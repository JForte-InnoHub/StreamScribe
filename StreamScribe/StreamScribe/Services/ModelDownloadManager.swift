import Foundation
import Combine

/// Tracks the on-disk presence and active download/load state of the ML model
/// weights each backend needs. Companion to `ToolManager` — same shape and same
/// UI conventions (status enum with `.label` for display, inline `ProgressView`
/// while a download is in flight), but for the per-engine model weights rather
/// than the CLI tools.
///
/// **Why this exists.** Before this manager, the very first time the user hit
/// Start on a fresh install, the transcription engine's `prepare()` call would
/// silently block for tens of seconds — or several minutes for the large
/// Whisper variants — while WhisperKit/mlx-audio-swift/SpeakerKit downloaded
/// model weights from Hugging Face. The status pill showed "Loading Whisper
/// model …" but with no progress indicator and no log output that looked like
/// download activity. Users reported the app looked hung. This manager:
///
///   1. Surfaces a persistent per-model presence indicator in the sidebar so
///      users can see at a glance which models are already cached vs. need to
///      be fetched.
///   2. Provides a "Download" button next to each model picker that lets users
///      pre-fetch the weights before starting a transcription, with a real
///      progress bar showing bytes downloaded vs. estimated total.
///   3. Mirrors status updates from the in-pipeline `prepare()` path so the
///      same UI element animates whether the download was triggered explicitly
///      via the button OR implicitly by the user just clicking Start.
///   4. Distinguishes the "downloading from network" phase from the "loading
///      weights into memory" phase that follows — the libraries we wrap don't
///      tell us when they're done with the network, but a stalled cache-
///      directory size is a strong heuristic, and the distinction matters
///      because the load phase can itself take 5-30 seconds for large models.
///
/// **How progress works.** The download libraries (WhisperKit's WhisperKit
/// config, mlx-audio-swift's `fromPretrained`, SpeakerKit's init) don't expose
/// per-byte progress callbacks for their multi-file HF repo fetches, even
/// though swift-transformers itself supports it — the wrappers swallow the
/// callback. So instead, while a `prepare()` runs we poll the cache directory
/// for the relevant model every 500ms and surface the live byte count to the
/// UI. We pair that with hardcoded per-model size estimates (see
/// `estimatedBytes(for:)`) to compute a percentage — approximate, but stable
/// enough that the user can tell "still progressing" from "stuck."
///
/// **Isolation.** Not `@MainActor`-isolated as a class — same pattern as
/// `ToolManager` and for the same reason: `@StateObject` default-value
/// initialization in `StreamScribeApp` runs in the non-isolated `App` struct
/// init context, and a MainActor-isolated init would either fail to compile
/// under strict concurrency checking or fail at runtime to populate the
/// `@StateObject` (which manifests downstream as a missing-EnvironmentObject
/// crash when child views go to read it). Instead, the published-state
/// mutations hop to MainActor explicitly via `Task { @MainActor in ... }`
/// or `await MainActor.run {}` from the engine pipeline, mirroring
/// `ToolManager.setStatus`.
final class ModelDownloadManager: ObservableObject {

    static let shared = ModelDownloadManager()

    /// Identifies a specific model variant we can track. Whisper and Parakeet
    /// have user-pickable model lists, so they carry the model name as an
    /// associated value; Sortformer and SpeakerKit each have a single canonical
    /// model that the user can't change today, so they're plain cases.
    ///
    /// Conformance to `Hashable` lets us use this as a dictionary key for the
    /// per-model status storage.
    enum ModelKey: Hashable {
        case whisper(modelName: String)
        case parakeet(modelRepo: String)
        case sortformer
        case speakerKit
        case fluidAudio
        case canary

        /// Short identifier for log lines. Avoids dumping a full repo path
        /// into every status print.
        var logTag: String {
            switch self {
            case .whisper(let n):  return "whisper:\(n)"
            case .parakeet(let r): return "parakeet:\(r)"
            case .sortformer:      return "sortformer"
            case .speakerKit:      return "speakerKit"
            case .canary:          return "canary"
            case .fluidAudio:      return "fluidAudio"
            }
        }
    }

    /// Per-model status. Mirrors `ToolManager.YTDlpStatus`/`DenoStatus` shape so
    /// the sidebar can render it with the same components.
    ///
    /// **Indeterminate progress.** The underlying download libraries
    /// (WhisperKit, mlx-audio-swift, SpeakerKit) don't expose any usable
    /// progress callback for their HF Hub fetches. We tried (a) polling
    /// the cache directory size — fails because the library writes to
    /// temp files and renames at completion, so the size jumps from 0 to
    /// total in one step; (b) parsing the library's terminal-style log
    /// lines — fragile and the cadence wasn't useful; (c) pre-fetching
    /// via swift-huggingface's `HubClient` directly — works but mlx-
    /// audio-swift uses its own custom cache subpath (`hub/mlx-audio/
    /// <org>_<name>`) instead of the standard HF Hub layout, so we'd
    /// download everything twice. Verdict: the libraries don't give us
    /// progress, and there's no clever workaround.
    ///
    /// So `.downloading` is an **indeterminate spinner with elapsed
    /// time** — honest about what we know. The UI renders an
    /// indeterminate `ProgressView` (animated barberpole) plus a label
    /// like "Downloading… 0:37" so the user can at least see the
    /// process is alive.
    enum ModelStatus: Equatable {
        /// We haven't probed disk yet for this model. Treated as a "show
        /// nothing yet" state in the UI — no Download button, no label —
        /// since making a positive claim ("Not downloaded") before checking
        /// would be wrong. Quickly transitions to `.cached` or `.notDownloaded`
        /// once `refreshAllOnDiskStatuses` runs at launch.
        case unknown
        /// On disk and ready to load. We check by probing known cache paths;
        /// see `isCached(_:)` for the per-backend logic.
        case cached
        /// Probe completed and the model is not on disk. Distinct from
        /// `.unknown` so the UI can show the Download button only when we're
        /// sure it's needed.
        case notDownloaded
        /// `prepare()` is in flight and the model wasn't already on disk —
        /// we're actually downloading bytes over the network.
        ///
        /// **Carries:** the start timestamp so the UI can show elapsed time
        /// ("Downloading… 0:37"), and an optional progress fraction (0...1).
        ///
        /// **Why `progress` is optional.** Three regimes:
        ///   1. Mirror downloads (R2 tarballs, the default path) — we use
        ///      `URLSessionDownloadDelegate` and get exact byte progress
        ///      from `didWriteData`. Progress = non-nil from the first
        ///      chunk onward.
        ///   2. FluidAudio — its library manages its own per-file
        ///      downloads, so we disk-poll the cache directory against a
        ///      known total size. Progress = approximate but non-nil.
        ///   3. HuggingFace fallback (when the R2 mirror is missing or
        ///      fails) — we hand control to the library's own loader and
        ///      have no per-byte visibility. Progress = nil; UI falls
        ///      back to an indeterminate spinner.
        ///
        /// Initial state on entering this case is `progress: nil` (we
        /// haven't received the first delegate callback yet); the value
        /// updates to non-nil within a few hundred ms once the download
        /// begins streaming bytes.
        case downloading(startedAt: Date, progress: Double?)
        /// `prepare()` is in flight but the model IS already on disk —
        /// no network, just CoreML/MLX weights being loaded into RAM.
        /// Distinct from `.downloading` because the previous label
        /// ("Downloading…") was misleading users into thinking a
        /// re-download was happening when it wasn't. Same timestamp +
        /// indeterminate-spinner UX, but the label reads "Loading…"
        /// instead. Typical duration: 1-10 seconds.
        case loading(startedAt: Date)
        /// `prepare()` completed successfully. Distinct from `.cached` because
        /// it implies the weights are not just on disk but have been loaded
        /// into memory at least once this app launch — useful diagnostic info
        /// for the user when triaging slow first chunks.
        case ready
        case error(String)

        var label: String {
            switch self {
            case .unknown:                  return ""
            case .cached:                   return "Downloaded"
            case .notDownloaded:            return "Not downloaded"
            case .downloading(let start, let progress):
                let elapsed = Int(Date().timeIntervalSince(start))
                let mins = elapsed / 60
                let secs = elapsed % 60
                if let progress {
                    // Clamp defensively — the delegate has occasionally
                    // been observed to report `totalBytesExpectedToWrite`
                    // as -1 on servers that don't send Content-Length, in
                    // which case division yields negative/NaN values that
                    // were already filtered at the call site. The clamp
                    // here is belt-and-suspenders insurance for an
                    // unexpected value sneaking through.
                    let clamped = max(0.0, min(1.0, progress))
                    let pct = Int(clamped * 100)
                    return String(format: "Downloading… %d:%02d (%d%%)", mins, secs, pct)
                }
                return String(format: "Downloading… %d:%02d", mins, secs)
            case .loading(let start):
                let elapsed = Int(Date().timeIntervalSince(start))
                let mins = elapsed / 60
                let secs = elapsed % 60
                return String(format: "Loading… %d:%02d", mins, secs)
            case .ready:                    return "Ready"
            case .error(let m):             return "Error: \(m)"
            }
        }
    }

    /// Per-model status keyed by `ModelKey`. Reading a missing key returns
    /// `.unknown` — see the `status(_:)` accessor.
    @Published private(set) var statuses: [ModelKey: ModelStatus] = [:]

    /// `@MainActor` because all reads come from SwiftUI views (which run on
    /// main) and we don't want to expose non-main reads of `@Published`
    /// state — concurrent access would race with the publish path.
    @MainActor
    func status(_ key: ModelKey) -> ModelStatus {
        statuses[key] ?? .unknown
    }

    // MARK: - Initial probe

    /// Probes disk for every model variant currently selectable in the UI and
    /// seeds `statuses` accordingly. Called at app launch and again whenever
    /// we want a fresh disk-truth read (e.g. after a download completes).
    ///
    /// Preserves "in-flight" states: if a model is currently `.downloading`
    /// or `.loading` when the probe runs, we leave that alone — don't
    /// downgrade it to `.cached` just because the partial files happen to
    /// be on disk during the active download. Same for `.ready` (in-memory
    /// model is loaded — the `.ready` label is more informative than
    /// `.cached`).
    @MainActor
    func refreshAllOnDiskStatuses() {
        print("[ModelDownload] Refreshing all on-disk statuses…")
        var next = statuses
        var transitions: [String] = []

        func setIfNotInFlight(_ key: ModelKey, _ newStatus: ModelStatus) {
            let current = next[key] ?? .unknown
            switch current {
            case .downloading, .loading, .ready:
                // Don't disturb in-flight or just-loaded state.
                return
            default:
                break
            }
            if current != newStatus {
                transitions.append("\(key.logTag): \(stateName(current)) → \(stateName(newStatus))")
            }
            next[key] = newStatus
        }

        for name in TranscriptionEngine.availableWhisperModels {
            let key = ModelKey.whisper(modelName: name)
            setIfNotInFlight(key, isCached(key) ? .cached : .notDownloaded)
        }
        for repo in TranscriptionEngine.availableParakeetModels {
            let key = ModelKey.parakeet(modelRepo: repo)
            setIfNotInFlight(key, isCached(key) ? .cached : .notDownloaded)
        }
        setIfNotInFlight(.sortformer, isCached(.sortformer) ? .cached : .notDownloaded)
        setIfNotInFlight(.speakerKit, isCached(.speakerKit) ? .cached : .notDownloaded)

        statuses = next
        if transitions.isEmpty {
            print("[ModelDownload] Probe complete; no status changes.")
        } else {
            print("[ModelDownload] Probe complete; transitions:")
            for line in transitions {
                print("[ModelDownload]   \(line)")
            }
        }
    }

    /// Convenience for log messages.
    private func stateName(_ s: ModelStatus) -> String {
        switch s {
        case .unknown: return "unknown"
        case .cached: return "cached"
        case .notDownloaded: return "notDownloaded"
        case .downloading: return "downloading"
        case .loading: return "loading"
        case .ready: return "ready"
        case .error: return "error"
        }
    }

    // MARK: - On-disk probes

    /// Whether the model weights for `key` are currently on disk. Routes to
    /// each backend's `isModelCached` helper; the cache-path knowledge stays
    /// local to the backend that produced it.
    ///
    /// Non-isolated: pure disk probe, safe to call from any context.
    nonisolated func isCached(_ key: ModelKey) -> Bool {
        let cached: Bool
        switch key {
        case .whisper(let name):
            cached = WhisperKitBackend.isModelCached(modelName: name)
        case .parakeet(let repo):
            cached = ParakeetBackend.isModelCached(modelRepo: repo)
        case .sortformer:
            cached = SortformerBackend.isModelCached()
        case .speakerKit:
            cached = SpeakerKitBackend.isModelCached()
        case .fluidAudio:
            cached = FluidAudioBackend.isModelCached()
        case .canary:
            cached = CanaryBackend.isModelCached()
        }
        print("[ModelDownload] Probe \(key.logTag): \(cached ? "cached" : "not on disk")")
        return cached
    }

    // MARK: - Status updates

    @MainActor
    func markDownloading(_ key: ModelKey) {
        let prev = statuses[key] ?? .unknown
        statuses[key] = .downloading(startedAt: Date(), progress: nil)
        print("[ModelDownload] \(key.logTag): \(stateName(prev)) → downloading")
    }

    /// Update the progress fraction inside an in-flight `.downloading`
    /// status without resetting the start timestamp. Called repeatedly
    /// from:
    ///   - The R2 mirror download delegate (`MirrorDownloader`'s
    ///     `didWriteData`) at every received chunk
    ///   - The FluidAudio disk poller (a separate Task that watches
    ///     `~/Library/Application Support/FluidAudio/Models/`)
    ///
    /// If the current status is not `.downloading` (e.g. it raced with
    /// a transition to `.loading` after the download completed), this
    /// no-ops. Safe to call from any thread — hops to MainActor for the
    /// publish, like every other status mutation in this manager.
    ///
    /// Progress is clamped to 0...1 here as well as in the label
    /// accessor; the double-clamp is defensive cheap insurance and not
    /// otherwise meaningful.
    @MainActor
    private func updateDownloadProgress(_ key: ModelKey, progress: Double) {
        guard case .downloading(let start, _) = statuses[key] else { return }
        let clamped = max(0.0, min(1.0, progress))
        statuses[key] = .downloading(startedAt: start, progress: clamped)
    }

    // MARK: - Cache management (debug)

    /// Delete every model cache directory we know about, then refresh
    /// statuses so the sidebar reflects the post-wipe state. Returns the
    /// list of paths the wipe attempted (including ones that didn't
    /// exist), for the caller to surface in a confirmation dialog or log.
    ///
    /// **Debug-only.** Wired up via the Debug menu's "Clear Model Cache"
    /// item — not exposed in the main UI. The intended use case is
    /// testing the download flow itself (verifying progress bars,
    /// error states, R2-vs-HF fallback paths) without manually `rm
    /// -rf`-ing cache directories from the terminal.
    ///
    /// **What gets deleted:**
    ///   - `~/Library/Application Support/StreamScribe/Models/` — the
    ///     unified models root. Wipes both the `huggingface/` subdirectory
    ///     (Parakeet, Whisper, Sortformer, SpeakerKit) and the
    ///     `fluidaudio/` subdirectory (FluidAudio's CoreML bundles).
    ///   - `~/Library/Application Support/FluidAudio/Models/` — the
    ///     symlink the SDK uses. Whether this resolves to our
    ///     unified root (the common case) or is a stale real
    ///     directory from a pre-consolidation install, removing it
    ///     ensures the symlink is recreated cleanly on next launch.
    ///
    /// We don't try to be surgical (deleting only the specific repos
    /// StreamScribe uses) because:
    ///   - The candidate-path logic varies per backend
    ///   - This is a debug feature, not a user-facing one
    ///   - The user who clicks this button knows what they're doing
    ///
    /// WhisperKit's cache isn't covered here — it lives under
    /// `~/Library/Application Support/WhisperKit/` (system-managed,
    /// per the SDK's own conventions). If you're testing WhisperKit
    /// redownloads, you'll need to wipe that path separately. Not
    /// included because most StreamScribe testing centers on
    /// Parakeet/FluidAudio (the new defaults) and the unified root.
    ///
    /// Errors per-path are caught and logged but don't abort the
    /// overall wipe — best-effort. The returned list says what was
    /// attempted, not what succeeded.
    nonisolated func clearAllModelCaches() async -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library").appendingPathComponent("Application Support")

        let pathsToWipe: [URL] = [
            // Unified models root — primary deletion target. Wipes
            // everything under StreamScribe/Models/ (huggingface/ +
            // fluidaudio/ + anything else we add later).
            appSupport.appendingPathComponent("StreamScribe").appendingPathComponent("Models"),
            // FluidAudio symlink at the SDK's hardcoded path. Removing
            // the symlink itself (not following it) — the next launch
            // recreates it pointing at the freshly-empty unified root.
            // If it's somehow not a symlink (older install), removing
            // is still the right thing: clears whatever stale state
            // was there.
            appSupport.appendingPathComponent("FluidAudio").appendingPathComponent("Models"),
        ]

        var attempted: [String] = []
        for path in pathsToWipe {
            attempted.append(path.path)
            guard fm.fileExists(atPath: path.path) else {
                print("[ModelDownload] clearAllModelCaches: \(path.path) does not exist, skipping")
                continue
            }
            do {
                try fm.removeItem(at: path)
                print("[ModelDownload] clearAllModelCaches: removed \(path.path)")
            } catch {
                print("[ModelDownload] clearAllModelCaches: FAILED to remove \(path.path) — \(error.localizedDescription)")
            }
        }

        // Re-probe disk so the sidebar's status indicators flip from
        // .cached → .notDownloaded for the models we just deleted.
        await MainActor.run {
            self.refreshAllOnDiskStatuses()
        }

        return attempted
    }

    /// Mark a prepare-in-flight where the model is already on disk —
    /// the work is a CoreML/MLX weights load into RAM, NOT a network
    /// download. Distinct from `markDownloading` so the UI label reads
    /// "Loading…" instead of the misleading "Downloading…". Same
    /// indeterminate-spinner + elapsed-time UX otherwise.
    @MainActor
    func markLoading(_ key: ModelKey) {
        let prev = statuses[key] ?? .unknown
        statuses[key] = .loading(startedAt: Date())
        print("[ModelDownload] \(key.logTag): \(stateName(prev)) → loading")
    }

    /// After `prepare()` completes, re-probe disk and pick the best status.
    /// `.ready` (in-memory loaded) is preferred when the model is actually on
    /// disk, since "Ready" is the most informative label. Falls back to
    /// `.cached` if for some reason the disk probe doesn't see the files
    /// (unexpected — the library just successfully loaded them — but
    /// defensive).
    @MainActor
    func markReady(_ key: ModelKey) {
        statuses[key] = .ready
        print("[ModelDownload] \(key.logTag): → ready (prepare() succeeded)")
    }

    @MainActor
    func markError(_ key: ModelKey, message: String) {
        statuses[key] = .error(message)
        print("[ModelDownload] \(key.logTag): → error: \(message)")
    }

    /// MainActor-isolated read of the current status — used by `runDownload`
    /// to check the double-start guard from its non-isolated context.
    @MainActor
    private func currentStatus(_ key: ModelKey) -> ModelStatus {
        statuses[key] ?? .unknown
    }

    // MARK: - Explicit downloads (sidebar buttons)

    func downloadWhisperModel(name: String) async {
        let key = ModelKey.whisper(modelName: name)
        await runDownload(key: key) {
            let backend = WhisperKitBackend(
                modelName: name,
                languageCode: nil,
                computeUnits: .auto,
                role: "prefetch"
            )
            try await backend.prepare()
        }
    }

    func downloadParakeetModel(repo: String) async {
        let key = ModelKey.parakeet(modelRepo: repo)
        await runDownload(key: key) {
            let backend = ParakeetBackend(modelRepo: repo, chunkDuration: 5.0)
            try await backend.prepare()
        }
    }

    /// Manual Canary bundle download (R2 tarball) — download and
    /// load testable separately, like the other models.
    func downloadCanaryModel() async {
        await runDownload(key: .canary) {
            try await CanaryBackend.downloadModels()
        }
    }

    func downloadSortformerModel() async {
        await runDownload(key: .sortformer) {
            let backend = SortformerBackend()
            try await backend.prepare()
        }
    }

    func downloadSpeakerKitModel() async {
        await runDownload(key: .speakerKit) {
            let backend = SpeakerKitBackend()
            try await backend.prepare()
        }
    }

    /// Pre-download FluidAudio's models without starting a session. Same
    /// shape as the other download methods — uses `runDownload` for the
    /// status scaffolding, calls `FluidAudioBackend.prepare()` which
    /// downloads + compiles both the offline pyannote pipeline (3 CoreML
    /// bundles: segmentation + embedding + VAD) AND the LS-EEND streaming
    /// model. The backend's prepare loads both eagerly because it can't
    /// know in advance whether the user's next session will be static
    /// or live.
    ///
    /// Backend memory is released after prepare returns by instantiating
    /// it locally — the local reference goes out of scope as soon as the
    /// closure exits, letting ARC reclaim the CoreML buffers. Same trick
    /// the SortformerBackend pre-download uses.
    func downloadFluidAudioModel() async {
        // Spawn a disk-poll task in parallel with prepare() so the UI
        // sees a progress percentage during FluidAudio's download.
        // Unlike the R2 mirror path, we don't control FluidAudio's
        // downloader (it's inside the SDK), so we approximate progress
        // by watching the cache directory size against an expected
        // total. The expected total is a conservative estimate of the
        // pyannote pipeline (~150 MB) + LSEEND dihard3 (~100 MB) =
        // ~250 MB. Real-world transfer size varies with model variant
        // and HF response headers; the percentage will be approximate.
        //
        // The poller starts at the same time prepare() does and
        // cancels when prepare() returns (success or throw). It
        // updates `statuses[.fluidAudio]` via `updateDownloadProgress`,
        // which no-ops harmlessly if the state has already moved to
        // `.loading` (post-download, pre-ready).
        let pollerTask = Task { [weak self] in
            await self?.pollFluidAudioCacheSize(key: .fluidAudio)
        }
        await runDownload(key: .fluidAudio) {
            let backend = FluidAudioBackend()
            try await backend.prepare()
            // Explicit unload here as a belt-and-suspenders. The local
            // reference would be released anyway when the closure exits,
            // but FluidAudio's CoreML buffers are large enough that we
            // want to be explicit about reclaiming them before the
            // surrounding await chain returns control to the UI.
            await backend.unload()
        }
        pollerTask.cancel()
    }

    /// Approximate total size of FluidAudio's combined model bundles
    /// after download + CoreML compilation. Used to compute a percentage
    /// in `pollFluidAudioCacheSize` without a per-file HEAD request.
    ///
    /// The expected size is the SUM of:
    ///   - Offline pyannote pipeline (segmentation + embedding + VAD
    ///     CoreML bundles): ~150 MB on disk after compilation
    ///   - LS-EEND dihard3 variant CoreML bundle: ~100 MB on disk
    ///
    /// Tracked as a constant rather than a configured value because
    /// FluidAudio's model versions change rarely; if they do, the
    /// progress percentage gets slightly off and we adjust the
    /// constant on the next release.
    private static let fluidAudioExpectedTotalBytes: Int64 = 250 * 1024 * 1024

    /// Poll FluidAudio's cache directory every 500 ms, computing the
    /// download progress as `current_dir_size / expected_total`.
    /// Runs until the task is cancelled (which happens when prepare()
    /// returns in `downloadFluidAudioModel`).
    ///
    /// Read-only filesystem traversal — `enumerator(at:includingPropertiesForKeys:)`
    /// walks the directory tree once per tick, summing file sizes.
    /// For ~250 MB across a few dozen files, this is well under 1 ms
    /// on local SSD; the polling interval is the dominant cost.
    private func pollFluidAudioCacheSize(key: ModelKey) async {
        // Use FluidAudioBackend's canonical path resolver. The actual
        // location is `~/Library/Application Support/FluidAudio/Models/`
        // — hardcoded by the SDK and not configurable via API. Earlier
        // versions of this file polled `~/.cache/fluidaudio/Models/`
        // which never existed, so the progress percentage stayed at
        // nil indefinitely and the UI fell back to the indeterminate
        // spinner. Now centralized so any future SDK API change for
        // path overrides only needs to be applied in one place.
        let cacheDir = FluidAudioBackend.fluidAudioCacheDirectory()

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)  // 500 ms
            if Task.isCancelled { break }

            // Re-stat the cache dir size each tick. Don't cache results
            // — the file count and individual sizes change throughout
            // the download as CoreML bundles get compiled in place.
            let bytes = directorySize(at: cacheDir)
            if bytes <= 0 { continue }

            let fraction = Double(bytes) / Double(Self.fluidAudioExpectedTotalBytes)
            await MainActor.run {
                self.updateDownloadProgress(key, progress: fraction)
            }
        }
    }

    /// Recursively sum the file sizes under `directory`. Returns 0 if
    /// the directory doesn't exist or is empty. Used by the FluidAudio
    /// disk poller to compute download progress; could be reused for
    /// any other backend that manages its own downloads.
    ///
    /// Errors from individual file stats are swallowed — partial
    /// results are better than no results for a progress estimator.
    private func directorySize(at directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Shared scaffolding for the four `downloadXModel` methods. Sets status
    /// to `.downloading`, awaits the work, then transitions to `.ready` on
    /// success or `.error` on throw. Catches everything so a misbehaving
    /// backend can't bubble out into the sidebar's button-tap handler.
    ///
    /// Runs from a non-isolated context. Status writes hop to MainActor
    /// explicitly because the `markX` methods are `@MainActor`-isolated; the
    /// heavy `work()` closure stays off-main and its `await backend.prepare()`
    /// runs on the backend actor's executor.
    ///
    /// **Ticker.** Starts a side task that wakes up every second to nudge
    /// SwiftUI to re-render the elapsed-time label. Without it the label
    /// would only update on natural state changes — but our `.downloading`
    /// status doesn't change during the multi-minute download, so the
    /// "Downloading… 0:37" text would freeze. The ticker re-writes the
    /// same status to itself to force a publish.
    private func runDownload(key: ModelKey, work: @escaping () async throws -> Void) async {
        let current = await currentStatus(key)
        let alreadyInFlight: Bool
        switch current {
        case .downloading, .loading: alreadyInFlight = true
        default:                     alreadyInFlight = false
        }
        if alreadyInFlight {
            print("[ModelDownload] \(key.logTag): download already in flight, ignoring duplicate request")
            return
        }
        print("[ModelDownload] \(key.logTag): starting download / prepare…")
        await markDownloading(key)

        let startedAt = Date()
        let ticker = startElapsedTicker(key: key, startedAt: startedAt)
        defer { ticker.cancel() }

        // Debug-menu override: "Force R2 Mirror" forces every download
        // to skip HF entirely, useful for two things:
        //   - Testing the mirror flow without having to actually
        //     block HF at the network layer
        //   - Working around situations where HF responds normally
        //     to small requests but actual model file downloads
        //     still fail (some firewalls do deep packet inspection
        //     that distinguishes API endpoints from CDN downloads).
        // The flag is read from UserDefaults via the static accessor
        // so SwiftUI's @AppStorage in the Debug menu and our read
        // here stay in sync without needing observation plumbing.
        if Self.forceMirrorDownload {
            print("[ModelDownload] \(key.logTag): Force R2 Mirror enabled — bypassing HF entirely")
            await self.runMirrorOnlyFallback(key: key, work: work, startedAt: startedAt, ticker: ticker)
            return
        }

        // Default flow: R2 mirror FIRST, HuggingFace as fallback.
        //
        // **Why mirror-first and not HF-first.** HuggingFace can be
        // partially blocked on corporate/Netskope networks — the
        // hostname resolves and the root page returns 200, but actual
        // model file downloads stall indefinitely. An HF reachability
        // probe gives a false-positive in that case ("HF looks fine!")
        // and we waste minutes waiting on a doomed primary attempt
        // before falling back. The mirror, hosted on Cloudflare's
        // public R2 CDN, is much less likely to be selectively
        // blocked and gives a fast, reliable answer. So we try it
        // first and only reach for HF if the mirror itself fails
        // (R2 outage, missing object, network problem on our side).
        //
        // **What counts as "mirror failure".** Any throw from the
        // mirror pipeline — download failure, extraction failure, or
        // prepare() failure loading the just-extracted weights —
        // triggers the HF fallback. The HF library does its own file
        // validation and will re-download files that don't match
        // expected hashes, so partial state left by a mid-extraction
        // failure gets cleaned up automatically rather than producing
        // confusing errors.
        //
        // **What if no mirror is configured.** `mirror(for:)` returns
        // nil when `mirrorBaseURL` still contains the REPLACE-ME
        // placeholder. In that case we skip directly to HF — same
        // behavior as before the mirror was introduced.
        if let mirror = Self.mirror(for: key) {
            print("[ModelDownload] \(key.logTag): trying R2 mirror as primary download source: \(mirror.url.absoluteString)")
            do {
                try await self.downloadAndExtractMirror(key: key, mirror: mirror)
                // Bytes are now on disk. The next step — work() — is
                // the library's prepare() which loads weights into
                // memory. This phase takes 5-30s for medium Whisper
                // models on first load, longer for larger ones, and
                // during it the "Downloading…" label is misleading
                // (nothing is downloading). Switch to .loading so the
                // UI shows "Loading…" instead. The ticker keeps
                // running across this transition since it handles
                // both downloading and loading.
                await markLoading(key)
                print("[ModelDownload] \(key.logTag): mirror download succeeded, loading weights into memory…")
                // OFFLINE LOAD (2026-07-27): the bytes are already on
                // disk from the R2 tarball, but the backends' prepare()
                // (WhisperKit's model load, MLX's Parakeet loader) will
                // otherwise reach back to HuggingFace to re-validate
                // and fetch small sidecar files (e.g. weight.bin,
                // config hashes). On a machine that can reach HF that's
                // invisible; on a Netskope fleet machine those fetches
                // STALL, prepare() throws, and — the bug in gabrams's
                // 2026-07-27 log — the throw was caught as "R2 mirror
                // failed" and dragged the whole flow into a doomed HF
                // fallback, wasting ~5 min per model and ultimately
                // reporting "Model not found" for a model that was
                // fully downloaded and extracted. HF_HUB_OFFLINE forces
                // the loader to trust the extracted snapshot. Scoped:
                // set before prepare(), cleared after (success OR
                // throw), so the no-mirror HF path below still works.
                setenv("HF_HUB_OFFLINE", "1", 1)
                do {
                    try await work()
                    unsetenv("HF_HUB_OFFLINE")
                } catch {
                    unsetenv("HF_HUB_OFFLINE")
                    throw error
                }
                ticker.cancel()
                let total = Date().timeIntervalSince(startedAt)
                print(String(format: "[ModelDownload] %@: complete via R2 mirror in %.2fs", key.logTag, total))
                await markReady(key)
                await MainActor.run { self.refreshAllOnDiskStatuses() }
                return
            } catch let mirrorError {
                print("[ModelDownload] \(key.logTag): R2 mirror failed (\(mirrorError.localizedDescription)) — falling back to HuggingFace")
                // Reset status back to .downloading for the HF attempt —
                // we transitioned to .loading after the mirror download
                // succeeded, and if we got here via prepare() failure
                // the label would otherwise be stuck on "Loading…"
                // while HF re-downloads bytes over the network.
                await markDownloading(key)
                // Fall through to HF below.
            }
        } else {
            print("[ModelDownload] \(key.logTag): no R2 mirror configured for this model — using HuggingFace directly")
        }

        // HuggingFace fallback (or primary, if no mirror configured).
        //
        // Wrapped in a 5-minute hard timeout so a stalled HF download
        // doesn't hang indefinitely. 5 minutes is long enough for any
        // normal model download on any sane connection (largest
        // Whisper variant we ship is ~1.5GB; at 50 KB/s that's ~9
        // minutes — but if it's that slow, the user is going to have
        // a worse problem than this timeout). Typical 600MB model on
        // a 10 Mbps line: <2 minutes.
        print("[ModelDownload] \(key.logTag): attempting HuggingFace download (5-minute timeout)…")
        do {
            try await Self.withTimeout(seconds: 300, key: key, label: "HuggingFace download") {
                try await work()
            }
            ticker.cancel()
            let total = Date().timeIntervalSince(startedAt)
            print(String(format: "[ModelDownload] %@: complete via HuggingFace in %.2fs", key.logTag, total))
            await markReady(key)
            await MainActor.run { self.refreshAllOnDiskStatuses() }
        } catch {
            ticker.cancel()
            print("[ModelDownload] \(key.logTag): HuggingFace also failed — \(error.localizedDescription)")
            await markError(key, message: error.localizedDescription)
        }
    }

    /// Tick once per second to refresh the elapsed-time label. The
    /// `ModelStatus.downloading(startedAt:progress:)` payload doesn't change on
    /// its own, but SwiftUI only re-renders when `@Published` actually
    /// publishes. So we re-publish the same value once a second so the
    /// view recomputes `status.label` and the timer text advances.
    ///
    /// **Visibility note:** internal (not private) so
    /// `TranscriptionEngine.preparingWithStatusReport` can use the same
    /// ticker for the Start-button path. Both paths get identical
    /// elapsed-time updates.
    ///
    /// Also emits a 30s heartbeat log line so the in-app viewer (⌘L)
    /// has a record that the process is alive.
    func startElapsedTicker(key: ModelKey, startedAt: Date) -> Task<Void, Never> {
        return Task { [weak self] in
            var lastHeartbeatLog: Date = startedAt
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
                if Task.isCancelled { break }

                // Re-publish the same status to wake up SwiftUI. The
                // label is computed via `Date().timeIntervalSince(s)`
                // from inside a computed property, which SwiftUI
                // doesn't re-evaluate on a wall-clock timer — only
                // when the @Published value changes. So we trigger a
                // change by reassigning the same value once per
                // second.
                //
                // Earlier this function checked `s == startedAt` to
                // confirm "this is MY download, not someone else's
                // that came after". That check was buggy: the Date
                // stored in `statuses[key]` was created inside
                // markDownloading, while `startedAt` was created in
                // runDownload — those Dates differ by microseconds
                // and never compare equal, so the ticker bailed on
                // its first iteration and the label only updated on
                // window-focus changes (when SwiftUI re-evaluated
                // the view for other reasons).
                //
                // The check served no real purpose anyway: the
                // in-flight guard at the top of runDownload prevents
                // concurrent downloads of the same key, so there's
                // only ever one ticker per (key, run) tuple. We just
                // check that the status is still downloading or
                // loading; if it's moved to .ready / .cached /
                // .error / etc., the ticker exits naturally.
                let stillRunning: Bool = await MainActor.run { [weak self] in
                    guard let self else { return false }
                    switch self.statuses[key] {
                    case .downloading(let s, let p):
                        // Preserve the latest known progress when
                        // re-publishing. The progress value is updated
                        // independently from this ticker by the URL
                        // session delegate (R2 mirror path) or the
                        // FluidAudio disk poller; this ticker's only
                        // job is to wake SwiftUI so the elapsed-time
                        // portion of the label advances.
                        self.statuses[key] = .downloading(startedAt: s, progress: p)
                        return true
                    case .loading(let s):
                        self.statuses[key] = .loading(startedAt: s)
                        return true
                    default:
                        return false
                    }
                }
                if !stillRunning { break }

                // 30s heartbeat log so the viewer has timestamped
                // records of progress for diagnostic purposes.
                if Date().timeIntervalSince(lastHeartbeatLog) >= 30.0 {
                    let elapsed = Int(Date().timeIntervalSince(startedAt))
                    print("[ModelDownload] \(key.logTag): still working… elapsed \(elapsed)s")
                    lastHeartbeatLog = Date()
                }
            }
        }
    }

    // MARK: - R2 Mirror Fallback

    /// Base URL for the R2 mirror that hosts model archives as fallback
    /// when Hugging Face is unreachable (corporate firewalls, blocked
    /// regions, HF outages, etc.).
    ///
    /// **Update this when your bucket URL changes** — e.g., if you
    /// switch from the default `pub-<id>.r2.dev` URL to a custom domain
    /// like `models.streamscribe.app`, this is the only line to change.
    /// Trailing slash is required; archive filenames are appended to it
    /// to form the full URL.
    ///
    /// The archive filenames follow the convention from
    /// `mirror-hf-models.sh`: each model's archive is named after its
    /// HF identifier with a `.tar.gz` suffix (e.g.
    /// `openai_whisper-small.en.tar.gz`,
    /// `diar_streaming_sortformer_4spk-v2.1-fp16.tar.gz`).
    /// Canonical R2 mirror base. Internal (not private): the
    /// FluidAudio-family backends default ModelRegistry.baseURL to
    /// this, so ALL model downloads route to R2 unless a custom
    /// mirror is set — fleet machines have no HuggingFace access,
    /// so HF-as-default was a latent failure.
    static let mirrorBaseURL = "https://pub-201cda1156ec4d469157edb7a3ec216d.r2.dev/"

    /// Debug-menu override: when true, every model download skips the
    /// HuggingFace primary path and goes straight to the R2 mirror.
    /// Persisted via UserDefaults so the setting survives app
    /// relaunches; the matching `@AppStorage` in the Debug menu
    /// reads/writes the same key. Default is false (normal HF-first
    /// behavior).
    ///
    /// Useful when:
    /// - Testing the mirror flow without having to block HF at the
    ///   network layer.
    /// - The HF probe succeeds (the root page is reachable) but
    ///   actual model file downloads still fail — some firewalls
    ///   distinguish API endpoints from CDN file downloads.
    /// - Force-refreshing a model from the mirror without first
    ///   waiting for the HF attempt to time out.
    static var forceMirrorDownload: Bool {
        get { UserDefaults.standard.bool(forKey: "ModelDownload.forceMirror") }
        set { UserDefaults.standard.set(newValue, forKey: "ModelDownload.forceMirror") }
    }

    /// Describes a single mirror entry: where to download from, where
    /// to extract to. We don't include a checksum here intentionally —
    /// downloads are over HTTPS so the integrity is already protected
    /// by TLS, and avoiding a per-model SHA constant keeps the user's
    /// re-mirror workflow simple (re-upload archives, no code edits
    /// needed). If you want defense-in-depth checksum verification,
    /// it'd slot in as an optional `sha256: String?` field on this
    /// struct plus a comparison after download.
    private struct ModelMirror {
        let url: URL
        let extractTo: URL
    }

    /// Look up the R2 mirror for a given model key, or nil if no mirror
    /// is configured for it. The extract-to paths match where each
    /// backend looks for its local cache, all rooted under the
    /// unified models root (`~/Library/Application Support/StreamScribe/Models/`):
    ///
    /// - WhisperKit: `<root>/huggingface/models/argmaxinc/whisperkit-coreml/<modelName>/`
    /// - SpeakerKit: `<root>/huggingface/models/argmaxinc/speakerkit-coreml/`
    /// - Parakeet / Sortformer: `<root>/huggingface/hub/mlx-audio/<org>_<name>/`
    ///   (mlx-audio-swift's empirically-observed cache convention — note
    ///   the underscore separator between org and name, not HF Hub's
    ///   `--` separator. See `ParakeetBackend.cacheCandidatePaths` for
    ///   the full provenance.)
    /// - FluidAudio: `<root>/fluidaudio/` (with a symlink from
    ///   `~/Library/Application Support/FluidAudio/Models/` pointing
    ///   here, set up at app launch by
    ///   `StreamScribeApp.setupFluidAudioSymlink()`)
    ///
    /// Returns nil if `mirrorBaseURL` is left at the placeholder, which
    /// effectively disables the fallback. To enable mirrors, replace
    /// the placeholder with your actual bucket URL.
    /// Compute the StreamScribe models root: `~/Library/Application
    /// Support/StreamScribe/Models/`. Matches the path set up by
    /// `StreamScribeApp.setupUnifiedModelsRoot()` — both functions
    /// MUST stay in sync (any future change should be made in both
    /// places, or refactored into a shared utility).
    ///
    /// Returns nil if Application Support isn't reachable, which
    /// shouldn't happen in practice on a normally-functioning macOS
    /// install. Mirror lookup falls back to nil in that case, which
    /// disables R2 mirrors for the session — HF fallback still works.
    private static func streamScribeModelsRoot() -> URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("StreamScribe")
            .appendingPathComponent("Models")
    }

    private static func mirror(for key: ModelKey) -> ModelMirror? {
        guard !mirrorBaseURL.contains("REPLACE-ME") else { return nil }
        guard let base = URL(string: mirrorBaseURL) else { return nil }
        guard let modelsRoot = streamScribeModelsRoot() else { return nil }
        let hfRoot = modelsRoot.appendingPathComponent("huggingface")

        switch key {
        case .canary:
            // Canary's tarball download lives in CanaryBackend
            // (ensureModelBundle) — the generic mirror extractor
            // isn't used, so no mirror entry here.
            return nil
        case .whisper(let modelName):
            return ModelMirror(
                url: base.appendingPathComponent("\(modelName).tar.gz"),
                extractTo: hfRoot
                    .appendingPathComponent("models")
                    .appendingPathComponent("argmaxinc")
                    .appendingPathComponent("whisperkit-coreml")
                    .appendingPathComponent(modelName)
            )

        case .speakerKit:
            return ModelMirror(
                url: base.appendingPathComponent("speakerkit-coreml.tar.gz"),
                extractTo: hfRoot
                    .appendingPathComponent("models")
                    .appendingPathComponent("argmaxinc")
                    .appendingPathComponent("speakerkit-coreml")
            )

        case .parakeet(let modelRepo):
            // Split "mlx-community/parakeet-tdt-0.6b-v3" into org + name.
            // The archive filename uses just the name (per the mirror
            // script's convention); the destination uses the
            // org_name form mlx-audio expects.
            let parts = modelRepo.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let org = String(parts[0])
            let name = String(parts[1])
            return ModelMirror(
                url: base.appendingPathComponent("\(name).tar.gz"),
                extractTo: hfRoot
                    .appendingPathComponent("hub")
                    .appendingPathComponent("mlx-audio")
                    .appendingPathComponent("\(org)_\(name)")
            )

        case .sortformer:
            // Sortformer is single-canonical (no user-pickable variant),
            // so we hardcode its repo identifier here. Must match
            // `SortformerBackend.defaultModelRepo`.
            let org = "mlx-community"
            let name = "diar_streaming_sortformer_4spk-v2.1-fp16"
            return ModelMirror(
                url: base.appendingPathComponent("\(name).tar.gz"),
                extractTo: hfRoot
                    .appendingPathComponent("hub")
                    .appendingPathComponent("mlx-audio")
                    .appendingPathComponent("\(org)_\(name)")
            )

        case .fluidAudio:
            // FluidAudio's CoreML bundles are R2-mirrored as a single
            // tarball (`fluidaudio.tar.gz`) containing the SDK's
            // expected `Models/` layout — pyannote segmentation +
            // embedding bundles under `speaker-diarization-coreml/`,
            // the LS-EEND bundle under `ls-eend-coreml/`, etc.
            //
            // **Extract destination.** `<root>/fluidaudio/`, which is
            // also the symlink target set up by
            // `StreamScribeApp.setupFluidAudioSymlink()`. The
            // hardcoded SDK path
            // `~/Library/Application Support/FluidAudio/Models/` is a
            // symlink to here, so files written via this mirror are
            // automatically findable by the SDK without any
            // additional configuration on its side.
            //
            // **Tarball production.** One-time user setup: run the
            // app once with default HF download to populate
            // FluidAudio's models, then `tar -czf fluidaudio.tar.gz
            // *` from inside the populated Models directory and
            // upload to R2. The archive's relative paths should
            // place entries at `speaker-diarization-coreml/...` and
            // `ls-eend-coreml/...` at the archive root so extraction
            // lands them correctly under `<root>/fluidaudio/`.
            //
            // **Fallback to HF.** If this R2 mirror fails (tarball
            // missing, network error, decode failure), `runDownload`
            // catches the error and falls through to the closure
            // that calls `FluidAudioBackend.prepare()` — which uses
            // FluidAudio's own HF-based download. The disk-poll
            // progress task started in `downloadFluidAudioModel`
            // covers that fallback path with approximate progress.
            return ModelMirror(
                url: base.appendingPathComponent("fluidaudio.tar.gz"),
                extractTo: modelsRoot.appendingPathComponent("fluidaudio")
            )
        }
    }

    /// Download the mirror archive to a temp file, extract it into the
    /// backend's cache location, and delete the temp file. Errors
    /// from any step throw; the caller in `runDownload` catches and
    /// falls through to the error path.
    ///
    /// **Streaming download.** Uses `URLSession.download(from:)` which
    /// writes directly to a temp file on disk rather than buffering
    /// the full response in memory. Important for the larger archives
    /// (Whisper medium is ~1.5GB, Parakeet variants similar) — we
    /// don't want to allocate gigabytes of `Data` just to write them
    /// to disk a moment later.
    ///
    /// **Extraction via `/usr/bin/tar`.** Foundation doesn't have a
    /// tar.gz extractor (only `FileManager.unzipItem` for .zip), so we
    /// shell out to the system tar. It's been on every macOS since
    /// forever, handles .tar.gz natively with `-xzf`, and is already
    /// in the trust boundary of the app.
    ///
    /// The destination directory is created if it doesn't exist. Any
    /// existing files in the destination are left alone — `tar -x`
    /// overwrites individual files but doesn't clear the dir first.
    /// If you ever need a clean install, delete the destination dir
    /// before calling this.
    private func downloadAndExtractMirror(key: ModelKey, mirror: ModelMirror) async throws {
        print("[ModelDownload] \(key.logTag): downloading mirror archive from \(mirror.url.absoluteString)")

        // Step 1: download to a temp file with per-byte progress.
        //
        // Uses `MirrorDownloader` (a `URLSessionDownloadDelegate` wrapper)
        // instead of `URLSession.shared.download(from:)` so we get
        // `didWriteData(totalBytesWritten:totalBytesExpectedToWrite:)`
        // callbacks during the transfer. R2 always sends `Content-Length`
        // for static objects, so `totalBytesExpectedToWrite` is the real
        // archive size — no separate HEAD request needed.
        //
        // The progress callback updates `statuses[key]` on MainActor
        // (hop inside the closure) so SwiftUI sees the fraction tick
        // up in real time, and the "Downloading… 0:37 (42%)" label
        // takes shape within a few hundred ms of the first chunk
        // arriving.
        let downloadedURL = try await MirrorDownloader.download(
            from: mirror.url,
            onProgress: { [weak self] fraction in
                guard let self else { return }
                Task { @MainActor in
                    self.updateDownloadProgress(key, progress: fraction)
                }
            }
        )

        // Move the temp file to a stable temp path before the cleanup
        // hook fires. Pure paranoia — the file URL we got back from
        // URLSession.download is documented to be valid for the
        // duration of the delegate callback, and we're past that, but
        // the move is cheap and removes any ambiguity.
        let tmpDir = FileManager.default.temporaryDirectory
        let stableArchive = tmpDir.appendingPathComponent("streamscribe-mirror-\(UUID().uuidString).tar.gz")
        try FileManager.default.moveItem(at: downloadedURL, to: stableArchive)
        defer { try? FileManager.default.removeItem(at: stableArchive) }

        let size = (try? FileManager.default.attributesOfItem(atPath: stableArchive.path)[.size] as? Int) ?? -1
        print("[ModelDownload] \(key.logTag): mirror archive downloaded (\(size) bytes)")

        // Step 2: create destination, extract.
        try FileManager.default.createDirectory(
            at: mirror.extractTo,
            withIntermediateDirectories: true
        )
        print("[ModelDownload] \(key.logTag): extracting to \(mirror.extractTo.path)")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = [
            "-xzf", stableArchive.path,
            "-C", mirror.extractTo.path
        ]
        // Capture stderr so an extraction failure has a useful message.
        let errPipe = Pipe()
        task.standardError = errPipe
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "(no error output)"
            throw NSError(
                domain: "ModelDownloadManager",
                code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "tar -xzf failed (status \(task.terminationStatus)): \(errMsg)"]
            )
        }

        print("[ModelDownload] \(key.logTag): mirror extraction complete")
    }

    /// Probe whether `huggingface.co` is reachable from this network.
    /// Used to detect blocked-HF scenarios early so we can skip the
    /// primary download (which would otherwise hang indefinitely on
    /// some firewalled networks instead of failing cleanly).
    ///
    /// Implementation: a HEAD request to the HF root with a short
    /// timeout (10s). We don't care about the response body or even
    /// the status code — any HTTP response means the connection was
    /// established and HF is reachable at the network layer. Only
    /// total connection failures or timeouts count as "unreachable".
    private func probeHFReachable() async -> Bool {
        guard let url = URL(string: "https://huggingface.co/") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10.0
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                // Any HTTP response (even 4xx/5xx) means the connection
                // worked. Status code itself doesn't matter — HF's root
                // is a real page, but we'd accept anything that came
                // back through the pipe.
                let ok = http.statusCode > 0
                print("[ModelDownload] HF probe got HTTP \(http.statusCode) — \(ok ? "reachable" : "unreachable")")
                return ok
            }
            return false
        } catch {
            print("[ModelDownload] HF probe failed — \(error.localizedDescription)")
            return false
        }
    }

    /// Race the given async body against a timeout. If the body
    /// completes first, return its result; if the timeout fires
    /// first, cancel the body and throw a TimeoutError.
    ///
    /// **Why this exists.** Library calls into WhisperKit /
    /// SpeakerKitDiarizer / mlx-audio-swift use URLSession with the
    /// default 7-day resource timeout. On networks that silently
    /// sinkhole HF connections (Netskope and friends), these calls
    /// can hang for hours without ever throwing. Wrapping the
    /// library call in `withTimeout` gives us an upper bound on how
    /// long we wait before falling back to the mirror.
    ///
    /// **Implementation note.** Uses `Task.init` + a separate watcher
    /// task rather than `withThrowingTaskGroup`. TaskGroup requires
    /// `@Sendable` closures, and our `work` parameter (from
    /// `runDownload`) isn't marked `@Sendable` — propagating that
    /// annotation through all the `downloadXxxModel` call sites
    /// would be a much larger change. The Task-based approach is
    /// functionally equivalent for our purposes: a timed race
    /// between two operations with explicit cancellation.
    ///
    /// **Cancellation behavior.** When the timeout fires, we call
    /// `work.cancel()` on the body task. URLSession integrates with
    /// Swift's structured concurrency cancellation, so any pending
    /// network requests inside the library call WILL be cancelled.
    /// If the library has gotten past the network step into local
    /// processing, that processing may continue briefly until it
    /// next checks for cancellation — but the await on `work.value`
    /// throws `CancellationError` immediately, and we surface that
    /// as our timeout error.
    private static func withTimeout<T>(
        seconds: TimeInterval,
        key: ModelKey,
        label: String,
        body: @escaping () async throws -> T
    ) async throws -> T {
        let work = Task {
            try await body()
        }
        let watcher = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !work.isCancelled {
                print("[ModelDownload] \(key.logTag): \(label) hit \(Int(seconds))s timeout — cancelling and falling back")
                work.cancel()
            }
        }
        defer { watcher.cancel() }
        do {
            return try await work.value
        } catch is CancellationError {
            throw NSError(
                domain: "ModelDownloadManager.Timeout",
                code: -1001,
                userInfo: [NSLocalizedDescriptionKey: "\(label) timed out after \(Int(seconds))s"]
            )
        }
    }

    /// Mirror-only download path. Used when the HF probe fails and we
    /// skip the primary attempt entirely.
    ///
    /// This is structurally similar to the mirror branch in
    /// `runDownload`'s catch block, but inlined into its own helper
    /// so the no-probe path and the on-failure path read cleanly. The
    /// flow is the same: download the .tar.gz, extract it, then call
    /// the backend's prepare() to load weights from the now-local
    /// cache.
    private func runMirrorOnlyFallback(
        key: ModelKey,
        work: @escaping () async throws -> Void,
        startedAt: Date,
        ticker: Task<Void, Never>
    ) async {
        guard let mirror = Self.mirror(for: key) else {
            ticker.cancel()
            let msg = "HuggingFace unreachable and no R2 mirror configured for this model. Check Settings → … or update mirrorBaseURL in ModelDownloadManager.swift."
            print("[ModelDownload] \(key.logTag): \(msg)")
            await markError(key, message: msg)
            return
        }
        do {
            try await self.downloadAndExtractMirror(key: key, mirror: mirror)
            // Bytes on disk; next phase is weight-load into memory.
            // Same rationale as the catch-block path — show "Loading…"
            // not "Downloading…" while the library's prepare() runs.
            await markLoading(key)
            print("[ModelDownload] \(key.logTag): mirror download succeeded (HF skipped due to probe failure), loading weights into memory…")
            try await work()
            ticker.cancel()
            let total = Date().timeIntervalSince(startedAt)
            print(String(format: "[ModelDownload] %@: complete via mirror (HF unreachable) in %.2fs", key.logTag, total))
            await markReady(key)
            await MainActor.run { self.refreshAllOnDiskStatuses() }
        } catch let mirrorError {
            ticker.cancel()
            let msg = "HuggingFace unreachable; R2 mirror also failed: \(mirrorError.localizedDescription)"
            print("[ModelDownload] \(key.logTag): \(msg)")
            await markError(key, message: msg)
        }
    }
}

// MARK: - MirrorDownloader

/// `URLSessionDownloadDelegate`-based downloader with per-byte progress
/// reporting. Drop-in replacement for `URLSession.shared.download(from:)`
/// — same shape (URL in, file URL out, throws on failure), but with a
/// progress callback that fires whenever URLSession delivers a chunk.
///
/// **Why a one-shot delegate instance per download.** Each download
/// gets its own `URLSession` configured with this delegate as its
/// delegate. The session is invalidated in `urlSession(_:didBecomeInvalidWithError:)`
/// or in `finish(...)`, breaking the retain cycle that would otherwise
/// leak the session, delegate, continuation, and any captured callback
/// state. This is the recommended Apple pattern — `URLSession`'s
/// delegate-based init was designed for short-lived sessions.
///
/// **Continuation semantics.** Resumed exactly once: either from
/// `didFinishDownloadingTo` (success) or `didCompleteWithError`
/// (failure). The `finished` flag guards against the rare case
/// where both fire (e.g. cancellation racing with completion).
///
/// **File lifetime.** The temp file URL we get from
/// `didFinishDownloadingTo` is only valid until that delegate method
/// returns. We move it to a stable location inline, then resume the
/// continuation with the new URL. The caller is responsible for
/// deleting the moved file.
private final class MirrorDownloader: NSObject, URLSessionDownloadDelegate {

    /// Download a file from `url`, reporting progress via `onProgress`
    /// (called on URLSession's background queue, not necessarily main).
    /// Returns the URL of a temp file containing the downloaded bytes;
    /// the caller is responsible for moving/deleting it.
    ///
    /// Throws on non-2xx HTTP status, transport errors, or cancellation.
    static func download(
        from url: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let downloader = MirrorDownloader(onProgress: onProgress, continuation: continuation)
            // Default config (no caching, no cookie store needed) is
            // fine for one-shot large-file downloads from a public CDN.
            let session = URLSession(
                configuration: .default,
                delegate: downloader,
                delegateQueue: nil
            )
            downloader.session = session
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    /// Captured so we can invalidate the session in `finish` — breaking
    /// the URLSession → delegate retain cycle that would otherwise keep
    /// this instance alive forever.
    fileprivate var session: URLSession?
    /// Guard against double-resume on the continuation. URLSession
    /// occasionally fires both `didFinishDownloadingTo` and
    /// `didCompleteWithError(nil)` for the same task; without this
    /// guard, the second call would crash with a "continuation
    /// resumed twice" trap.
    private var finished = false

    private init(
        onProgress: @escaping (Double) -> Void,
        continuation: CheckedContinuation<URL, Error>
    ) {
        self.onProgress = onProgress
        self.continuation = continuation
        super.init()
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // `totalBytesExpectedToWrite` is `-1` (NSURLSessionTransferSizeUnknown)
        // when the server doesn't send Content-Length. R2 always sends
        // it, but we guard anyway — if we ever point this at a server
        // that doesn't, we silently skip the progress update for that
        // chunk rather than reporting a bogus fraction.
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(fraction)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temp file at `location` is only valid until this delegate
        // method returns. Move it to a stable temp path inline before
        // resuming the continuation so the caller has time to do
        // whatever (move it again, extract it, etc.).
        //
        // We use a UUID-named file rather than letting URLSession's
        // own temp name leak — the URLSession path is opaque and the
        // caller may want a friendlier name for logging.
        let stable = FileManager.default.temporaryDirectory
            .appendingPathComponent("streamscribe-download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: stable)

            // Validate HTTP status before declaring success. A 4xx or
            // 5xx body could have been written to disk as a "downloaded
            // file" containing an error page — we don't want the caller
            // to try to extract that as if it were a tarball.
            if let http = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: stable)
                finish(throwing: NSError(
                    domain: "MirrorDownloader",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) from mirror"]
                ))
                return
            }

            finish(returning: stable)
        } catch {
            finish(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // Only fire the error path here; success path was already
        // handled in `didFinishDownloadingTo`. If `error == nil` and
        // we haven't finished yet, it means the task completed
        // without a finished-download callback (e.g. cancellation
        // before any data arrived) — treat as a generic failure.
        if let error {
            finish(throwing: error)
        } else if !finished {
            finish(throwing: NSError(
                domain: "MirrorDownloader",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "download completed without producing a file"]
            ))
        }
    }

    // MARK: Continuation plumbing

    private func finish(returning url: URL) {
        guard !finished else { return }
        finished = true
        continuation?.resume(returning: url)
        continuation = nil
        session?.finishTasksAndInvalidate()
    }

    private func finish(throwing error: Error) {
        guard !finished else { return }
        finished = true
        continuation?.resume(throwing: error)
        continuation = nil
        session?.finishTasksAndInvalidate()
    }
}
