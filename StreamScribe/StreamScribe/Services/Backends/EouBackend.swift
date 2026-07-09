import Foundation
import AVFoundation
import FluidAudio

/// Transcription backend wrapping FluidAudio's `StreamingEouAsrManager`
/// — NVIDIA's Parakeet EOU (End-of-Utterance) 120M model, the one
/// genuinely streaming-native ASR in the stack.
///
/// **How it differs from the other backends.** WhisperKit and the MLX
/// Parakeet backend are batch models: each `transcribe` call processes
/// its chunk independently and returns that chunk's text. EOU is a
/// stateful stream: audio is fed continuously, the model decodes
/// incrementally with conformer caches carrying context across chunk
/// boundaries, and the transcript accumulates inside the manager with
/// per-token timestamps plus end-of-utterance markers. This backend
/// adapts that accumulation model to StreamScribe's per-chunk pull
/// API by tracking how many tokens each call has already consumed and
/// emitting only the NEW tokens as segments — split at EOU boundaries
/// where the model detected an utterance ending inside the window.
///
/// **What EOU buys over the batch backends in live mode:**
///   - No chunk-boundary word loss: the conformer caches mean a word
///     straddling two of our 5s chunks decodes correctly instead of
///     being clipped at the seam (the overlap-and-dedupe machinery the
///     batch backends need doesn't apply here).
///   - Utterance-aligned segments: splits happen where speech actually
///     pauses, not at arbitrary 5-second marks.
///   - 120M parameters: the smallest, fastest raw-pass option in the
///     app — designed for realtime dictation latency.
///
/// **Limitations, be aware:**
///   - English only.
///   - No punctuation/capitalization (raw streaming output). Pair
///     with a heavier refined-pass model (TDT-CTC 1.1B) in multi-pass
///     live mode, which was the intended use when this was added.
///   - Accuracy is a 120M model's: fine for provisional raw-pass
///     text, not for final transcripts.
///
/// **Model download.** FluidAudio's ModelHub fetches
/// `FluidInference/parakeet-realtime-eou-120m-coreml` (the 160ms
/// chunk variant) into `~/Library/Application Support/FluidAudio/
/// Models/parakeet-eou-streaming/160ms/` on first prepare. The same
/// R2 mirror override the diarizer uses (`FluidAudioBackend.
/// mirrorURLKey`) is applied before download for corporate-network
/// deployments.
actor EouBackend: TranscriptionBackend {

    private var manager: StreamingEouAsrManager?

    /// Absolute session timeline offset. The manager's token
    /// timestamps are relative to the start of the audio it's been
    /// fed; the first chunk's `chunkStartTime` anchors them to the
    /// session timeline. Reset per session.
    private var sessionStart: TimeInterval?

    /// How many accumulated tokens previous `transcribe` calls have
    /// already emitted as segments. The manager's token arrays grow
    /// monotonically across the session; each call emits only
    /// `tokens[consumedTokenCount...]`.
    private var consumedTokenCount: Int = 0

    /// How many EOU timestamps have already been used as segment
    /// boundaries. Same monotonic-consumption pattern as the tokens.
    private var consumedEouCount: Int = 0

    func loadingDescription() -> String {
        "Loading Parakeet EOU 120M (streaming)…"
    }

    func prepare() async throws {
        guard manager == nil else { return }

        // R2 mirror override — same knob the FluidAudio diarizer path
        // uses, so corporate networks that block HuggingFace get the
        // EOU model from the same mirror.
        if let mirrorURL = UserDefaults.standard.string(forKey: FluidAudioBackend.mirrorURLKey),
           !mirrorURL.isEmpty {
            ModelRegistry.baseURL = mirrorURL
            print("[EOU] Using R2 mirror: \(mirrorURL)")
        }

        // 160ms chunk variant: lowest latency step size, the flagship
        // configuration FluidAudio benchmarks. Our pipeline feeds 5s
        // chunks; the manager internally hops through them in 160ms
        // encoder steps, so OUR chunk cadence and the model's step
        // size are independent knobs.
        let m = StreamingEouAsrManager(chunkSize: .ms160)
        try await m.loadModels()
        self.manager = m
        print("[EOU] Parakeet EOU models loaded.")
    }

    func transcribe(samples: [Float], chunkStartTime: TimeInterval) async throws -> TranscriptionResult {
        guard let manager else {
            throw NSError(domain: "EouBackend", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "EOU backend not prepared"])
        }

        if sessionStart == nil {
            sessionStart = chunkStartTime
        }
        let base = sessionStart ?? chunkStartTime

        // Feed the chunk. `process` converts/enqueues and advances the
        // streaming decode; the returned string is always empty by
        // design (transcript accumulates internally).
        let buffer = try Self.makePCMBuffer(from: samples)
        _ = try await manager.process(audioBuffer: buffer)

        // Pull the accumulated state and slice off what's new.
        let rawTokens = await manager.getRawTokenStrings()
        let tokenTimestampsMs = await manager.getTokenTimestampsMs()
        let eouTimestampsMs = await manager.getEouTimestampsMs()

        let tokenCount = min(rawTokens.count, tokenTimestampsMs.count)
        guard tokenCount > consumedTokenCount else {
            // Nothing new decoded this chunk (silence, or audio still
            // inside the model's context window).
            return TranscriptionResult(segments: [], detectedLanguage: "en")
        }

        let newTokens = Array(rawTokens[consumedTokenCount..<tokenCount])
        let newTimestamps = Array(tokenTimestampsMs[consumedTokenCount..<tokenCount])
        consumedTokenCount = tokenCount

        // New EOU boundaries since last call, used to split the new
        // tokens into utterance-aligned segments.
        let newEous = Array(eouTimestampsMs[min(consumedEouCount, eouTimestampsMs.count)...])
        consumedEouCount = eouTimestampsMs.count

        let chunkEnd = chunkStartTime + Double(samples.count) / 16_000.0
        let segments = Self.buildSegments(
            tokens: newTokens,
            timestampsMs: newTimestamps,
            eouBoundariesMs: newEous,
            timelineBase: base,
            clampEnd: chunkEnd
        )

        return TranscriptionResult(segments: segments, detectedLanguage: "en")
    }

    func reset() async {
        await manager?.reset()
        sessionStart = nil
        consumedTokenCount = 0
        consumedEouCount = 0
    }

    func unload() async {
        manager = nil
        sessionStart = nil
        consumedTokenCount = 0
        consumedEouCount = 0
    }

    // MARK: - Helpers

    /// Split a run of new tokens into segments at EOU boundaries and
    /// materialize them as TranscriptSegments on the absolute session
    /// timeline.
    ///
    /// **Text reconstruction.** Raw tokens are SentencePiece pieces:
    /// word-initial pieces carry a leading "▁". Concatenating pieces
    /// and mapping "▁" → space reconstructs the text — the same
    /// convention every SentencePiece tokenizer uses.
    ///
    /// **Timing.** Token timestamps mark token START times. A
    /// segment spans first-token start → last-token start + a small
    /// tail allowance (240ms ≈ typical final-token duration), clamped
    /// to the chunk end so a segment never claims audio that hasn't
    /// been fed yet.
    static func buildSegments(
        tokens: [String],
        timestampsMs: [Int],
        eouBoundariesMs: [Int],
        timelineBase: TimeInterval,
        clampEnd: TimeInterval
    ) -> [TranscriptSegment] {
        guard !tokens.isEmpty else { return [] }

        // Partition token indices at EOU boundaries: a token belongs
        // to the utterance whose EOU timestamp is >= its own.
        var groups: [[Int]] = []
        var current: [Int] = []
        var eouIter = eouBoundariesMs.sorted().makeIterator()
        var nextEou = eouIter.next()

        for i in 0..<tokens.count {
            // Close the current group when this token starts AFTER
            // the pending EOU boundary — the utterance ended before
            // this token began.
            while let boundary = nextEou, timestampsMs[i] > boundary {
                if !current.isEmpty {
                    groups.append(current)
                    current = []
                }
                nextEou = eouIter.next()
            }
            current.append(i)
        }
        if !current.isEmpty {
            groups.append(current)
        }

        var segments: [TranscriptSegment] = []
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let text = group
                .map { tokens[$0] }
                .joined()
                .replacingOccurrences(of: "▁", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let start = timelineBase + Double(timestampsMs[first]) / 1000.0
            let rawEnd = timelineBase + Double(timestampsMs[last]) / 1000.0 + 0.24
            let end = min(max(rawEnd, start + 0.1), clampEnd)

            segments.append(TranscriptSegment(
                text: text,
                start: start,
                end: end,
                speaker: nil,
                isFinalized: true
            ))
        }
        return segments
    }

    /// Wrap 16 kHz mono Float32 samples in the AVAudioPCMBuffer the
    /// FluidAudio manager expects. The manager resamples internally
    /// if needed, but our pipeline already delivers 16k mono so the
    /// conversion is a straight copy.
    static func makePCMBuffer(from samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw NSError(domain: "EouBackend", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate PCM buffer"])
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }
}
