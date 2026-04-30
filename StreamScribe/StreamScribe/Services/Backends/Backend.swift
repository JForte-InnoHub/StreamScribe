import Foundation
import MLX

/// Compute unit selection hint for backends that run on CoreML. Maps onto
/// CoreML's `MLComputeUnits` cases plus an explicit `.auto` for "use the
/// library's own default" — which is what every backend did before Phase 7.
///
/// Not every backend honors this:
///   - **WhisperKit**: respects all cases via `WhisperKitConfig.computeOptions`.
///   - **SpeakerKit**: doesn't accept a compute units parameter in its public
///     init today; treats this as `.auto` regardless.
///   - **Parakeet / Sortformer**: use MLX rather than CoreML. MLX dispatches
///     across CPU/GPU itself based on operation type and memory layout; no
///     equivalent knob. Hint is ignored.
///
/// Rationale for an enum rather than passing `MLComputeUnits` directly:
/// most of the project doesn't `import CoreML`, and exposing the CoreML type
/// here would force every transitive caller to import it too. Mapping in the
/// one backend (WhisperKit) that actually consumes the value keeps the
/// dependency contained.
enum ComputeUnits: String, Codable, Equatable {
    /// Defer to the library's default — typically "use whatever the model
    /// was compiled for," which is `.cpuAndNeuralEngine` for WhisperKit's
    /// encoder and `.cpuAndGPU` for its decoder. This matches all phases up
    /// to and including Phase 6, so default `.auto` everywhere is a no-op
    /// shipping change.
    case auto
    case cpuOnly
    case cpuAndGPU
    case cpuAndNeuralEngine
    case all
}

/// User-visible identifier for a transcription engine. Lets the UI list options without
/// caring about the underlying model class hierarchy.
enum TranscriptionEngineKind: String, CaseIterable, Identifiable, Codable {
    case whisperKit = "WhisperKit"
    case parakeet   = "Parakeet (MLX)"

    var id: String { rawValue }

    var blurb: String {
        switch self {
        case .whisperKit:
            return "OpenAI Whisper via CoreML/ANE. Multilingual, mature, with timestamps."
        case .parakeet:
            return "NVIDIA Parakeet via MLX. English, very fast on Apple Silicon."
        }
    }
}

/// User-visible identifier for a diarization engine.
enum DiarizationEngineKind: String, CaseIterable, Identifiable, Codable {
    case off        = "Off"
    case speakerKit = "SpeakerKit (pyannote 4)"
    case sortformer = "Sortformer (MLX, streaming)"

    var id: String { rawValue }

    var blurb: String {
        switch self {
        case .off:
            return "No speaker labels."
        case .speakerKit:
            return "Argmax pyannote port. Offline-style; ~30s warm-up before first labels appear."
        case .sortformer:
            return "NVIDIA Sortformer via MLX. True streaming, up to 4 speakers."
        }
    }
}

/// Anything that turns 16 kHz mono Float32 PCM chunks into transcript segments.
/// Implementations: WhisperKitBackend, ParakeetBackend.
protocol TranscriptionBackend: Actor {
    /// Human-readable description of what's being loaded, surfaced in the UI status line.
    func loadingDescription() -> String

    /// Download/load the model. Idempotent.
    func prepare() async throws

    /// Transcribe one chunk. `chunkStartTime` is the absolute offset on the stream timeline.
    /// Returns segments with timestamps already mapped to that timeline.
    func transcribe(samples: [Float], chunkStartTime: TimeInterval) async throws -> TranscriptionResult

    /// Optional reset between sessions (e.g. clear streaming state).
    func reset() async

    /// Release the underlying model resources (CoreML buffers, MLX weights, etc.)
    /// so the heavy memory footprint can be reclaimed. A subsequent `prepare()`
    /// call must successfully re-load the model.
    ///
    /// Used by the multi-pass refinement pipeline to lazy-load the refined
    /// transcriber per-window and drop it between windows, eliminating the
    /// memory-pressure interference between an idle refined model and the
    /// raw pass. Default empty implementation makes this opt-in: backends
    /// that don't want to participate in the lazy-load lifecycle can omit it.
    func unload() async
}

extension TranscriptionBackend {
    func unload() async { /* opt-in; no-op by default */ }
}

/// What a transcription backend returns per chunk.
struct TranscriptionResult {
    var segments: [TranscriptSegment]
    var detectedLanguage: String?
}

/// Anything that assigns speaker labels to chunks.
/// Implementations: SpeakerKitBackend, SortformerBackend, NoOpDiarizationBackend.
protocol DiarizationBackend: Actor {
    func loadingDescription() -> String
    func prepare() async throws
    /// Returns speaker turns mapped to the absolute stream timeline.
    func diarize(samples: [Float], chunkStartTime: TimeInterval) async -> [SpeakerTurn]
    func reset() async

    /// Release the underlying model resources. See `TranscriptionBackend.unload()`
    /// for full rationale. Default empty implementation makes this opt-in.
    func unload() async

    /// Diarize an entire audio buffer at once. Used for static sources (local files,
    /// VOD streams) where we have the whole audio available — gives the backend full
    /// context for clustering and produces stable speaker IDs without any chunk
    /// stitching heuristics.
    ///
    /// `bufferStartTime` is the absolute timeline offset at which this buffer begins
    /// (typically 0 for whole-file diarization).
    ///
    /// Default implementation falls back to the per-chunk method, which is correct
    /// but loses the accuracy benefit. SpeakerKitBackend overrides this to call its
    /// underlying diarize() once on the full buffer.
    func diarizeWholeBuffer(samples: [Float], bufferStartTime: TimeInterval) async -> [SpeakerTurn]
}

extension DiarizationBackend {
    func diarizeWholeBuffer(samples: [Float], bufferStartTime: TimeInterval) async -> [SpeakerTurn] {
        await diarize(samples: samples, chunkStartTime: bufferStartTime)
    }

    func unload() async { /* opt-in; no-op by default */ }
}

/// Speaker turn — same shape regardless of which backend produced it.
struct SpeakerTurn: Equatable, Sendable {
    let speaker: String
    let start: TimeInterval
    let end: TimeInterval

    func overlaps(_ segStart: TimeInterval, _ segEnd: TimeInterval) -> TimeInterval {
        let lo = max(start, segStart)
        let hi = min(end, segEnd)
        return max(0, hi - lo)
    }
}

// MARK: - MLX cache management

/// UserDefaults key for the user-configurable MLX buffer cache limit (megabytes).
/// Settings surface this as a slider; both MLX-based backends read it in their
/// `prepare()` to apply the limit before the model loads.
let mlxCacheLimitMBKey = "mlx.cacheLimitMB"

/// Default cache limit, in MB. 512 MB is comfortably above a single Parakeet
/// or Sortformer chunk's intermediate-buffer working set on Apple Silicon
/// while still bounded enough to prevent the unbounded-cache slowdown we hit
/// in session 5 (where chunk #176 took 82s of inference for 5s of audio).
/// Reference: MLX-Swift LLM examples ship with 20 MB for iOS and 512 MB for
/// desktop LLM apps; ASR backends are lighter than LLMs so 512 MB has
/// generous headroom.
let mlxCacheLimitDefaultMB = 512

/// Minimum/maximum bounds for the user-facing slider. Below 128 MB MLX starts
/// thrashing as it evicts useful intermediates between chunks; above 2048 MB
/// defeats the purpose of capping the cache at all. The actual safe ceiling
/// depends on the user's machine memory; the slider's job is to keep them
/// within a sane range, not to enforce a hardware-aware budget.
let mlxCacheLimitMinMB = 128
let mlxCacheLimitMaxMB = 2048

/// Read the current cache limit from UserDefaults and apply it via
/// `MLX.GPU.set(cacheLimit:)`. Both `ParakeetBackend` and `SortformerBackend`
/// call this from their `prepare()` so the setting takes effect on the next
/// session start (re-reading lets a slider change apply without an app
/// restart).
///
/// `set(cacheLimit:)` is global; calling it from multiple backends is
/// idempotent. The MLX value most recently set wins, and since both
/// backends read the same UserDefaults key they'll always agree.
///
/// Reads UserDefaults directly (not via @AppStorage) because this is called
/// from inside an actor — @AppStorage is a SwiftUI property wrapper and only
/// makes sense on View structs.
func applyMLXCacheLimit() {
    let stored = UserDefaults.standard.integer(forKey: mlxCacheLimitMBKey)
    // UserDefaults returns 0 if the key has never been written. Fall back to
    // the default in that case. Also clamp to the sane range in case a
    // misbehaving build wrote an out-of-range value.
    let mb = stored > 0
        ? min(max(stored, mlxCacheLimitMinMB), mlxCacheLimitMaxMB)
        : mlxCacheLimitDefaultMB
    MLX.GPU.set(cacheLimit: mb * 1024 * 1024)
    print("[MLX] cache limit set to \(mb) MB.")
}
