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

        /// Short identifier for log lines. Avoids dumping a full repo path
        /// into every status print.
        var logTag: String {
            switch self {
            case .whisper(let n):  return "whisper:\(n)"
            case .parakeet(let r): return "parakeet:\(r)"
            case .sortformer:      return "sortformer"
            case .speakerKit:      return "speakerKit"
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
        /// we're actually downloading bytes over the network. Carries
        /// the start timestamp so the UI can show elapsed time
        /// ("Downloading… 0:37"). No progress fraction — see enum doc
        /// for why.
        case downloading(startedAt: Date)
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
            case .downloading(let start):
                let elapsed = Int(Date().timeIntervalSince(start))
                let mins = elapsed / 60
                let secs = elapsed % 60
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
        }
        print("[ModelDownload] Probe \(key.logTag): \(cached ? "cached" : "not on disk")")
        return cached
    }

    // MARK: - Status updates

    @MainActor
    func markDownloading(_ key: ModelKey) {
        let prev = statuses[key] ?? .unknown
        statuses[key] = .downloading(startedAt: Date())
        print("[ModelDownload] \(key.logTag): \(stateName(prev)) → downloading")
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
                try await work()
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
    /// `ModelStatus.downloading(startedAt:)` payload doesn't change on
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
                    case .downloading(let s):
                        self.statuses[key] = .downloading(startedAt: s)
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
    private static let mirrorBaseURL = "https://pub-201cda1156ec4d469157edb7a3ec216d.r2.dev/"

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
    /// backend looks for its local cache:
    ///
    /// - WhisperKit: `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<modelName>/`
    /// - SpeakerKit: `~/Documents/huggingface/models/argmaxinc/speakerkit-coreml/`
    /// - Parakeet / Sortformer: `~/Documents/huggingface/hub/mlx-audio/<org>_<name>/`
    ///   (mlx-audio-swift's empirically-observed cache convention — note
    ///   the underscore separator between org and name, not HF Hub's
    ///   `--` separator. See `ParakeetBackend.cacheCandidatePaths` for
    ///   the full provenance.)
    ///
    /// Returns nil if `mirrorBaseURL` is left at the placeholder, which
    /// effectively disables the fallback. To enable mirrors, replace
    /// the placeholder with your actual bucket URL.
    private static func mirror(for key: ModelKey) -> ModelMirror? {
        guard !mirrorBaseURL.contains("REPLACE-ME") else { return nil }
        guard let base = URL(string: mirrorBaseURL) else { return nil }
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let hfRoot = docs.appendingPathComponent("huggingface")

        switch key {
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

        // Step 1: download to a temp file. URLSession.download writes
        // directly to disk; we move the temp file aside immediately so
        // it doesn't get swept by the URL loading system's cleanup.
        let (downloadedURL, response) = try await URLSession.shared.download(from: mirror.url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(
                domain: "ModelDownloadManager",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "mirror returned HTTP \(code)"]
            )
        }

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
