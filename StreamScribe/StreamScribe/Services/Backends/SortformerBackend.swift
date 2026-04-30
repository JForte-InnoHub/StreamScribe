import Foundation
import MLX
import MLXAudioVAD

/// Sortformer-backed diarization via mlx-audio-swift.
///
/// Public API consumed (verified against mlx-audio-swift 0.1.2 sources):
///   • `SortformerModel.fromPretrained(_:)` — public static func.
///   • `model.initStreamingState() -> StreamingState` — public, builds initial buffer state.
///   • `model.feed(chunk:state:sampleRate:threshold:minDuration:mergeGap:spkcacheMax:fifoMax:)`
///     async throws → `(DiarizationOutput, StreamingState)`. Returns segments whose
///     `start`/`end` are **already mapped to absolute streaming time** (the model adds
///     `chunkTimeOffset` internally, see Sortformer.swift line 808).
///   • `DiarizationSegment` exposes `start: Float`, `end: Float`, `speaker: Int`.
///   • `StreamingState` (no prefix) is the public state type — not `SortformerStreamingState`.
///
/// Capped at 4 simultaneous speakers (architectural).
actor SortformerBackend: DiarizationBackend {

    private var model: SortformerModel?
    private let modelRepo: String
    private let threshold: Float

    /// Persistent streaming state across chunks. Carries speaker identity forward so cluster IDs
    /// (`DiarizationSegment.speaker`) stay stable for the whole session — no embedding-similarity
    /// hack needed on our side.
    private var streamingState: StreamingState?

    init(
        modelRepo: String = "mlx-community/diar_streaming_sortformer_4spk-v2.1-fp16",
        threshold: Float = 0.5
    ) {
        self.modelRepo = modelRepo
        self.threshold = threshold
    }

    func loadingDescription() -> String {
        "Loading Sortformer (MLX)…"
    }

    func prepare() async throws {
        if model != nil { return }
        // Apply the user's MLX buffer-cache limit before model load. See
        // `applyMLXCacheLimit` in Backend.swift for full rationale — the
        // short version is that without a cap, MLX inference slows
        // progressively over a long session. Sortformer runs every chunk
        // alongside Parakeet, so its inferences would contribute equally
        // to the cache buildup without this. Both backends call this in
        // prepare() rather than once at app launch so the setting can be
        // changed in Settings without an app restart.
        applyMLXCacheLimit()

        // Migrate a sideloaded copy from ~/Documents/huggingface/hub/ if
        // present. Same mechanism Parakeet uses; we delegate to its
        // helper because Sortformer is a mlx-audio-swift model with the
        // same HF Hub cache layout. See ParakeetBackend's
        // migrateSideloadedCacheIfPresent doc comment for details.
        ParakeetBackend.migrateSideloadedCacheIfPresent(modelRepo: modelRepo)

        let m = try await SortformerModel.fromPretrained(modelRepo)
        self.model = m
        self.streamingState = m.initStreamingState()

        // Reclaim the duplicate HF Hub copy left over by mlx-audio-swift.
        // See ParakeetBackend.cleanupDuplicateHubCopy for the full
        // explanation — same library, same duplicate-download behavior.
        ParakeetBackend.cleanupDuplicateHubCopy(modelRepo: modelRepo)
    }

    func diarize(samples: [Float], chunkStartTime: TimeInterval) async -> [SpeakerTurn] {
        // Parameter `chunkStartTime` is unused: Sortformer's `feed()` returns segments with
        // timestamps already mapped onto the absolute stream timeline (the model tracks
        // `framesProcessed` in StreamingState and adds the offset internally). Keeping the
        // parameter in the protocol lets other backends (e.g. SpeakerKit) need it.
        _ = chunkStartTime

        guard let model, let state = streamingState else { return [] }
        guard samples.count >= 16_000 else { return [] }

        do {
            let chunk = MLXArray(samples)
            let (output, newState) = try await model.feed(
                chunk: chunk,
                state: state,
                sampleRate: 16_000,
                threshold: threshold,
                spkcacheMax: 188,
                fifoMax: 188
            )
            self.streamingState = newState

            return output.segments.map { seg in
                SpeakerTurn(
                    speaker: "Speaker \(seg.speaker + 1)",  // 0-indexed → 1-indexed for display
                    start: TimeInterval(seg.start),
                    end: TimeInterval(seg.end)
                )
            }
        } catch {
            #if DEBUG
            print("Sortformer error: \(error)")
            #endif
            return []
        }
    }

    func reset() async {
        streamingState = model?.initStreamingState()
    }

    /// Drop the loaded model and the streaming state. Subsequent `prepare()`
    /// will re-load (Sortformer's model is small — ~24M params — so this is
    /// cheap compared to Whisper). Used in the multi-pass refinement
    /// lazy-load path for symmetry with the transcriber. The streaming state
    /// across refined-pass calls isn't used today (refined diarizer output
    /// is currently discarded — see comment in performRefinementPass), so
    /// losing it on unload has no functional cost.
    func unload() async {
        guard model != nil else { return }
        model = nil
        streamingState = nil
        print("[Sortformer] unloaded model.")
    }

    /// Whole-file diarization for static sources (local files, VOD).
    ///
    /// Sortformer is architecturally a streaming model — `feed()` is designed to be
    /// called repeatedly with short chunks, carrying `StreamingState` forward so the
    /// model can track speaker identity continuously. The default `diarizeWholeBuffer`
    /// implementation in `DiarizationBackend`'s extension just calls `diarize()` once
    /// on the full buffer, which hands Sortformer one giant blob in a single `feed()`
    /// call. That's not how it was trained to operate and tends to produce unstable
    /// over-segmentation (each sentence becomes its own short cluster, with implausible
    /// speaker flips between adjacent sentences).
    ///
    /// This override does what the model expects: slice the buffer into ~5s chunks,
    /// feed them sequentially with state preserved, then post-process to merge any
    /// adjacent same-speaker segments that got split at our artificial chunk
    /// boundaries.
    ///
    /// We deliberately use a *fresh* StreamingState here rather than the one that may
    /// have been carrying chunked-mode state from earlier in the session — whole-file
    /// diarization runs at end-of-pipeline and shouldn't be polluted by any prior
    /// per-chunk calls (in static mode there shouldn't be any, but belt-and-suspenders).
    func diarizeWholeBuffer(samples: [Float], bufferStartTime: TimeInterval) async -> [SpeakerTurn] {
        guard let model else { return [] }
        guard samples.count >= 16_000 else { return [] }

        // Sortformer's training context window per feed() call. 5s is the sweet spot
        // referenced in mlx-audio-swift's docs and matches our existing live-mode
        // chunk size. Larger windows risk the same one-giant-blob problem; smaller
        // windows produce too many short feed() calls and slow things down.
        let chunkSamples = Int(5.0 * 16_000)

        var state = model.initStreamingState()
        var collected: [SpeakerTurn] = []

        var cursor = 0
        while cursor < samples.count {
            let end = min(cursor + chunkSamples, samples.count)
            let slice = Array(samples[cursor..<end])

            // Skip any final tail shorter than 1s — feed() requires ≥1s of audio,
            // matching the guard in diarize() above. The previous chunks already
            // cover the timeline up to (samples.count - tail), and the model's
            // streaming state has already absorbed everything.
            guard slice.count >= 16_000 else { break }

            do {
                let chunk = MLXArray(slice)
                let (output, newState) = try await model.feed(
                    chunk: chunk,
                    state: state,
                    sampleRate: 16_000,
                    threshold: threshold,
                    spkcacheMax: 188,
                    fifoMax: 188
                )
                state = newState

                // feed() returns segments with timestamps already mapped to absolute
                // streaming time (the model adds chunkTimeOffset internally based on
                // the StreamingState's framesProcessed counter). Add bufferStartTime
                // so that callers passing a non-zero start get correct absolute times
                // on the master timeline.
                for seg in output.segments {
                    collected.append(SpeakerTurn(
                        speaker: "raw_\(seg.speaker)",  // placeholder; relabeled below
                        start: bufferStartTime + TimeInterval(seg.start),
                        end: bufferStartTime + TimeInterval(seg.end)
                    ))
                }
            } catch {
                #if DEBUG
                print("[SortformerBackend] whole-buffer feed() error at offset \(cursor): \(error)")
                #endif
                // Continue; partial output is more useful than none.
            }

            cursor = end
        }

        // Post-process: merge adjacent same-speaker segments that abut each other.
        // Sortformer's per-chunk emission may split a continuous turn into multiple
        // segments when the turn straddles a chunk boundary; merging restores it.
        let merged = SortformerBackend.mergeAdjacent(collected, gapTolerance: 0.5)

        // Apply first-appearance ordering: the speaker who talks first becomes
        // "Speaker 1", the next new voice becomes "Speaker 2", etc. This mirrors
        // SpeakerKitBackend.diarizeWholeBuffer so the two backends produce
        // similarly-numbered output, and makes labels deterministic across runs.
        return SortformerBackend.relabelByFirstAppearance(merged)
    }

    // MARK: - Whole-buffer post-processing helpers

    /// Merge adjacent SpeakerTurns produced by sequential feed() calls when they
    /// represent the same continuous turn split at a chunk boundary. "Adjacent" =
    /// same raw speaker ID AND end[i] is within `gapTolerance` seconds of start[i+1].
    /// Input must be sorted by start time (which the sequential feed pass already
    /// guarantees within a single raw speaker).
    private static func mergeAdjacent(_ turns: [SpeakerTurn], gapTolerance: TimeInterval) -> [SpeakerTurn] {
        guard !turns.isEmpty else { return turns }
        // Sort once; segments from different chunks may interleave on the timeline
        // when speakers overlap, so we can't assume input order.
        let sorted = turns.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
        var out: [SpeakerTurn] = []
        for t in sorted {
            // Look for a same-speaker turn whose end is close to this one's start.
            // We scan the tail rather than just last() because two interleaved
            // speakers can leave a same-speaker continuation a couple positions back.
            var mergedInto: Int?
            for i in stride(from: out.count - 1, through: max(0, out.count - 4), by: -1) {
                if out[i].speaker == t.speaker,
                   t.start - out[i].end <= gapTolerance,
                   t.start >= out[i].start
                {
                    mergedInto = i
                    break
                }
            }
            if let i = mergedInto {
                out[i] = SpeakerTurn(
                    speaker: out[i].speaker,
                    start: out[i].start,
                    end: max(out[i].end, t.end)
                )
            } else {
                out.append(t)
            }
        }
        return out
    }

    /// Relabel raw speaker IDs ("raw_0", "raw_1", …) to "Speaker N" based on order
    /// of first appearance on the timeline. Mirrors the SpeakerKit pattern so users
    /// don't have to learn two different labeling conventions across diarizers.
    private static func relabelByFirstAppearance(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        var firstAppearance: [String: TimeInterval] = [:]
        for t in turns {
            if firstAppearance[t.speaker] == nil {
                firstAppearance[t.speaker] = t.start
            }
        }
        let ordered = firstAppearance
            .sorted { $0.value < $1.value }
            .map { $0.key }
        var rawToLabel: [String: String] = [:]
        for (i, raw) in ordered.enumerated() {
            rawToLabel[raw] = "Speaker \(i + 1)"
        }
        return turns.map { t in
            SpeakerTurn(
                speaker: rawToLabel[t.speaker] ?? t.speaker,
                start: t.start,
                end: t.end
            )
        }
    }
}

extension SortformerBackend {
    /// Default repo (mirrors the `init` default). Hoisted into a static
    /// constant so `isModelCached` can build a path candidate without
    /// instantiating the actor — instance properties on actors aren't
    /// reachable from non-isolated contexts without an await.
    static let defaultModelRepo = "mlx-community/diar_streaming_sortformer_4spk-v2.1-fp16"

    /// Whether the Sortformer weights are already on disk. Sortformer ships a
    /// single canonical model today (no user-pickable variants), so this
    /// checks just that repo. Same probe shape as `ParakeetBackend.isModelCached`
    /// because both go through mlx-audio-swift's `fromPretrained` path which
    /// uses the same Hugging Face Hub cache layout.
    static func isModelCached() -> Bool {
        ParakeetBackend.isModelCached(modelRepo: defaultModelRepo)
    }
}

/// No-op diarization for when the user disables it. Keeps the engine code uniform.
actor NoOpDiarizationBackend: DiarizationBackend {
    func loadingDescription() -> String { "" }
    func prepare() async throws {}
    func diarize(samples: [Float], chunkStartTime: TimeInterval) async -> [SpeakerTurn] { [] }
    func reset() async {}
}
