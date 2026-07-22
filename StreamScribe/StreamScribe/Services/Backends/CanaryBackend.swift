import Foundation
import FluidAudio

/// Transcription backend for NVIDIA Canary-1B v2 via FluidAudio's
/// CoreML build (`FluidInference/canary-1b-v2-coreml`, int4, ANE).
///
/// **What Canary is.** A FastConformer encoder + Transformer
/// attention encoder-decoder — a fundamentally more accurate
/// architecture than Parakeet's transducer (≈2.1% WER on LibriSpeech
/// test-clean for the int4 build), multilingual (25 languages), at
/// the cost of autoregressive decoding (~7x realtime on ANE — ample
/// for both raw 5s chunks and refined 30-60s windows). Replaced the
/// Parakeet EOU engine slot: EOU's accuracy disappointed, and Canary
/// is batch-capable, so unlike EOU it's also legitimate on the
/// REFINED slot — arguably its best seat, since accuracy is the
/// refined pass's whole job.
///
/// **Sliding-window semantics.** FluidAudio's CanaryManager consumes
/// contiguous audio in 2s hops with 10s of internal left context.
/// Two consequences shape this backend:
///
///   1. **No token timestamps** — the manager returns text per hop.
///      This backend feeds the manager in its native 2s subchunks
///      and synthesizes one segment per non-empty hop spanning that
///      hop's time range. 2s granularity is fine for diarizer
///      attribution (typical turns are much longer).
///   2. **The internal buffer must NEVER be double-fed.** The engine
///      delivers OVERLAPPING chunks (batch backends dedupe by text);
///      re-feeding overlap into a stateful context buffer duplicates
///      words and corrupts context. This backend tracks a fed
///      high-water mark and slices each incoming chunk to only its
///      NEW samples. (The retired EOU backend never did this — a
///      plausible contributor to its perceived inaccuracy.)
actor CanaryBackend: TranscriptionBackend {

    private var manager: CanaryManager?

    /// The manager's native hop: 2 seconds at 16 kHz.
    private static let subchunkSamples = 32_000

    /// Absolute end time (session timeline) of audio already fed to
    /// the manager — the double-feed guard.
    private var fedThrough: TimeInterval = 0
    private var hasFedAnything = false

    /// Sub-2s remainder awaiting the next chunk, with its start time.
    private var carry: [Float] = []
    private var carryStart: TimeInterval = 0

    func loadingDescription() -> String {
        "Loading Canary 1B v2 (CoreML)…"
    }

    func prepare() async throws {
        guard manager == nil else { return }

        if let mirrorURL = UserDefaults.standard.string(forKey: FluidAudioBackend.mirrorURLKey),
           !mirrorURL.isEmpty {
            ModelRegistry.baseURL = mirrorURL
            print("[Canary] Using R2 mirror: \(mirrorURL)")
        }

        // FluidAudio's canonical cache location for canary (matches
        // the CLI's convention): ~/Library/Application Support/
        // FluidAudio/canary. `CanaryModels.load` downloads what's
        // missing and CoreML-loads (preprocessor CPU, encoder/decoder
        // per default configuration).
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("FluidAudio")
            .appendingPathComponent("canary")
        let models = try await CanaryModels.load(from: dir)
        let m = CanaryManager()
        m.initialize(models: models)
        self.manager = m
        print("[Canary] Models loaded.")
    }

    func transcribe(samples: [Float], chunkStartTime: TimeInterval) async throws -> TranscriptionResult {
        guard let manager else {
            throw NSError(domain: "CanaryBackend", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Canary backend not prepared"])
        }

        // Double-feed guard: drop any samples we've already fed
        // (chunk overlap from the engine's batch-oriented pipeline).
        var newSamples = samples
        var newStart = chunkStartTime
        if hasFedAnything && chunkStartTime < fedThrough {
            let skip = Int(((fedThrough - chunkStartTime) * 16_000).rounded())
            guard skip < samples.count else {
                // Entirely already-fed audio (a pure-overlap call).
                return TranscriptionResult(segments: [], detectedLanguage: "en")
            }
            newSamples = Array(samples[skip...])
            newStart = fedThrough
        }

        // Stitch with any sub-hop remainder from the previous call.
        var stitched: [Float]
        var base: TimeInterval
        if carry.isEmpty {
            stitched = newSamples
            base = newStart
        } else {
            stitched = carry + newSamples
            base = carryStart
        }

        var segments: [TranscriptSegment] = []
        var offset = 0
        while stitched.count - offset >= Self.subchunkSamples {
            let sub = Array(stitched[offset..<(offset + Self.subchunkSamples)])
            let text = try await manager.processStreamingChunk(sub)
            let t0 = base + Double(offset) / 16_000.0
            let t1 = t0 + Double(Self.subchunkSamples) / 16_000.0
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(TranscriptSegment(
                    text: trimmed,
                    start: t0,
                    end: t1,
                    speaker: nil,
                    isFinalized: true
                ))
            }
            offset += Self.subchunkSamples
        }

        carry = Array(stitched[offset...])
        carryStart = base + Double(offset) / 16_000.0
        fedThrough = carryStart + Double(carry.count) / 16_000.0
        hasFedAnything = true

        return TranscriptionResult(segments: segments, detectedLanguage: "en")
    }

    func reset() async {
        manager?.reset()
        carry = []
        carryStart = 0
        fedThrough = 0
        hasFedAnything = false
    }

    func unload() async {
        manager = nil
        carry = []
        fedThrough = 0
        hasFedAnything = false
    }
}
