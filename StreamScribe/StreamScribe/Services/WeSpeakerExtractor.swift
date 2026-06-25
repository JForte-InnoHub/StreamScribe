import Foundation
import FluidAudio

/// Side-channel WeSpeaker embedding extractor for runtime voice
/// identification. Wraps FluidAudio's `DiarizerManager` (the same
/// public pipeline the standalone SpeakerEnroll CLI uses) to produce
/// embeddings comparable to the templates in `VoiceprintService`.
///
/// **Why a side-channel.** The app's primary live diarizer is
/// `LSEENDDiarizer`, which doesn't expose WeSpeaker embeddings — its
/// end-to-end architecture tracks speaker identity through internal
/// attention slots rather than the discrete WeSpeaker vectors our
/// templates live in. We can't compare LSEEND's internal state
/// against our templates directly. So we run WeSpeaker independently
/// against cluster audio extracted from the accumulated buffer, get
/// vectors in the same space as the templates, and match.
///
/// **Cost is bounded by gating.** This extractor runs only when a
/// cluster has accumulated enough speech AND hasn't already been
/// identified with high confidence AND has hit a refresh interval.
/// For a 90-minute Senate hearing with 6 active speakers, total
/// extractions are typically 15-30 over the session, each taking
/// ~150ms on ANE. Negligible overhead.
///
/// **Models share with the bundle FluidAudio already loaded.**
/// `DiarizerModels.downloadIfNeeded()` returns the same CoreML
/// bundles that LSEEND/OfflineDiarizerManager use, fetched from
/// disk cache on subsequent calls. No double download, no double
/// compile — first call is ~3-5 seconds for the initial models
/// resolution, subsequent calls are <100ms.
///
/// **A fresh DiarizerManager per extraction.** We create a new
/// `DiarizerManager` for each `extractEmbedding` call rather than
/// caching one across calls. Reason: `DiarizerManager.speakerManager`
/// accumulates state across `performCompleteDiarization` invocations.
/// Calling twice with audio from the same person reuses the existing
/// cluster ID and returns a running-average embedding — fine for
/// enrollment (where we WANT averaging), wrong for runtime
/// identification (where each cluster's current state should be
/// extracted fresh). Creating a fresh manager per call is cheap
/// (~10ms) since the models are cached.
@MainActor
final class WeSpeakerExtractor {

    static let shared = WeSpeakerExtractor()

    /// Cached DiarizerModels bundle. Loaded on first use and reused
    /// across extractions. Survives session boundaries since the
    /// model weights don't change.
    private var cachedModels: DiarizerModels?

    private init() {}

    // MARK: - Public extraction API

    /// Extract a WeSpeaker embedding from a single-speaker audio clip.
    ///
    /// **Input requirements:** 16kHz mono Float32 samples. At least
    /// 1 second of audio (16,000 samples). The gating logic in
    /// `TranscriptionEngine` ensures this is met; callers outside
    /// that path should validate themselves.
    ///
    /// **Single-speaker assumption.** The clip should contain primarily
    /// one speaker. If the diarization step inside DiarizerManager
    /// detects multiple speakers (boundary contamination, leakage from
    /// adjacent segments), we pick the dominant one when it accounts
    /// for ≥70% of the audio. Below 70% the clip is too contested for
    /// a reliable embedding and we throw — caller should skip and
    /// retry on the next refresh interval.
    ///
    /// The 70% threshold is more lenient than the 80% used in the
    /// standalone enrollment CLI. Live audio is messier than
    /// pre-curated enrollment clips, and we'd rather accept some
    /// degradation than miss identifications that would have worked.
    ///
    /// **Returns** the WeSpeaker embedding (256-dim Float vector,
    /// NOT pre-normalized — VoiceprintService normalizes at match
    /// time).
    func extractEmbedding(from audio: [Float]) async throws -> [Float] {
        let durationSeconds = Double(audio.count) / 16_000.0
        guard durationSeconds >= 1.0 else {
            throw ExtractionError.audioTooShort(durationSeconds: durationSeconds)
        }

        let models = try await loadModels()
        let diarizer = DiarizerManager()
        diarizer.initialize(models: models)

        // Same call path as the standalone enrollment CLI's
        // EnrollCommand. Returns a DiarizationResult with segments,
        // and populates SpeakerManager with one or more speakers
        // representing the detected clusters in this audio.
        let result = try diarizer.performCompleteDiarization(audio)
        return try selectEmbedding(from: result, diarizer: diarizer)
    }

    // MARK: - Helpers

    /// Lazy-load (and cache) the DiarizerModels bundle. The first
    /// call may trigger a download if FluidAudio's models aren't
    /// cached yet — usually they are, since LSEEND/OfflineDiarizerManager
    /// would have already loaded them earlier in the session.
    private func loadModels() async throws -> DiarizerModels {
        if let m = cachedModels { return m }
        let m = try await DiarizerModels.downloadIfNeeded()
        cachedModels = m
        return m
    }

    /// Pick the right speaker embedding from a diarization result —
    /// same logic as the standalone enrollment CLI's selectEmbedding,
    /// with a slightly lower dominance threshold (70% vs 80%) tuned
    /// for messier live audio.
    private func selectEmbedding(
        from result: DiarizationResult,
        diarizer: DiarizerManager
    ) throws -> [Float] {
        let speakerIds = diarizer.speakerManager.speakerIds
        guard !speakerIds.isEmpty else {
            throw ExtractionError.noSpeakerDetected
        }

        // Build (id, duration, embedding) tuples for every speaker.
        // Skip any with missing embeddings — shouldn't happen since
        // DiarizerManager only creates a speaker after extracting one,
        // but defensive.
        var candidates: [(id: String, duration: Double, embedding: [Float])] = []
        for id in speakerIds {
            guard let speaker = diarizer.speakerManager.getSpeaker(for: id) else { continue }
            let embedding = speaker.currentEmbedding
            guard !embedding.isEmpty else { continue }

            // Cumulative speech time for this speaker.
            var totalSeconds: Double = 0
            for segment in result.segments where segment.speakerId == id {
                totalSeconds += Double(segment.endTimeSeconds - segment.startTimeSeconds)
            }
            candidates.append((id, totalSeconds, embedding))
        }

        guard !candidates.isEmpty else { throw ExtractionError.emptyEmbedding }

        if candidates.count == 1 {
            return candidates[0].embedding
        }

        // Multi-speaker case. Pick dominant if it accounts for ≥70%
        // of speech time. Below that the clip is too contested for a
        // reliable single-speaker embedding.
        let totalDuration = candidates.map { $0.duration }.reduce(0, +)
        guard totalDuration > 0,
              let dominant = candidates.max(by: { $0.duration < $1.duration }) else {
            throw ExtractionError.noSpeakerDetected
        }
        let dominantFraction = dominant.duration / totalDuration
        guard dominantFraction >= 0.7 else {
            throw ExtractionError.contestedAudio(dominantFraction: dominantFraction)
        }
        return dominant.embedding
    }

    // MARK: - Errors

    enum ExtractionError: LocalizedError {
        case audioTooShort(durationSeconds: Double)
        case noSpeakerDetected
        case emptyEmbedding
        case contestedAudio(dominantFraction: Double)

        var errorDescription: String? {
            switch self {
            case .audioTooShort(let s):
                return "Audio too short (\(String(format: "%.1fs", s))) — need at least 1s"
            case .noSpeakerDetected:
                return "No speaker detected in audio clip"
            case .emptyEmbedding:
                return "Empty embedding returned from diarizer"
            case .contestedAudio(let f):
                return "Multi-speaker audio (dominant: \(String(format: "%.0f%%", f * 100))); need ≥70%"
            }
        }
    }
}
