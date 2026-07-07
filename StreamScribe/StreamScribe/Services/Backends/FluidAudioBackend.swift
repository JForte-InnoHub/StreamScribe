import Foundation
import FluidAudio

/// FluidAudio-backed diarization. Combines two of FluidAudio's three
/// diarization options under a single user-facing engine:
///
///   - **Offline (`OfflineDiarizerManager`)**: pyannote Community-1 pipeline
///     (powerset segmentation + WeSpeaker embeddings + VBx Bayesian HMM
///     clustering). Used for static sessions via `diarizeWholeBuffer`.
///     No realistic speaker ceiling; produces stable IDs from VBx
///     clustering; best accuracy of FluidAudio's options for
///     batch use cases.
///
///   - **Streaming (`LSEENDDiarizer`)**: end-to-end neural diarization
///     with CoreML inference. Up to 10 speakers, 100 ms frame updates
///     with 900 ms tentative preview. Used for live sessions via
///     `diarize`. Marketed as FluidAudio's recommended online
///     diarizer — single model (no separate VAD/segmentation/embedding
///     stages), simpler pipeline than streaming pyannote, better
///     speaker capacity than NVIDIA Sortformer.
///
/// The third FluidAudio option, streaming `DiarizerManager` (pyannote
/// 3.1 segmentation + WeSpeaker streaming), is deliberately NOT exposed
/// here — FluidAudio's own docs note it's the slowest of the three and
/// only worth using if you need the modular pipeline for speaker
/// pre-enrollment or external clustering. Neither applies to our use
/// case.
///
/// **Why one backend instead of two engine kinds.** The session mode
/// (static vs live) is determined by the engine when it resolves
/// `resolvedSessionMode`, and the engine calls either
/// `diarizeWholeBuffer` (static) or `diarize` per chunk (live). The
/// backend doesn't need to know the mode upfront — it just routes
/// based on which method the engine calls. So one DiarizationEngineKind
/// option exposes both underlying models cleanly: the user picks
/// "FluidAudio" once and gets the right model automatically per session.
///
/// **License attribution.** FluidAudio SDK is Apache 2.0; the
/// pyannote-community-1 base model is cc-by-4.0; LS-EEND model is
/// MIT (per FluidInference's HF repo). All three require attribution
/// per their terms — see the About panel / NOTICES for credits.
///
/// **Cache location.** FluidAudio's SDK hardcodes
/// `~/Library/Application Support/FluidAudio/Models/` as its
/// download/load directory — `OfflineDiarizerModels.defaultModelsDirectory()`
/// returns it and there's no public API to redirect. StreamScribe
/// works around this by setting up a symlink at app launch (see
/// `StreamScribeApp.setupFluidAudioSymlink()`) that points the SDK's
/// hardcoded path at the unified models root:
/// `~/Library/Application Support/StreamScribe/Models/fluidaudio/`.
/// From the SDK's perspective nothing changes; from StreamScribe's
/// perspective all models live in one place.
///
/// Two download paths are supported:
///   1. **R2 mirror (preferred)**: `ModelDownloadManager` downloads
///      a single `fluidaudio.tar.gz` archive and extracts it to the
///      unified path. Skips the SDK's own download flow entirely.
///      Progress tracking comes from the same `MirrorDownloader`
///      delegate that Parakeet/Whisper use.
///   2. **HuggingFace fallback**: if the R2 mirror fails (tarball
///      missing, network error), `runDownload` falls through and
///      calls `prepare()` below. The SDK's own auto-download runs,
///      writing into the unified path via the symlink. Progress
///      tracking is approximate (disk-poll, since we don't control
///      the SDK's downloader).
///
/// Public API consumed (verified against FluidAudio 0.12.4 / 0.14.x):
///   - `OfflineDiarizerManager(config:)`, `prepareModels()`, `process(audio:)`
///   - `OfflineDiarizerConfig()` (default config)
///   - `LSEENDDiarizer(variant:)`, `processComplete(_:sourceSampleRate:)`
///   - `LSEENDDiarizer.Variant.dihard3` (DIHARD-3 trained variant)
///   - `ModelRegistry.baseURL` (static, for download-source override)
///   - Result shapes: `OfflineDiarizerResult.segments[].speakerId/startTimeSeconds/endTimeSeconds`,
///     `DiarizerTimeline.speakers[].index/finalizedSegments[].startTime/endTime`
actor FluidAudioBackend: DiarizationBackend {

    /// Offline pipeline manager. Loaded on first use (or in `prepare()`
    /// if the session will go static). nil until prepared.
    private var offlineManager: OfflineDiarizerManager?

    /// LS-EEND streaming diarizer. Loaded on first use. nil until prepared.
    /// Marked `Variant.dihard3` — the DIHARD-3 trained model, which is
    /// the FluidAudio default and what their benchmarks reference.
    private var lseendDiarizer: LSEENDDiarizer?

    /// Accumulated audio buffer for live mode. Each `diarize` call
    /// extends this buffer and re-runs LS-EEND on the growing whole.
    ///
    /// **Why accumulate rather than feed chunks individually.** LS-EEND
    /// exposes both streaming and complete-buffer APIs. The streaming
    /// API maintains state across calls and emits incremental results;
    /// the complete-buffer API (`processComplete`) processes the entire
    /// buffer at once with full context. For our initial integration we
    /// use the complete-buffer approach, accumulating chunks into
    /// `accumulatedBuffer` and re-running each tick. This costs CPU
    /// (every tick re-processes everything) but is the simplest
    /// integration and produces correct results.
    ///
    /// A future optimization is to switch to LS-EEND's true streaming
    /// API once we've verified the call shape — would reduce per-chunk
    /// cost from O(session length) to O(chunk size). Tracked as a
    /// follow-up; not on the critical path for getting the feature
    /// working.
    ///
    /// Memory note: typical session is bounded — a 2-hour senate
    /// hearing at 16 kHz mono Float32 is ~460 MB, comfortably within
    /// RAM on any modern Mac. Sessions longer than that would warrant
    /// a streaming switch.
    private var accumulatedBuffer: [Float] = []
    private var accumulatedStart: TimeInterval = 0

    /// Stable speaker label assignment for the live path. LS-EEND's
    /// per-call output uses 0-indexed speaker indices (`speaker.index`)
    /// that are reasonably stable across calls when processing the
    /// same buffer prefix, but we re-label by first-appearance time
    /// for consistency with SortformerBackend / SpeakerKitBackend.
    /// Cleared on `reset()`.
    private var liveLabelMap: [Int: String] = [:]

    init() {}

    func loadingDescription() -> String {
        "Loading FluidAudio (pyannote / LS-EEND)…"
    }

    /// Prepare both models. We don't know in advance whether the session
    /// will be static (using offline pyannote) or live (using LS-EEND),
    /// so we load both eagerly. Combined disk + memory footprint is
    /// manageable: offline pipeline is ~150 MB across its three CoreML
    /// bundles (segmentation + embedding + VAD), LS-EEND is ~100 MB.
    ///
    /// If a future split needed (lazy-load per session mode), the
    /// switch would be: stash the resolved session mode somewhere
    /// the backend can read at prepare time, and only init the model
    /// for that mode. Not worth doing speculatively.
    func prepare() async throws {
        // R2 mirror override. The user's setup uses an R2 mirror for
        // model downloads to bypass corporate-network blocks on
        // HuggingFace. ParakeetBackend and WhisperKitBackend already
        // route through R2; FluidAudio's `ModelRegistry.baseURL` is
        // the equivalent knob here. If the mirror key isn't set,
        // FluidAudio falls through to HuggingFace as default.
        if let mirrorURL = UserDefaults.standard.string(forKey: FluidAudioBackend.mirrorURLKey),
           !mirrorURL.isEmpty {
            ModelRegistry.baseURL = mirrorURL
            print("[FluidAudio] Using R2 mirror: \(mirrorURL)")
        }

        // Offline pipeline. `prepareModels()` downloads + Core ML-compiles
        // all three model bundles (segmentation, embedding, VAD) into the
        // FluidAudio cache. Idempotent — no-op if already cached.
        if offlineManager == nil {
            let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
            try await manager.prepareModels()
            self.offlineManager = manager
            print("[FluidAudio] Offline diarizer ready.")
        }

        // LS-EEND streaming diarizer. Constructor handles download +
        // compile, similar to OfflineDiarizerManager.prepareModels.
        if lseendDiarizer == nil {
            let diarizer = try await LSEENDDiarizer(variant: .dihard3)
            self.lseendDiarizer = diarizer
            print("[FluidAudio] LS-EEND streaming diarizer ready.")
        }
    }

    /// Live-mode per-chunk diarization via LS-EEND.
    ///
    /// **Approach.** Accumulate samples into `accumulatedBuffer`, then run
    /// `LSEENDDiarizer.processComplete` on the growing buffer each tick.
    /// LS-EEND's complete-buffer API processes everything at once with
    /// full context — correct results but O(buffer length) per call.
    ///
    /// **Why this is acceptable for now.** Live diarization runs at
    /// ~5-second chunk intervals. Even on a long session, LS-EEND's
    /// realtime factor is high enough (~50-100x) that processing a
    /// 30-minute accumulated buffer in <30 seconds still keeps us
    /// comfortably ahead of the audio. For 2-hour senate hearings it
    /// would start to lag — that's the threshold at which the
    /// switch-to-true-streaming optimization becomes necessary.
    ///
    /// **Sample rate.** LS-EEND expects 16 kHz mono Float32. Our pipeline
    /// already feeds 16 kHz mono samples to all backends, so no
    /// conversion is needed.
    func diarize(samples: [Float], chunkStartTime: TimeInterval) async -> [SpeakerTurn] {
        guard let diarizer = lseendDiarizer else { return [] }
        guard samples.count >= 16_000 else { return [] }

        // Track the absolute timeline offset of where the accumulated
        // buffer begins. The first chunk's chunkStartTime IS the buffer
        // start; subsequent chunks just extend the buffer.
        if accumulatedBuffer.isEmpty {
            accumulatedStart = chunkStartTime
        }
        accumulatedBuffer.append(contentsOf: samples)

        do {
            let timeline = try diarizer.processComplete(
                accumulatedBuffer,
                sourceSampleRate: 16_000
            )

            // Map LS-EEND's per-speaker finalized segments into our flat
            // SpeakerTurn array. processComplete only includes finalized
            // segments here — the 900ms tentative preview is internal and
            // doesn't surface, matching what Sortformer does (we don't
            // expose tentative there either).
            var turns: [SpeakerTurn] = []
            for (_, speaker) in timeline.speakers {
                let label = stableLabel(forIndex: speaker.index)
                for segment in speaker.finalizedSegments {
                    // Add accumulatedStart so segment times land on the
                    // absolute session timeline rather than buffer-local time.
                    turns.append(SpeakerTurn(
                        speaker: label,
                        start: accumulatedStart + TimeInterval(segment.startTime),
                        end: accumulatedStart + TimeInterval(segment.endTime)
                    ))
                }
            }
            return turns
        } catch {
            #if DEBUG
            print("[FluidAudio] LS-EEND processComplete error: \(error)")
            #endif
            return []
        }
    }

    /// Static-mode whole-buffer diarization via offline pyannote-community-1
    /// pipeline. Best path for senate hearings and other multi-speaker
    /// archived recordings — VBx clustering produces stable speaker IDs
    /// across hours of audio without the chunk-boundary instability
    /// the streaming backends have.
    func diarizeWholeBuffer(samples: [Float], bufferStartTime: TimeInterval) async -> [SpeakerTurn] {
        guard let manager = offlineManager else { return [] }
        guard samples.count >= 16_000 else { return [] }

        do {
            let result = try await manager.process(audio: samples)

            // Map pyannote's result format to our SpeakerTurn array.
            // OfflineDiarizerResult.segments has speakerId (String) and
            // start/endTimeSeconds (Float — wrapped via TimeInterval()
            // since SpeakerTurn / our timeline math uses Double, and
            // Swift doesn't auto-promote Float + Double).
            // speakerId is something like "SPEAKER_00", "SPEAKER_01", etc.
            // We relabel by first appearance to match SortformerBackend
            // and SpeakerKitBackend conventions.
            let raw = result.segments.map { seg in
                SpeakerTurn(
                    speaker: seg.speakerId,
                    start: bufferStartTime + TimeInterval(seg.startTimeSeconds),
                    end: bufferStartTime + TimeInterval(seg.endTimeSeconds)
                )
            }
            return FluidAudioBackend.relabelByFirstAppearance(raw)
        } catch {
            #if DEBUG
            print("[FluidAudio] Offline diarizer error: \(error)")
            #endif
            return []
        }
    }

    /// Reset streaming state. Called between sessions. Drops the
    /// accumulated buffer and the label map so the next session starts
    /// fresh. Doesn't unload models — those stay resident until `unload()`.
    func reset() async {
        accumulatedBuffer = []
        accumulatedStart = 0
        liveLabelMap = [:]
    }

    /// Release model resources. Matches Sortformer / Parakeet's pattern.
    /// FluidAudio's manager + diarizer types don't expose explicit
    /// unload APIs, so we just nil out the references and let ARC
    /// reclaim the CoreML buffers.
    func unload() async {
        offlineManager = nil
        lseendDiarizer = nil
        accumulatedBuffer = []
        accumulatedStart = 0
        liveLabelMap = [:]
        print("[FluidAudio] unloaded models.")
    }

    /// Slice audio from the accumulated buffer for a given time range.
    /// Used by `TranscriptionEngine.runVoiceprintIdentification` to
    /// pull per-cluster audio for WeSpeaker extraction.
    ///
    /// **Time origin.** Time ranges are in session-wall-clock seconds,
    /// matching what `SpeakerTurn` and segment fields use. The buffer
    /// stores audio starting at `accumulatedStart`; sample index is
    /// `(time - accumulatedStart) × 16000`.
    ///
    /// **Out-of-buffer behavior.** Returns empty if the requested
    /// range falls entirely outside the buffer's current contents.
    /// Clips the range to whatever portion IS in the buffer if it
    /// overlaps partially. The buffer gets trimmed periodically by
    /// the live diarization loop, so requests for old time ranges
    /// will return progressively less audio over time.
    ///
    /// **Sample rate is hardcoded** at 16,000 — matches the
    /// FluidAudio pipeline's expected rate and `accumulatedBuffer`'s
    /// content rate. If the pipeline ever moves to a different rate
    /// this needs to update in lockstep.
    func sliceAccumulatedBuffer(from startTime: TimeInterval, to endTime: TimeInterval) -> [Float] {
        let sampleRate: Double = 16_000
        let bufferStart = accumulatedStart
        let bufferEnd = bufferStart + Double(accumulatedBuffer.count) / sampleRate

        let clipStart = max(startTime, bufferStart)
        let clipEnd = min(endTime, bufferEnd)
        guard clipEnd > clipStart else { return [] }

        let startIdx = Int((clipStart - bufferStart) * sampleRate)
        let endIdx = Int((clipEnd - bufferStart) * sampleRate)
        guard startIdx >= 0,
              endIdx <= accumulatedBuffer.count,
              startIdx < endIdx else {
            return []
        }

        return Array(accumulatedBuffer[startIdx..<endIdx])
    }

    /// **OBSOLETE.** Originally intended to expose per-cluster
    /// embeddings from LSEEND's internal state, but LSEEND's
    /// end-to-end architecture doesn't surface WeSpeaker embeddings.
    /// Embeddings now come from `WeSpeakerExtractor` via
    /// `sliceAccumulatedBuffer` + `DiarizerManager`. This method is
    /// kept as a no-op so the older integration path in
    /// `TranscriptionEngine` compiles during the transition; it will
    /// be removed once that path is fully migrated.
    func currentSpeakerEmbeddings() -> [String: [Float]] {
        return [:]
    }

    // MARK: - Live-mode label stability

    /// Map LS-EEND's numeric speaker index to a stable "Speaker N" label
    /// using first-appearance order. LS-EEND's index numbering should be
    /// stable across calls when processing the same buffer prefix, but
    /// we add this layer so the user-visible labels are deterministic
    /// and match the convention used by Sortformer / SpeakerKit
    /// ("Speaker 1", "Speaker 2", etc., assigned in order of first voice
    /// on the timeline).
    private func stableLabel(forIndex index: Int) -> String {
        if let existing = liveLabelMap[index] {
            return existing
        }
        let label = "Speaker \(liveLabelMap.count + 1)"
        liveLabelMap[index] = label
        return label
    }

    // MARK: - Static-mode post-processing helpers

    /// Relabel raw pyannote speaker IDs (e.g. "SPEAKER_00", "SPEAKER_03")
    /// to "Speaker N" based on order of first appearance on the timeline.
    /// Mirrors SortformerBackend.relabelByFirstAppearance so users get
    /// consistent label conventions across diarizers.
    ///
    /// Note that pyannote's IDs are not necessarily in temporal order
    /// (it might assign SPEAKER_03 first if its clustering algorithm
    /// happened to discover that cluster first), so this relabel pass
    /// is necessary, not cosmetic.
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

extension FluidAudioBackend {
    /// UserDefaults key for the optional R2 mirror URL. Set via Settings
    /// → Advanced; absence means use HuggingFace as FluidAudio's default
    /// download source.
    static let mirrorURLKey = "fluidAudio.mirrorURL"

    /// Best-effort check for whether FluidAudio's models are already
    /// cached on disk. Checks the unified models path
    /// (`~/Library/Application Support/StreamScribe/Models/fluidaudio/`,
    /// returned by `fluidAudioCacheDirectory()`). We check whether
    /// the directory exists and contains at least one entry — not a
    /// perfect indicator (could be a partial download from an
    /// interrupted prepare()) but good enough for the sidebar's
    /// pre-download status indicator.
    ///
    /// More accurate per-model checks would require knowing FluidAudio's
    /// internal model subdirectory layout, which isn't part of their
    /// public API contract. Worst case if this returns false-positive
    /// "cached": the next session start does a download anyway, with
    /// progress visible in the SDK's logs.
    /// Whether FluidAudio's CoreML model bundles are already on disk.
    ///
    /// **Path:** `~/Library/Application Support/StreamScribe/Models/fluidaudio/`
    /// (the unified models root). Files written here are visible to
    /// the FluidAudio SDK via the symlink set up by
    /// `StreamScribeApp.setupFluidAudioSymlink()` — the SDK's
    /// hardcoded `~/Library/Application Support/FluidAudio/Models/`
    /// resolves to this directory.
    ///
    /// **Heuristic only.** A user manually deleting individual files
    /// inside this directory wouldn't be detected here, and a future
    /// FluidAudio update could add new required bundles we don't
    /// check for. The function returns true when ANY content exists
    /// at the path, treating "non-empty directory" as a proxy for
    /// "probably cached" — the real source of truth is FluidAudio's
    /// own `DiarizerModels.downloadIfNeeded()` which probes individual
    /// `.mlmodelc` bundles against its public API contract. Worst
    /// case if this returns false-positive "cached": the next session
    /// start does a download anyway, with progress visible in the
    /// SDK's logs.
    static func isModelCached() -> Bool {
        let cacheDir = fluidAudioCacheDirectory()
        guard FileManager.default.fileExists(atPath: cacheDir.path) else {
            return false
        }
        // Check that the directory has content. Empty cache dir doesn't
        // count as cached — could be a leftover from a wiped install.
        let contents = try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        return (contents?.isEmpty == false)
    }

    /// Canonical path where FluidAudio's CoreML model bundles live on
    /// disk. Returns the unified StreamScribe path
    /// (`~/Library/Application Support/StreamScribe/Models/fluidaudio/`)
    /// rather than FluidAudio's hardcoded SDK path
    /// (`~/Library/Application Support/FluidAudio/Models/`).
    ///
    /// Both paths point at the same physical files — the SDK's path
    /// is set up as a symlink to the unified path at app launch by
    /// `StreamScribeApp.setupFluidAudioSymlink()`. We prefer the
    /// unified path here so reads don't depend on symlink traversal
    /// behavior, and so debugging output (which sometimes prints
    /// this path) shows the user-friendly canonical location.
    ///
    /// If the symlink isn't set up for whatever reason (early launch
    /// failure, manual filesystem tampering), this still returns the
    /// unified path. FluidAudio's auto-download would then write to
    /// its own hardcoded path while our code reads from the unified
    /// path — `isModelCached` would return false despite files
    /// existing under the SDK path. Acceptable failure mode: the
    /// next download via our R2 mirror writes to the unified path,
    /// after which both paths see the same files.
    static func fluidAudioCacheDirectory() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library")
                .appendingPathComponent("Application Support")
        return appSupport
            .appendingPathComponent("StreamScribe")
            .appendingPathComponent("Models")
            .appendingPathComponent("fluidaudio")
    }
}
