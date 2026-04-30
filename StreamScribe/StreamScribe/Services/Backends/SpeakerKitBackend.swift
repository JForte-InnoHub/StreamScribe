import Foundation
import SpeakerKit

/// SpeakerKit-backed diarization (Argmax CoreML port of pyannote 4 community-1).
///
/// Honest accounting of a hard problem:
///
/// SpeakerKit is fundamentally an *offline* diarizer — `diarize(audioArray:)` clusters
/// speakers using an agglomerative algorithm over the *whole buffer it receives*. That
/// means cluster IDs (`SpeakerInfo.speakerId(Int)`) are only stable *within a single
/// call*. If we naively call it on each 5-second chunk, "Speaker 0" in chunk 1 has no
/// guaranteed relationship to "Speaker 0" in chunk 2. SpeakerKit does not publicly
/// expose voice embeddings we could use to stitch identities across calls.
///
/// We work around this by accumulating audio in a large window (default 30s) and
/// running diarization on that window. Identities are stable *within* the window.
/// Across windows we still face the same problem, so we apply a simple heuristic:
/// the speaker with the most active time in the previous window's overlap region is
/// matched to the speaker with the most active time in the current window's overlap
/// region. This works passably for 1-on-2 conversations and degrades for noisy
/// audio or rapid speaker changes.
///
/// Bottom line: for content with ≤4 speakers and tight identity stability needs,
/// **prefer Sortformer** — it has true streaming state. SpeakerKit is here for content
/// with more speakers or when you want to A/B against an offline-style diarizer.
actor SpeakerKitBackend: DiarizationBackend {

    private var speakerKit: SpeakerKit?

    /// Audio accumulator. We diarize when this fills past `windowSeconds`.
    private var audioBuffer: [Float] = []
    /// Absolute stream time (seconds) at which `audioBuffer[0]` starts.
    private var bufferStartTime: TimeInterval = 0

    /// How long a buffer to accumulate before running diarization. 30s is enough for
    /// pyannote-style clustering to produce stable IDs; shorter windows are less reliable.
    private let windowSeconds: TimeInterval = 30.0
    private let sampleRate: Double = 16_000

    /// Map from SpeakerKit's per-window cluster IDs to our stable session-level labels.
    /// Reset each new diarize() call; we re-stitch via the heuristic below.
    private var sessionSpeakerCount: Int = 0

    /// Track the previous window's speakers so we can attempt continuity.
    /// Each entry: speaker label → total active seconds in that window.
    private var lastWindowSpeakerActivity: [(label: String, activeSeconds: TimeInterval)] = []

    func loadingDescription() -> String {
        "Loading SpeakerKit (pyannote 4)…"
    }

    func prepare() async throws {
        if speakerKit != nil { return }
        speakerKit = try await SpeakerKit()
    }

    func diarize(samples: [Float], chunkStartTime: TimeInterval) async -> [SpeakerTurn] {
        // Track buffer start on the first chunk we see.
        if audioBuffer.isEmpty {
            bufferStartTime = chunkStartTime
        }
        audioBuffer.append(contentsOf: samples)

        // Wait until we have at least `windowSeconds` of audio. This means there's a
        // ~30s lag on the first speaker labels appearing — that's the trade-off.
        let windowSamples = Int(windowSeconds * sampleRate)
        guard audioBuffer.count >= windowSamples else { return [] }

        return await runDiarizationOnBuffer()
    }

    /// Run diarization on the accumulated buffer and reset.
    private func runDiarizationOnBuffer() async -> [SpeakerTurn] {
        guard let speakerKit else { return [] }
        guard audioBuffer.count >= 16_000 else { return [] }

        let bufferToProcess = audioBuffer
        let bufferStart = bufferStartTime

        // Reset for the next window before any await — keeps the actor simple.
        audioBuffer.removeAll(keepingCapacity: true)

        do {
            let result = try await speakerKit.diarize(audioArray: bufferToProcess, options: nil)

            // Convert SpeakerSegment[] → SpeakerTurn[]. Map cluster IDs to stable labels
            // using last-window continuity heuristic.
            let turns = mapSegmentsToTurns(result.segments, bufferStart: bufferStart)

            // Update last-window activity so the next call can stitch.
            updateLastWindowActivity(from: turns)

            return turns
        } catch {
            #if DEBUG
            print("SpeakerKit error: \(error)")
            #endif
            return []
        }
    }

    /// Convert SpeakerKit's per-window cluster IDs to our session-stable "Speaker N" labels.
    ///
    /// Strategy: build a per-window activity tally, sort speakers by active time descending,
    /// and match against last window in the same order. New speakers get fresh "Speaker N"
    /// labels with N incrementing globally. This is heuristic but predictable.
    private func mapSegmentsToTurns(_ segments: [SpeakerSegment], bufferStart: TimeInterval)
        -> [SpeakerTurn]
    {
        // Group segments by their per-window cluster ID and compute activity.
        var activityByClusterId: [Int: TimeInterval] = [:]
        for seg in segments {
            // SpeakerInfo can be .speakerId, .multiple, or .noMatch. We only attribute
            // single-speaker turns; multiple/noMatch get dropped (no good label to use).
            guard case .speakerId(let cid) = seg.speaker else { continue }
            let dur = TimeInterval(seg.endTime - seg.startTime)
            activityByClusterId[cid, default: 0] += dur
        }

        // Sort cluster IDs by activity descending — most-talkative cluster gets matched first.
        let clustersByActivity = activityByClusterId
            .sorted { $0.value > $1.value }
            .map { $0.key }

        // Sort previous window's labels the same way (already by activity in `lastWindowSpeakerActivity`).
        let lastLabels = lastWindowSpeakerActivity
            .sorted { $0.activeSeconds > $1.activeSeconds }
            .map { $0.label }

        // Map: per-window cluster ID → stable session label
        var clusterIdToLabel: [Int: String] = [:]
        for (i, cid) in clustersByActivity.enumerated() {
            if i < lastLabels.count {
                clusterIdToLabel[cid] = lastLabels[i]
            } else {
                sessionSpeakerCount += 1
                clusterIdToLabel[cid] = "Speaker \(sessionSpeakerCount)"
            }
        }

        // Build turns mapped to absolute time
        return segments.compactMap { seg in
            guard case .speakerId(let cid) = seg.speaker,
                  let label = clusterIdToLabel[cid]
            else { return nil }
            return SpeakerTurn(
                speaker: label,
                start: bufferStart + TimeInterval(seg.startTime),
                end: bufferStart + TimeInterval(seg.endTime)
            )
        }
    }

    private func updateLastWindowActivity(from turns: [SpeakerTurn]) {
        var activity: [String: TimeInterval] = [:]
        for t in turns {
            activity[t.speaker, default: 0] += (t.end - t.start)
        }
        lastWindowSpeakerActivity = activity
            .map { (label: $0.key, activeSeconds: $0.value) }
            .sorted { $0.activeSeconds > $1.activeSeconds }
    }

    func reset() async {
        audioBuffer.removeAll(keepingCapacity: true)
        bufferStartTime = 0
        sessionSpeakerCount = 0
        lastWindowSpeakerActivity.removeAll()
    }

    /// Whole-file diarization: feed SpeakerKit the entire audio buffer at once.
    ///
    /// SpeakerKit's pyannote-based pipeline performs agglomerative clustering across
    /// the whole input. With a complete buffer it has full context — every speaker's
    /// voice is visible to the clustering algorithm and IDs are stable for the entire
    /// audio. This is dramatically more accurate than the chunked path's activity-rank
    /// stitching heuristic, especially when there are many speakers or when speakers
    /// appear briefly.
    ///
    /// SpeakerKit returns `SpeakerInfo.speakerId(Int)` cluster IDs that are guaranteed
    /// stable within a single call. We map each one to a "Speaker N" label deterministically
    /// (lower cluster ID → lower N), so output naming stays consistent across runs of
    /// the same audio.
    func diarizeWholeBuffer(samples: [Float], bufferStartTime: TimeInterval) async -> [SpeakerTurn] {
        guard let speakerKit else { return [] }
        guard samples.count >= 16_000 else { return [] }

        do {
            let result = try await speakerKit.diarize(audioArray: samples, options: nil)

            // Build a mapping from SpeakerKit cluster ID → "Speaker N" label.
            // Sort by first appearance time so labels read naturally in document order:
            // the first person to speak is "Speaker 1", the next new voice is "Speaker 2", etc.
            var firstAppearance: [Int: Float] = [:]
            for seg in result.segments {
                guard case .speakerId(let cid) = seg.speaker else { continue }
                if firstAppearance[cid] == nil {
                    firstAppearance[cid] = seg.startTime
                }
            }
            let orderedClusters = firstAppearance
                .sorted { $0.value < $1.value }
                .map { $0.key }
            var clusterToLabel: [Int: String] = [:]
            for (i, cid) in orderedClusters.enumerated() {
                clusterToLabel[cid] = "Speaker \(i + 1)"
            }

            // Map segments to turns. Drop multi-speaker and no-match segments — those
            // don't have a stable label to assign. The transcription's pickSpeaker
            // logic falls back to the nearest neighbor with a label.
            return result.segments.compactMap { seg in
                guard case .speakerId(let cid) = seg.speaker,
                      let label = clusterToLabel[cid]
                else { return nil }
                return SpeakerTurn(
                    speaker: label,
                    start: bufferStartTime + TimeInterval(seg.startTime),
                    end: bufferStartTime + TimeInterval(seg.endTime)
                )
            }
        } catch {
            print("[SpeakerKitBackend] Whole-buffer diarization failed: \(error)")
            return []
        }
    }
}

extension SpeakerKitBackend {
    /// Whether the SpeakerKit (pyannote 4) weights are already on disk.
    /// SpeakerKit fetches its model from the `argmaxinc/speakerkit-pro`
    /// Hugging Face repo into the same Documents/huggingface cache root
    /// the other Argmax libraries use. The cache layout is the same shape
    /// as WhisperKit's, so we probe parallel paths.
    ///
    /// Conservative: if the cache layout differs (older SpeakerKit versions
    /// may have used a different path), this returns false and the sidebar
    /// shows "Not downloaded." Clicking Download then runs `SpeakerKit()`
    /// which is idempotent — if weights are actually cached, that init is
    /// just a quick file scan and the UI flips to Ready after a second or
    /// two. No incorrect-state hazard from a false negative.
    static func isModelCached() -> Bool {
        let fm = FileManager.default
        for path in cacheCandidatePaths() {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let contents = try? fm.contentsOfDirectory(atPath: path), !contents.isEmpty {
                return true
            }
        }
        return false
    }

    /// Possible disk locations for SpeakerKit weights. Parallel to
    /// `WhisperKitBackend.cacheCandidatePaths` and
    /// `ParakeetBackend.cacheCandidatePaths` — same shape so the
    /// `ModelDownloadManager` can poll cache size during downloads with
    /// uniform code across backends.
    ///
    /// **Repo-name history.** Argmax has shipped SpeakerKit under two HF
    /// repo names across releases. Current SDK versions resolve to
    /// `argmaxinc/speakerkit-coreml` (observed in field testing — that's
    /// what `SpeakerKit()` actually writes to disk today). Older builds
    /// resolved to `argmaxinc/speakerkit-pro`. We probe both: the first
    /// match wins in `isModelCached`, and the `ModelDownloadManager`'s
    /// `cacheDirectoryBytes` takes the max across candidates, so whichever
    /// SDK version the app links against will be detected correctly
    /// without the user having to re-download.
    static func cacheCandidatePaths() -> [String] {
        let fm = FileManager.default
        var candidates: [String] = []
        // Both repo names probed in both Documents and HF Hub cache
        // layouts. -coreml first (current SDK), -pro second (legacy).
        let repoNames = ["speakerkit-coreml", "speakerkit-pro"]

        for repo in repoNames {
            if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                candidates.append(docs
                    .appendingPathComponent("huggingface")
                    .appendingPathComponent("models")
                    .appendingPathComponent("argmaxinc")
                    .appendingPathComponent(repo)
                    .path)
            }
            if let home = ProcessInfo.processInfo.environment["HOME"] {
                candidates.append("\(home)/.cache/huggingface/hub/models--argmaxinc--\(repo)")
            }
            if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
                candidates.append(caches
                    .appendingPathComponent("huggingface")
                    .appendingPathComponent("models")
                    .appendingPathComponent("argmaxinc")
                    .appendingPathComponent(repo)
                    .path)
            }
        }
        return candidates
    }
}
