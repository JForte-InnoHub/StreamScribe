import SwiftUI
import AppKit

@main
struct StreamScribeApp: App {
    @StateObject private var transcriptionEngine = TranscriptionEngine()
    @StateObject private var toolManager = ToolManager.shared
    /// Per-model download/cache status. Mirrors `ToolManager`'s shape and is
    /// surfaced in the sidebar's model pickers (Download buttons + progress
    /// bars). Held as `@StateObject` so the singleton stays alive for the
    /// app's lifetime and its `@Published statuses` dictionary drives
    /// SwiftUI updates in the model rows. See `ModelDownloadManager` for the
    /// rationale on tracking model presence separately from `ToolManager`.
    @StateObject private var modelDownloadManager = ModelDownloadManager.shared
    /// Held as @StateObject so the singleton stays alive for the app's lifetime and
    /// its @Published authorizationStatus drives SwiftUI updates in the sidebar.
    /// The init() of NotificationService kicks off the initial status refresh, so by
    /// the time the user sees the sidebar we'll know whether notifications are
    /// allowed/denied/notDetermined.
    @StateObject private var notificationService = NotificationService.shared
    /// Logger held at app scope so its capture lifetime spans the entire run.
    /// startCapture() runs from init() below — it must fire before anything else
    /// prints, otherwise early prints are lost. The @StateObject also gives the
    /// log viewer a stable observation target.
    @StateObject private var logger = StreamScribeLogger.shared
    /// Update checker held at app scope so its @Published `updateAvailable`
    /// can drive the WindowGroup's update alert and Settings UI. The
    /// init() is private; we get the singleton instance here and let
    /// the @StateObject wrapper hold it for the app's lifetime. The
    /// actual launch-time check fires from a `.task` on ContentView below
    /// — not from this declaration, since @StateObject's initializer runs
    /// during view construction and we don't want to block startup on a
    /// GitHub round-trip.
    @StateObject private var updateChecker = UpdateChecker.shared

    /// Debug toggle: force every model download to skip HuggingFace and
    /// go straight to the R2 mirror. Bound to the Debug menu's "Force
    /// R2 Mirror" item and to `ModelDownloadManager.forceMirrorDownload`
    /// via the same UserDefaults key — @AppStorage participates in
    /// SwiftUI view updates so the menu label flips between
    /// "Disable…" / "Force…" reactively when toggled.
    @AppStorage("ModelDownload.forceMirror") private var forceMirrorDownload: Bool = false

    /// Debug toggle: force the Retry probe button to render even
    /// when the probe didn't actually fail. Same UserDefaults key as
    /// the corresponding @AppStorage in SidebarView — the menu item
    /// here writes it, the sidebar reads it, both update when it
    /// changes. Used for visual / interaction testing of the button
    /// without having to break the probe.
    @AppStorage("debug.forceShowRetryProbeButton") private var debugForceShowRetryProbeButton: Bool = false

    /// Whether the Debug menu is shown to the user. In DEBUG builds
    /// the menu is always present (computed below). In RELEASE
    /// builds it's gated on this flag, which the user can flip via
    /// the Settings sheet → Advanced → "Show Debug menu" checkbox.
    /// Default off in release so the average user never sees the
    /// menu unless they explicitly enable it. Useful for shipping
    /// diagnostic tools (Force R2 Mirror, Force Retry Probe Button,
    /// Show Refinement Stats) to advanced users without cluttering
    /// the menu bar for everyone.
    @AppStorage("debug.menuEnabled") private var debugMenuEnabledByUser: Bool = false

    /// First-time-setup completion flag. False on a fresh install (key
    /// has never been touched), flipped to true when the user dismisses
    /// the WelcomeView (either via Continue or Skip), and backfilled to
    /// true for existing users whose cookieBrowser is already configured
    /// (see the .task on ContentView below — they'd otherwise see a
    /// "welcome" sheet they don't need).
    @AppStorage("hasCompletedFirstTimeSetup") private var hasCompletedFirstTimeSetup: Bool = false

    /// Triggers the confirmation alert for the Debug menu's "Clear Model
    /// Cache" item. The action is destructive (deletes downloaded
    /// model files; user has to re-download to use them next session),
    /// so we route through a confirmation dialog instead of firing
    /// directly on menu click — preventing the easy misfire of
    /// reaching for one debug menu item and hitting an adjacent one.
    @State private var showClearCacheConfirmation: Bool = false

    /// Set after a cache wipe completes; drives a brief success alert
    /// so the user gets feedback that the wipe ran (otherwise the menu
    /// just closes silently and they wonder if it worked).
    @State private var clearCacheCompletionMessage: String? = nil

    /// Resolved debug-menu visibility, combining build-config and
    /// user preference. Encapsulated as a computed property so the
    /// menu definition stays readable and the policy is in one place.
    private var showDebugMenu: Bool {
        #if DEBUG
        return true
        #else
        return debugMenuEnabledByUser
        #endif
    }

    /// Lets us open the log viewer from menu commands.
    @Environment(\.openWindow) private var openWindow

    /// Compute the canonical StreamScribe models root and ensure both
    /// it and its expected subdirectories exist. Sets `HF_HOME` to the
    /// huggingface subdirectory so swift-transformers and mlx-audio
    /// route their caches there, and sets up the FluidAudio symlink
    /// so the SDK's hardcoded cache path lands inside the unified
    /// root.
    ///
    /// Idempotent: safe to call multiple times. All `try?` so partial
    /// failures (e.g. parent dir already exists, symlink already
    /// correct) silently no-op rather than throwing.
    private static func setupUnifiedModelsRoot() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            print("[StreamScribe] No Application Support directory available — skipping unified models setup")
            return
        }

        let modelsRoot = appSupport
            .appendingPathComponent("StreamScribe")
            .appendingPathComponent("Models")
        try? fm.createDirectory(at: modelsRoot, withIntermediateDirectories: true)

        // HF_HOME → <root>/huggingface
        let hfHome = modelsRoot.appendingPathComponent("huggingface")
        try? fm.createDirectory(at: hfHome, withIntermediateDirectories: true)
        setenv("HF_HOME", hfHome.path, 0)

        // FluidAudio target dir + symlink. See the helper for the
        // full set of cases it handles (fresh install, existing
        // symlink, existing real directory with files needing
        // migration, etc.).
        let fluidAudioTarget = modelsRoot.appendingPathComponent("fluidaudio")
        try? fm.createDirectory(at: fluidAudioTarget, withIntermediateDirectories: true)
        setupFluidAudioSymlink(target: fluidAudioTarget, appSupport: appSupport)
    }

    /// Make `~/Library/Application Support/FluidAudio/Models/` resolve
    /// (via symlink) to `<unified models root>/fluidaudio/`. Handles
    /// every state the SDK path could be in:
    ///
    ///   1. Doesn't exist → just create the symlink
    ///   2. Already a correct symlink → no-op
    ///   3. A symlink pointing elsewhere → replace
    ///   4. A real directory with files → migrate files to target,
    ///      then replace with symlink (preserves models from existing
    ///      installs that ran FluidAudio's auto-download before we
    ///      had this consolidation)
    ///   5. A real directory but empty → delete + replace with symlink
    ///   6. Something else (regular file?) → leave alone, log warning
    ///
    /// All file operations use `try?` and log on failure. The worst
    /// case if anything fails: FluidAudio's SDK keeps using its
    /// hardcoded cache path independently of our unified root,
    /// losing the consolidation but not breaking anything else.
    private static func setupFluidAudioSymlink(target: URL, appSupport: URL) {
        let fm = FileManager.default
        let sdkPath = appSupport
            .appendingPathComponent("FluidAudio")
            .appendingPathComponent("Models")

        // Ensure the parent dir (~/Library/Application Support/FluidAudio/)
        // exists. Without it, createSymbolicLink fails with EEXIST/ENOENT
        // depending on the macOS version.
        try? fm.createDirectory(
            at: sdkPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Determine what's at the SDK path.
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: sdkPath.path, isDirectory: &isDir)
        let attrs = try? fm.attributesOfItem(atPath: sdkPath.path)
        let typeIsSymlink = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink

        if !exists {
            // Case 1: fresh install. Create the symlink and we're done.
            do {
                try fm.createSymbolicLink(at: sdkPath, withDestinationURL: target)
                print("[StreamScribe] FluidAudio symlink created: \(sdkPath.path) → \(target.path)")
            } catch {
                print("[StreamScribe] FluidAudio symlink creation failed: \(error.localizedDescription)")
            }
            return
        }

        if typeIsSymlink {
            // Case 2/3: existing symlink. Verify the destination; replace
            // if wrong.
            if let dest = try? fm.destinationOfSymbolicLink(atPath: sdkPath.path),
               dest == target.path {
                return
            }
            try? fm.removeItem(at: sdkPath)
            try? fm.createSymbolicLink(at: sdkPath, withDestinationURL: target)
            print("[StreamScribe] FluidAudio symlink replaced (was pointing elsewhere)")
            return
        }

        if isDir.boolValue {
            // Case 4 or 5: real directory at the SDK path. Migrate any
            // contents into the target, then replace with a symlink.
            // Use moveItem rather than copy to preserve disk space —
            // these CoreML bundles are ~250 MB and copying then
            // deleting wastes time on slow disks.
            if let contents = try? fm.contentsOfDirectory(atPath: sdkPath.path),
               !contents.isEmpty {
                print("[StreamScribe] Migrating \(contents.count) item(s) from \(sdkPath.path) to \(target.path)")
                for item in contents {
                    let from = sdkPath.appendingPathComponent(item)
                    let to = target.appendingPathComponent(item)
                    if fm.fileExists(atPath: to.path) {
                        // Already at target — skip (don't clobber). The
                        // user may have manually copied or the migration
                        // is running a second time after a partial
                        // success.
                        print("[StreamScribe]   - \(item): already at target, skipping")
                        continue
                    }
                    do {
                        try fm.moveItem(at: from, to: to)
                        print("[StreamScribe]   - \(item): moved")
                    } catch {
                        print("[StreamScribe]   - \(item): move failed: \(error.localizedDescription)")
                    }
                }
            }
            do {
                try fm.removeItem(at: sdkPath)
                try fm.createSymbolicLink(at: sdkPath, withDestinationURL: target)
                print("[StreamScribe] FluidAudio cache dir replaced with symlink")
            } catch {
                print("[StreamScribe] FluidAudio symlink replace failed: \(error.localizedDescription) — files now at \(target.path); SDK will use the old path until manually fixed")
            }
            return
        }

        // Case 6: a regular file at the SDK path? Doesn't make sense
        // but possible. Don't touch it.
        print("[StreamScribe] Unexpected item at FluidAudio SDK path: \(sdkPath.path) — leaving as-is")
    }

    init() {
        // Set up the unified StreamScribe models directory and route
        // all model storage through it. Layout:
        //
        //   ~/Library/Application Support/StreamScribe/Models/
        //   ├── huggingface/         (HF_HOME — Whisper, Parakeet,
        //   │                         Sortformer, SpeakerKit, anything
        //   │                         else routed through HuggingFace
        //   │                         Hub or its mirror)
        //   └── fluidaudio/          (FluidAudio CoreML bundles,
        //                             reached via a symlink from
        //                             FluidAudio's hardcoded path)
        //
        // **Why Application Support over Documents.** Originally we
        // used `~/Documents/huggingface/` for visibility, but that was
        // motivated by users sideloading models on locked-down
        // networks. With R2 mirrors in place, that workflow is no
        // longer needed — model fetches happen automatically and
        // reliably. Application Support is the macOS-standard
        // location for app-managed data the user doesn't directly
        // edit. It's still visible in Finder via Cmd+Shift+G, just
        // not part of the default sidebar.
        //
        // **Why FluidAudio gets a symlink.** FluidAudio's SDK
        // hardcodes its cache path inside
        // `OfflineDiarizerModels.defaultModelsDirectory()` —
        // `~/Library/Application Support/FluidAudio/Models/`. There's
        // no public API to redirect it. We solve this by making that
        // hardcoded path a symlink that points into our unified
        // models root. From FluidAudio's perspective nothing changes;
        // from the user's perspective all models live under
        // StreamScribe/Models/.
        //
        // **Timing.** Stored properties on this struct initialize
        // before this init body runs, so technically they fire before
        // HF_HOME is set. None of them load models in their
        // initializers though — they just hold state. The first model
        // load happens on Start button or Download button, long after
        // this setenv. swift-transformers' HubApi reads HF_HOME at
        // the moment of each request, not at startup, so late-binding
        // works.
        //
        // **Override semantics.** `setenv` with `overwrite=0` so an
        // explicit HF_HOME from the launch environment (e.g. set in
        // a developer's shell or Xcode scheme) wins. Lets us test
        // with the default cache location without rebuilding.
        Self.setupUnifiedModelsRoot()

        // Start log capture FIRST, before any other code that might print.
        // Doing this in init() rather than .task or onAppear ensures we catch
        // ToolManager.bootstrap()'s prints below, plus any TranscriptionEngine
        // setup output. Anything that prints before this line will only land in
        // Xcode's console, not in the in-app viewer.
        StreamScribeLogger.shared.startCapture()

        // Kick off the yt-dlp version check + auto-download in the background, so by
        // the time the user enters a YouTube URL the binary is ready.
        ToolManager.shared.bootstrap()

        // Seed the model-presence indicator from disk. Runs synchronously on
        // the main actor (probes are cheap — a few `fileExists` checks per
        // model), which is fine here since `init` is already on main and the
        // app launch is gated on it anyway. After this, the sidebar opens
        // with accurate "Downloaded" / "Not downloaded" labels rather than
        // a row of "Not checked" placeholders.
        Task { @MainActor in
            ModelDownloadManager.shared.refreshAllOnDiskStatuses()
        }

        // Media-cache lifecycle. We clear on launch to sweep leftovers
        // from a crashed prior session (the regular per-quit cleanup
        // doesn't run if the app didn't exit cleanly), and register for
        // `NSApplicationWillTerminateNotification` to clear on a clean
        // quit too. New-transcription-start triggers a third clear in
        // `TranscriptionEngine.start` so the cache only ever holds the
        // currently-displayed session's media (audio + video).
        MediaCacheManager.clearAll()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            MediaCacheManager.clearAll()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(transcriptionEngine)
                .environmentObject(toolManager)
                .environmentObject(modelDownloadManager)
                .environmentObject(notificationService)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    // Fire-and-forget launch-time update check — runs
                    // on EVERY launch (no throttle) so users hear
                    // about new versions at the earliest opportunity.
                    // The ~200-500 ms GitHub round-trip happens during
                    // ContentView appearance and doesn't block the
                    // window from showing; the alert appears if a
                    // newer version exists.
                    await updateChecker.checkOnLaunch()
                }
                .task {
                    // Backfill the first-time-setup flag for existing
                    // users who already have a cookieBrowser configured.
                    // Without this backfill, an existing user upgrading
                    // to this version would see the "Welcome" sheet on
                    // their first post-upgrade launch even though they're
                    // not new — the flag's default-false means we can't
                    // distinguish "new install" from "old install never
                    // touched this key" by the flag alone. The
                    // cookieBrowser check is our heuristic: a user with
                    // any non-default cookies setting has clearly used
                    // the app before.
                    if !hasCompletedFirstTimeSetup && toolManager.cookieBrowser != .none {
                        hasCompletedFirstTimeSetup = true
                    }
                }
                .sheet(isPresented: Binding(
                    get: { !hasCompletedFirstTimeSetup },
                    set: { isPresented in
                        // SwiftUI sets isPresented=false on any dismissal
                        // (button tap, Esc, click outside). The Continue
                        // and Skip buttons in WelcomeView already flip
                        // hasCompletedFirstTimeSetup; this binding makes
                        // Esc/outside-click also count as "complete" so
                        // we don't nag users who closed the sheet without
                        // making an explicit choice.
                        if !isPresented { hasCompletedFirstTimeSetup = true }
                    }
                )) {
                    WelcomeView()
                        .environmentObject(toolManager)
                        .environmentObject(notificationService)
                }
                .alert(
                    "Update Available",
                    isPresented: Binding(
                        get: { updateChecker.updateAvailable != nil },
                        set: { isPresented in
                            // SwiftUI sets isPresented=false when the
                            // alert is dismissed by any means (button tap,
                            // Esc, click outside). Each button's action
                            // already updates state appropriately; this
                            // binding just guards against orphan state
                            // by clearing updateAvailable on any dismissal.
                            if !isPresented { updateChecker.dismissAlert() }
                        }
                    ),
                    presenting: updateChecker.updateAvailable
                ) { release in
                    Button("Download…") {
                        NSWorkspace.shared.open(release.pageURL)
                        updateChecker.dismissAlert()
                    }
                    Button("Skip This Version") {
                        updateChecker.skipVersion(release.version)
                    }
                    Button("Remind Me Later", role: .cancel) {
                        updateChecker.dismissAlert()
                    }
                } message: { release in
                    Text("StreamScribe \(release.version) is available. You're running \(updateChecker.currentVersion).\n\n\(release.body)")
                }
                // Result alert for MANUAL update checks (app-menu item
                // or Settings button) when there's no update or the
                // check failed. Without this, clicking "Check for
                // Updates" while already current does nothing visible
                // — which reads as broken. Automatic launch checks
                // never populate manualCheckResult, so this alert
                // can't fire on startup.
                .alert(
                    "Software Update",
                    isPresented: Binding(
                        get: { updateChecker.manualCheckResult != nil },
                        set: { isPresented in
                            if !isPresented { updateChecker.manualCheckResult = nil }
                        }
                    )
                ) {
                    Button("OK", role: .cancel) {
                        updateChecker.manualCheckResult = nil
                    }
                } message: {
                    Text(updateChecker.manualCheckResult ?? "")
                }
                // Clear-cache confirmation alert. Routed via @State binding
                // toggled from the Debug menu's "Clear Model Cache…" item.
                // Lives here on ContentView (rather than next to the menu
                // item) because `Button` inside `CommandMenu` can't host
                // its own `.alert` modifier — the alert needs to attach
                // to a regular `View`, and ContentView is the natural
                // owner of any app-level UI.
                .alert(
                    "Clear all model caches?",
                    isPresented: $showClearCacheConfirmation
                ) {
                    Button("Clear", role: .destructive) {
                        Task {
                            let cleared = await ModelDownloadManager.shared.clearAllModelCaches()
                            await MainActor.run {
                                clearCacheCompletionMessage = "Wiped \(cleared.count) cache director\(cleared.count == 1 ? "y" : "ies"). Models will re-download on next session start (or use the sidebar Download buttons)."
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This deletes downloaded model files from disk. The next session will need to re-download them (~2.5 GB for TDT-CTC 1.1B + FluidAudio).")
                }
                .alert(
                    "Cache Cleared",
                    isPresented: Binding(
                        get: { clearCacheCompletionMessage != nil },
                        set: { if !$0 { clearCacheCompletionMessage = nil } }
                    ),
                    presenting: clearCacheCompletionMessage
                ) { _ in
                    Button("OK", role: .cancel) {
                        clearCacheCompletionMessage = nil
                    }
                } message: { msg in
                    Text(msg)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .saveItem) {
                Button("Export Transcript…") {
                    NotificationCenter.default.post(name: .exportTranscript, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(transcriptionEngine.segments.isEmpty)
            }
            // Replace the default "About StreamScribe" item so we can inject a
            // credits line into the standard macOS about panel. macOS reads
            // the credits from the `NSApplication.AboutPanelOptionKey.credits`
            // option when present; without an override, it falls back to the
            // contents of a `Credits.rtf` resource (we ship none), which would
            // leave the panel without our line. The standard panel layout —
            // app icon, name, version, copyright, then credits — is exactly
            // what we want; we're only adjusting the credits text.
            CommandGroup(replacing: .appInfo) {
                Button("About StreamScribe") {
                    let credits = NSAttributedString(
                        string: "Developed by Jamie Forte with help from our friend Claude.",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                            .foregroundColor: NSColor.labelColor,
                            .paragraphStyle: {
                                let p = NSMutableParagraphStyle()
                                p.alignment = .center
                                return p
                            }()
                        ]
                    )
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .credits: credits
                    ])
                }
            }
            CommandGroup(after: .appInfo) {
                Divider()
                // App update check. Standard macOS placement — right
                // under "About <App>" in the app menu, where Sparkle-
                // based apps put "Check for Updates…". Uses the same
                // forced check as the Settings button (ignores the
                // skip-version preference — a user explicitly asking
                // wants a definitive answer). If an update exists,
                // the standard update alert fires via the existing
                // `updateAvailable` binding; if not, the check is
                // silent aside from the console log. The item shows
                // a checking state and disables while in flight so
                // rapid re-clicks don't stack requests.
                Button(updateChecker.isChecking
                       ? "Checking for Updates…"
                       : "Check for StreamScribe Updates…") {
                    Task { await updateChecker.checkNow() }
                }
                .disabled(updateChecker.isChecking)
                Divider()
                Button(updateMenuTitle) {
                    Task { await toolManager.updateYTDlpNow() }
                }
                .disabled(updateMenuDisabled)
                Button(denoUpdateMenuTitle) {
                    Task { await toolManager.updateDenoNow() }
                }
                .disabled(denoUpdateMenuDisabled)
            }
            // Log viewer command, lives under the standard Window menu so it sits
            // alongside macOS's built-in window-management items. ⌘L is a common
            // shortcut for "show log" in dev tools (Xcode's GPU Frame Capture log,
            // Terminal's clear, etc. — context-dependent but well-precedented).
            CommandGroup(after: .windowList) {
                Divider()
                Button("Show Logs") {
                    openWindow(id: WindowID.logs)
                }
                .keyboardShortcut("l", modifiers: [.command])
                // Miniplayer — only enabled when there's a playable
                // audio source. Same window-id idiom as Show Logs so a
                // second click brings the existing window forward
                // rather than spawning duplicates.
                Button("Open Miniplayer") {
                    openWindow(id: WindowID.miniplayer)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(transcriptionEngine.playbackMediaURL == nil)
            }

            // File menu addition: clear the media cache directory on
            // demand. The cache also auto-clears on app quit and on
            // each new transcription start (see TranscriptionEngine.start),
            // but a manual clear is useful for users who want to reclaim
            // disk between long sessions without quitting the app.
            CommandGroup(after: .saveItem) {
                Button("Clear Media Cache") {
                    MediaCacheManager.clearAll()
                }
            }

            // Debug menu visibility: always in DEBUG builds, opt-in
            // via Settings → Advanced → "Show Debug menu" in release.
            // See `showDebugMenu` for the policy.
            if showDebugMenu {
                // Test harness for multi-pass refinement (Phases 1–3). All items
                // DEBUG-only originally; now available in release for opt-in
                // users via the Settings checkbox. The real pipeline (Phase 4+)
                // drives these paths in release builds.
                //
                // Phase 1+2 visual swap workflow:
                //   • "Mark Last 30s as Raw" (⌘⇧W) — flips recent segments to
                //     `.raw` so the reduced-opacity + "live" indicator becomes
                //     visible.
                //   • "Refine Last 30s (Test)" (⌘⇧R) — swaps the last-30s range
                //     with a synthetic "[refined]"-prefixed version. After ⌘⇧W
                //     to watch the raw → refined transition end-to-end.
                //
                // Phase 3 concurrency workflow:
                //   • "Toggle Refinement Enabled" (⌘⇧E) — flips the engine's
                //     `refinementEnabled` flag so the next session loads both the
                //     raw and refined backend pairs. No UI for this yet (Phase 6
                //     adds the Refinement sidebar subsection).
                //   • "Test Concurrent Backends" (⌘⇧T) — fires all four backends
                //     in parallel on whatever audio is currently in flight, logs
                //     timing and result shapes. Only works mid-session AND with
                //     refinement enabled at session start.
                CommandMenu("Debug") {
                Button("Mark Last 30s as Raw") {
                    DebugHarness.markLast30sAsRaw(engine: transcriptionEngine)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(transcriptionEngine.segments.isEmpty)

                Button("Refine Last 30s (Test)") {
                    DebugHarness.refineLast30s(engine: transcriptionEngine)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(transcriptionEngine.segments.isEmpty)

                Divider()

                Button(transcriptionEngine.refinementEnabled
                       ? "Disable Refinement (Next Session)"
                       : "Enable Refinement (Next Session)") {
                    transcriptionEngine.refinementEnabled.toggle()
                    print("[Debug] refinementEnabled = \(transcriptionEngine.refinementEnabled)")
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Test Concurrent Backends") {
                    Task { @MainActor in
                        await transcriptionEngine._debugRunConcurrentBackends()
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!transcriptionEngine.state.isActive)

                Button("Show Refinement Stats") {
                    DebugHarness.dumpRefinementStats(engine: transcriptionEngine)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                // Toggle that forces every subsequent model download
                // to skip HuggingFace and go straight to the R2 mirror.
                // Persisted across launches via the @AppStorage binding
                // below — both this label and ModelDownloadManager's
                // runtime check read the same UserDefaults key.
                //
                // No keyboard shortcut on this one because it's a
                // session-scope setting (set it once, forget about it),
                // not an action you'd repeatedly invoke.
                Button(forceMirrorDownload
                       ? "Disable Force R2 Mirror"
                       : "Force R2 Mirror (Skip HuggingFace)") {
                    forceMirrorDownload.toggle()
                    print("[Debug] forceMirrorDownload = \(forceMirrorDownload)")
                }

                // Force-show the Retry probe button regardless of
                // probe state. Surfaces it whenever there's a yt-dlp-
                // eligible URL in the input field, so paste any
                // YouTube link and the button appears next to the
                // source label. Used for visual verification — the
                // button is otherwise hard to test because it only
                // shows up when the probe legitimately fails, which
                // is hard to reproduce on a working network.
                Button(debugForceShowRetryProbeButton
                       ? "Disable Force Retry Probe Button"
                       : "Force Retry Probe Button (Always Show)") {
                    debugForceShowRetryProbeButton.toggle()
                    print("[Debug] debugForceShowRetryProbeButton = \(debugForceShowRetryProbeButton)")
                }

                Divider()

                // Re-shows the first-launch welcome sheet by clearing
                // the persisted completion flag. The sheet's
                // .sheet(isPresented:) binding observes
                // hasCompletedFirstTimeSetup, so flipping the flag back
                // to false triggers the sheet to appear immediately —
                // no app restart needed. Useful for testing the
                // welcome flow itself, the Keychain prompt behavior on
                // browser selection, and the "Skip for Now" path,
                // none of which are otherwise easy to reach once
                // first-time setup has completed on the user's machine.
                Button("Show Welcome Screen Again") {
                    hasCompletedFirstTimeSetup = false
                    print("[Debug] hasCompletedFirstTimeSetup = false (welcome sheet will re-appear)")
                }

                Divider()

                // Wipe every model cache directory we know about. Used
                // for testing the download flow itself (verifying
                // progress bars, error states, R2-vs-HF fallback paths)
                // without manually `rm -rf`-ing cache dirs from Terminal.
                //
                // Routes through a confirmation alert because the action
                // is destructive — the next session start will re-trigger
                // a full ~2.5 GB download (TDT-CTC 1.1B + FluidAudio +
                // whatever else was cached). The alert lives on
                // ContentView's window since `Button` inside `CommandMenu`
                // can't host its own `.alert` modifier.
                Button("Clear Model Cache…") {
                    showClearCacheConfirmation = true
                }
            }
            }  // end of `if showDebugMenu`
        }

        // Singleton tool window for the log viewer. `Window(_:id:)` creates exactly
        // one instance — re-issuing openWindow(id:) brings the existing one
        // forward rather than spawning duplicates, which is the right behavior for
        // a debug tool (you don't want three log windows).
        Window("Logs", id: WindowID.logs) {
            LogViewerWindow()
                .frame(minWidth: 700, minHeight: 400)
        }
        .windowResizability(.contentMinSize)

        // Miniplayer — floating audio/video player for replaying a
        // finished transcription's media. Hosts AVPlayerView, a
        // click-to-seek hook from the transcript pane, and a periodic
        // time observer that drives transcript-line highlighting. See
        // MiniplayerWindow for the full behavior. We use Window (not
        // WindowGroup) so a second open-request brings the existing
        // miniplayer forward instead of spawning duplicates — matches
        // MacWhisper's behavior.
        Window("Miniplayer", id: WindowID.miniplayer) {
            MiniplayerWindow()
                .environmentObject(transcriptionEngine)
                .frame(minWidth: 360, minHeight: 200)
        }
        .windowResizability(.contentMinSize)

        // Settings scene — auto-wires StreamScribe → Settings… (⌘,) on
        // macOS 13+. No custom NSWindow plumbing needed; SwiftUI manages
        // the lifecycle. Single-pane today (export-format-only) per the
        // SettingsView's own header comment; will grow as we add other
        // preference sections.
        Settings {
            // SettingsView's "Re-apply Dictionary" button reads from
            // the engine's segments and mutates them in place. Inject
            // the same engine instance the rest of the app uses so
            // the button operates on the live session's transcript,
            // not a phantom empty instance.
            //
            // **Belt-and-suspenders injection.** Both an
            // environmentObject AND a custom EnvironmentKey inject
            // the same engine. SettingsView reads via the custom key
            // (which gracefully returns nil if injection ever fails);
            // the environmentObject remains for any legacy code path
            // that might still expect it. If either mechanism breaks
            // in a future macOS SwiftUI regression, the other keeps
            // the Settings window operational.
            SettingsView()
                .environmentObject(transcriptionEngine)
                .environment(\.engineInstance, transcriptionEngine)
        }
    }

    /// Menu title reflects current version + status.
    private var updateMenuTitle: String {
        let version = toolManager.ytDlpVersion ?? "not installed"
        switch toolManager.ytDlpStatus {
        case .checking: return "Checking yt-dlp…"
        case .downloading(let p): return "Updating yt-dlp… \(Int(p * 100))%"
        default: return "Update yt-dlp Now (\(version))"
        }
    }

    private var updateMenuDisabled: Bool {
        switch toolManager.ytDlpStatus {
        case .checking, .downloading: return true
        default: return false
        }
    }

    private var denoUpdateMenuTitle: String {
        let version = toolManager.denoVersion ?? "not installed"
        switch toolManager.denoStatus {
        case .checking: return "Checking Deno…"
        case .downloading(let p): return "Downloading Deno… \(Int(p * 100))%"
        case .extracting: return "Extracting Deno…"
        default: return "Update Deno Now (\(version))"
        }
    }

    private var denoUpdateMenuDisabled: Bool {
        switch toolManager.denoStatus {
        case .checking, .downloading, .extracting: return true
        default: return false
        }
    }
}

/// Stable identifiers for non-document windows. Centralized so callers don't
/// pass stringly-typed IDs that drift over time.
enum WindowID {
    static let logs = "streamscribe.logs"
    static let miniplayer = "streamscribe.miniplayer"
}

extension Notification.Name {
    static let exportTranscript = Notification.Name("StreamScribe.exportTranscript")

    /// Posted by `TranscriptPaneView` (or any other view) when a
    /// transcript line is tapped while the miniplayer is open. The
    /// payload's `object` is a `TimeInterval` (the segment start time
    /// in seconds). MiniplayerWindow listens and calls `player.seek(to:)`.
    /// Decoupling the two views via NotificationCenter avoids threading
    /// a player binding through view hierarchies they don't otherwise
    /// share.
    static let miniplayerSeek = Notification.Name("StreamScribe.miniplayerSeek")

    /// Posted by MiniplayerWindow's periodic time observer. Payload's
    /// `object` is the current `TimeInterval`. TranscriptPaneView
    /// subscribes to drive the playing-segment highlight + auto-scroll.
    static let miniplayerTimeUpdate = Notification.Name("StreamScribe.miniplayerTimeUpdate")
}

/// Diagnostic helpers driven from the Debug menu in `StreamScribeApp.commands`.
///
/// Previously gated by `#if DEBUG` so release builds neither exposed the menu
/// nor compiled the helper. With the user-opt-in Debug menu visibility
/// (Settings → Advanced → "Show Debug menu"), the helper now needs to be
/// available in release builds too — otherwise the menu items here would be
/// dead in any non-DEBUG configuration.
///
/// Kept as an `enum` (uninhabited) to make clear there's no instance state —
/// just static entry points. The helpers mutate engine state in ways the
/// normal pipeline wouldn't (force-marking segments as raw, swapping in
/// synthetic refined versions, etc.) — fine for diagnostics, not something
/// average users should be triggering, which is why visibility defaults off
/// in release.
enum DebugHarness {
    /// Flips the most recent ~30s of segments to `.raw` so the UI's reduced-
    /// opacity + "live" dot indicator becomes visible without needing the
    /// refinement-enabled live pipeline to actually be running. Pure Phase 1
    /// visual-treatment test. The count chosen (most recent ~30s of segments,
    /// not most recent N) keeps the window definition consistent with
    /// `refineLast30s` so the same range gets marked then refined.
    @MainActor
    static func markLast30sAsRaw(engine: TranscriptionEngine) {
        let segments = engine.segments
        guard let last = segments.last else { return }
        let windowStart = max(0, last.end - 30.0)
        let countInWindow = segments.filter { $0.end > windowStart }.count
        guard countInWindow > 0 else { return }
        engine._debugMarkLastSegmentsAsRaw(count: countInWindow)
        print("[Debug] Marked \(countInWindow) segment(s) in last 30s as .raw.")
    }

    /// Phase 2 test harness for `replaceSegments(in:with:)`. Builds a synthetic
    /// "refined" version of the most recent ~30s of transcript and feeds it
    /// through the block-replacement primitive. The real refinement scheduler
    /// (Phase 4) will do this with actual Whisper + SpeakerKit output; for now
    /// this proves the swap works and lets the UI's raw → refined transition
    /// be eyeballed without a working refinement pipeline.
    ///
    /// Strategy: take everything in the last 30s window, mark the synthetic
    /// segments as `.refined`, prefix each segment's text with "[refined] "
    /// so the swap is unmistakeable on screen, and replace the range. Speaker
    /// labels are preserved verbatim — Phase 5 handles cross-pass speaker
    /// continuity; this harness doesn't pretend to.
    @MainActor
    static func refineLast30s(engine: TranscriptionEngine) {
        let segments = engine.segments
        guard let last = segments.last else { return }

        let windowEnd = last.end
        let windowStart = max(0, windowEnd - 30.0)

        let segsInWindow = segments.filter { $0.start < windowEnd && $0.end > windowStart }
        guard !segsInWindow.isEmpty else {
            print("[Debug] refineLast30s: no segments in window — nothing to do.")
            return
        }

        // Build "refined" replacements. Each input segment becomes one output
        // segment with the same timing/speaker but a "[refined]"-tagged text
        // so the swap is visible. New UUIDs so the view diffs them as fresh
        // insertions (otherwise SwiftUI would try to reconcile in-place and
        // the transition wouldn't fire).
        let refined: [TranscriptSegment] = segsInWindow.map { seg in
            TranscriptSegment(
                text: "[refined] " + seg.text,
                start: seg.start,
                end: seg.end,
                speaker: seg.speaker,
                isFinalized: true,
                refinementState: .refined
            )
        }

        engine.replaceSegments(in: windowStart...windowEnd, with: refined)
    }

    /// Phase 7: log a snapshot of the refinement pipeline's rolling stats
    /// to the standard log (visible in ⌘L). Intended use: spot-check what
    /// the adaptive-cadence policy is doing mid-session, or diagnose why
    /// the active cadence is high. Includes a small ASCII histogram of the
    /// last N latencies so the shape of the distribution (one outlier vs.
    /// systemic slowness) is visible at a glance.
    @MainActor
    static func dumpRefinementStats(engine: TranscriptionEngine) {
        let s = engine.refinementStats
        print("[Refinement/Stats] ─── snapshot ───")
        print("[Refinement/Stats] cadence: active=\(Int(engine.activeRefineCadence))s, nominal=\(Int(engine.refineCadenceSeconds))s, window=\(Int(engine.refineWindowSeconds))s")
        print("[Refinement/Stats] windows: refined=\(s.windowsRefined), failed=\(s.windowsFailed), dropped=\(s.windowsDropped)")
        if s.latencies.isEmpty {
            print("[Refinement/Stats] latencies: (no data yet)")
        } else {
            print("[Refinement/Stats] latencies: p50=\(String(format: "%.2f", s.p50))s, p95=\(String(format: "%.2f", s.p95))s")
            // Tiny histogram of the rolling window, oldest→newest. Bar
            // height scales to the current max so each session reads
            // consistently against its own data. Guarded against a 0 max
            // (would div-by-zero into Int conversion); 0.001 is "no
            // measurable time" — show empty bars rather than crash.
            let max = Swift.max(s.latencies.max() ?? 0, 0.001)
            let line = s.latencies.map { latency -> String in
                let pct = latency / max
                let bar = String(repeating: "▇", count: Int(pct * 6.0))
                return "\(String(format: "%.1f", latency))s\(bar)"
            }.joined(separator: " ")
            print("[Refinement/Stats] last \(s.latencies.count): \(line)")
        }
    }
}
