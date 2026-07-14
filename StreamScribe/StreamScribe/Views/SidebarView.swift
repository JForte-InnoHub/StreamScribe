import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications

struct SidebarView: View {
    @EnvironmentObject var engine: TranscriptionEngine
    @EnvironmentObject var toolManager: ToolManager
    @EnvironmentObject var modelDownloadManager: ModelDownloadManager
    @EnvironmentObject var notificationService: NotificationService
    @ObservedObject private var videoDownloadService = VideoDownloadService.shared
    @Binding var urlInput: String
    let onStart: () -> Void
    let onStop: () -> Void
    let onExport: () -> Void

    /// Window focus state. When the host window isn't the key window
    /// (user clicked another app or another window), this becomes
    /// `.inactive`. The control bar uses it to drop the primary buttons
    /// from `.borderedProminent` to `.bordered` styling — keeps them
    /// readable when inactive instead of fading to near-invisible.
    @Environment(\.controlActiveState) private var controlActiveState

    /// Buffer for the current keyword being typed. We commit to
    /// `engine.watchedKeywords` on Return or when the user clicks the add button.
    /// Pasting a comma- or newline-separated list is also supported — we split on
    /// commit so power users don't have to add chips one at a time.
    @State private var keywordDraft: String = ""

    /// Buffer for the speaker-search field. Used to filter the
    /// voiceprint template list shown as suggestions below the
    /// field. Unlike the keyword draft, this string is NEVER
    /// committed directly — only template names are added to
    /// `engine.spottedSpeakers`, via the suggestion list, never via
    /// free-form text entry.
    @State private var speakerSearchDraft: String = ""

    /// One-shot flag: have we ever auto-paired Parakeet with Sortformer?
    /// The first time the user picks Parakeet as the transcription engine
    /// we flip the diarizer to Sortformer (the matching MLX-streaming
    /// companion) as a convenience default. After that, this flag latches
    /// and we never auto-change the diarizer again — whatever diarizer
    /// choice the user makes from then on is sticky, even if they toggle
    /// engines back and forth. Persisted in UserDefaults via @AppStorage
    /// so it survives app restarts (since the engine/diarizer @Published
    /// properties on TranscriptionEngine themselves don't persist; this
    /// flag would be useless if it reset every launch).
    @AppStorage("engine.parakeetSortformerAutopairFired")
    private var parakeetSortformerAutopairFired: Bool = false

    // Section collapse states. Each sidebar section can be expanded
    // (default) or collapsed by clicking its header chevron. Persisted
    // via @AppStorage so the user's "I never use the refinement
    // controls, hide them" choice survives app restarts. Default
    // values are `true` (expanded) — the user has to opt INTO hiding
    // anything, so a fresh install looks like before.
    @AppStorage("sidebar.expanded.source") private var sourceExpanded: Bool = true
    @AppStorage("sidebar.expanded.mode") private var modeExpanded: Bool = true
    @AppStorage("sidebar.expanded.transcription") private var transcriptionEngineExpanded: Bool = true
    @AppStorage("sidebar.expanded.diarization") private var diarizationEngineExpanded: Bool = true
    @AppStorage("sidebar.expanded.refinement") private var refinementExpanded: Bool = true
    @AppStorage("sidebar.expanded.keywords") private var keywordsExpanded: Bool = true
    @AppStorage("sidebar.expanded.spotter") private var spotterExpanded: Bool = true
    @AppStorage("sidebar.expanded.status") private var statusExpanded: Bool = true
    @AppStorage("sidebar.expanded.tools") private var toolsExpanded: Bool = true

    /// Debug-only toggle (Debug menu): when on, the Retry probe
    /// button surfaces regardless of probe state. Used for verifying
    /// the button's visual appearance and tap behavior without
    /// having to actually break the probe. Reads/writes the same
    /// UserDefaults key the Debug menu binds to, so toggling the
    /// menu item flips this and re-renders the sidebar.
    @AppStorage("debug.forceShowRetryProbeButton") private var debugForceShowRetryProbeButton: Bool = false

    /// "Show all models" toggle in Settings → Advanced. Default off:
    /// the pickers show only the curated essential set
    /// (`essentialWhisperModels` / `essentialParakeetModels` from
    /// TranscriptionEngine). When on, every variant in
    /// `availableWhisperModels` / `availableParakeetModels` shows up.
    /// Persisted via @AppStorage so the choice survives launches.
    ///
    /// Always-on safety: regardless of this flag, if the currently-
    /// selected model isn't in the essential list, the picker still
    /// shows it (see the visibleWhisperModels/visibleParakeetModels
    /// computeds below). That keeps users from losing their selection
    /// mid-session if they toggled the flag.
    @AppStorage("models.showAllModels") private var showAllModels: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("StreamScribe")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                Text("Real-time stream transcription")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    urlSection
                    modeSection
                    statusSection
                    transcriptionEngineSection
                    diarizationEngineSection
                    refinementSection
                    keywordsSection
                    speakerSpotterSection
                    toolsSection
                }
                .padding(20)
            }

            Divider()
            controlBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Sections

    private var urlSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Source", isExpanded: $sourceExpanded)
            if sourceExpanded {
                TextField("URL, YouTube link, or file path", text: $urlInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(engine.state.isActive)
                    .onSubmit {
                        if !engine.state.isActive { onStart() }
                    }
                    // Eager-probe (Phase 8): kick off a duration probe whenever
                    // the URL changes. The engine's `beginProbe` cancels any
                    // in-flight probe, classifies the URL, and (for cheap probes
                    // only — local files, HLS, direct audio) runs a background
                    // probe whose result flows into `engine.probeStatus`.
                    // yt-dlp sources defer to start-time probing to avoid
                    // hitting macOS Keychain on every URL paste.
                    //
                    // `initial: true` runs once at view setup so a URL that's
                    // already in the field (e.g. a launched-with-URL deep link)
                    // gets probed too.
                    .onChange(of: urlInput, initial: true) { _, newValue in
                        engine.beginProbe(for: newValue)
                    }

                HStack(spacing: 8) {
                    Button(action: chooseFile) {
                        Label("Choose File…", systemImage: "folder")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                    .disabled(engine.state.isActive)

                    // Download Video button. Visible when the probe
                    // has classified the URL as static (a finite-
                    // duration video, not a live stream) and the
                    // engine is idle. The static-only restriction
                    // matters because yt-dlp's HLS-live download
                    // would never terminate — the user would need a
                    // separate "record live stream" flow we don't
                    // offer here.
                    //
                    // Clicking opens NSSavePanel defaulted to
                    // ~/Downloads with the probed title as the
                    // suggested filename. The download is fire-and-
                    // forget; progress shows in the status row
                    // below.
                    if showDownloadButton {
                        Button(action: downloadVideo) {
                            Label("Download Video…", systemImage: "arrow.down.circle")
                                .font(.system(size: 11))
                        }
                        .controlSize(.small)
                        .disabled(engine.state.isActive || videoDownloadService.isDownloading)
                    }

                    Spacer()
                }

                // Inline download progress / status. Renders only
                // while a download is in progress, just finished, or
                // failed — hidden when idle so the sidebar doesn't
                // carry dead UI between downloads. Sits directly under
                // the buttons so the progress feels attached to the
                // action that started it.
                if !videoDownloadService.statusText.isEmpty {
                    videoDownloadStatusRow
                }

                // Title from the probe, shown above the source/duration line.
                // Only appears when we actually have one — for HLS / direct
                // audio URLs that yt-dlp can't title, this row stays hidden so
                // we don't add visual noise saying "no title".
                //
                // The title can be long (especially YouTube hearings or panel
                // discussions), so we let it wrap to 2 lines and truncate
                // beyond that. Tail truncation preserves the front of the
                // title which is usually the most identifying part.
                if let title = engine.detectedTitle, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    Image(systemName: sourceIcon)
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 10))
                    Text(sourceLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    // Retry probe button. Surfaces when the eager probe
                    // failed — common on first launch when network state
                    // hasn't fully come up, when the user pastes a URL
                    // before the cookie jar / SSL trust store is ready,
                    // or when a transient yt-dlp / network error hit. Re-
                    // entering the URL works around it, but a one-click
                    // retry is faster and more discoverable.
                    //
                    // The button only renders for yt-dlp-eligible sources
                    // — local files don't fail probe in a recoverable way
                    // (if AVURLAsset can't read it, retrying won't help),
                    // and HLS / direct-audio probe paths are already
                    // resilient enough that surfacing a retry would just
                    // be noise.
                    //
                    // Debug override: when `debugForceShowRetryProbeButton`
                    // is on (Debug menu → "Force Retry Probe Button"),
                    // surface the button even on a successful probe so
                    // we can verify its appearance and tap behavior
                    // without having to actually break the probe. The
                    // URL-non-empty and requiresYTDlp conditions are
                    // still honored — those gate to "type a YouTube URL
                    // and you should see it," which matches the real-
                    // world scenario the debug toggle is simulating.
                    let probeFailureReason: String? = {
                        if case .failed(let r) = engine.probeStatus { return r }
                        if debugForceShowRetryProbeButton {
                            return "Debug: forced visibility (probe didn't actually fail)"
                        }
                        return nil
                    }()
                    if let reason = probeFailureReason,
                       (liveDetectedSource.requiresYTDlp || liveDetectedSource == .criticalMention || liveDetectedSource == .granicus),
                       !urlInput.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button {
                            engine.beginProbe(for: urlInput)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 9))
                                Text("Retry")
                                    .font(.system(size: 10))
                            }
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                        .help("Probe failed: \(reason). Click to retry.")
                    }
                }
            }
        }
    }

    /// Show NSOpenPanel for picking a local audio/video file.
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Audio or Video File"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // Build allowed types from our supported extensions list. We pull the UTType
        // from the extension; ones the system doesn't know are skipped silently.
        panel.allowedContentTypes = StreamSource.supportedFileExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        if panel.runModal() == .OK, let url = panel.url {
            urlInput = url.path
        }
    }

    /// Show the Download Video button based on URL classification —
    /// available immediately when the user pastes a URL, rather than
    /// waiting for a probe to complete. `resolvedSessionMode` was the
    /// wrong signal: it's only set inside `start()`, which means the
    /// button would never appear until the user clicked Start (defeating
    /// the point of a separate download flow).
    ///
    /// **Visibility rules:**
    ///   - URL field must be non-empty
    ///   - Must look like a URL (contain `://`), not a local file path
    ///   - Source can't be `.hls` — bare HLS streams are usually live
    ///     and would never terminate. Everything else (yt-dlp sources,
    ///     direct audio, etc.) MIGHT be a live stream (YouTube can be
    ///     either), but the vast majority aren't. If a user tries to
    ///     download an active livestream, yt-dlp will error out with a
    ///     clear message — acceptable failure mode vs. hiding the
    ///     button entirely.
    ///
    /// The status text is intentionally NOT a gate here — we want the
    /// button to remain visible during a download so users see why
    /// it's disabled (download in progress).
    private var showDownloadButton: Bool {
        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.contains("://") else { return false }
        let source = liveDetectedSource
        // Local files are already on disk, no download needed.
        if source == .localFile { return false }
        // Bare HLS streams are typically live — hide button to avoid
        // encouraging a download that would never finish.
        if source == .hls { return false }
        return true
    }

    /// Inline status row for the in-flight (or just-completed) video
    /// download. Renders the current `statusText`, a progress bar
    /// while downloading, a cancel button while downloading, and a
    /// dismiss "×" when finished/failed so the user can clear the
    /// row before starting a new download.
    private var videoDownloadStatusRow: some View {
        HStack(spacing: 8) {
            if videoDownloadService.isDownloading {
                ProgressView(value: videoDownloadService.progress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(maxWidth: 80)
            }
            Text(videoDownloadService.statusText)
                .font(.system(size: 10))
                .foregroundStyle(videoDownloadService.lastError != nil ? .red : .secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if videoDownloadService.isDownloading {
                Button {
                    videoDownloadService.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel download")
            } else {
                Button {
                    videoDownloadService.clearStatus()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }

    /// Open NSSavePanel and kick off a download if confirmed.
    ///
    /// **Filename strategy** mirrors `ContentView.exportMedia`: use
    /// the detected title (sanitized for filesystem-unsafe chars),
    /// fall back to "Video" if no title is available, and default
    /// to `.mp4` extension. The user can rename and change extension
    /// in the panel; yt-dlp picks the actual container based on best-
    /// quality source format, and we move-as-renamed to honor the
    /// user's choice — see VideoDownloadService for the detail.
    ///
    /// **Default directory** is `~/Downloads/` per the standard macOS
    /// expectation for "save downloaded content." If the user has
    /// chosen a different directory in a previous Save panel during
    /// this session, NSSavePanel remembers — which is good UX, we
    /// don't fight it.
    private func downloadVideo() {
        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed) else { return }

        let panel = NSSavePanel()
        panel.title = "Download Video"
        panel.canCreateDirectories = true

        // Default to ~/Downloads. NSHomeDirectory respects sandboxing
        // when the app is sandboxed; for an unsandboxed dev build it
        // returns the real user home. Either way "~/Downloads" is
        // what users expect for downloaded content.
        let downloadsURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Downloads", isDirectory: true)
        panel.directoryURL = downloadsURL

        // Sanitize the title for use as a filename. Same rules as
        // ContentView.exportMedia's helper — strip path separators
        // and control chars.
        let rawTitle = engine.detectedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String = {
            guard let t = rawTitle, !t.isEmpty else { return "Video" }
            let bad = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
            return t.components(separatedBy: bad).joined(separator: " ")
        }()
        panel.nameFieldStringValue = "\(title).mp4"

        if let mp4Type = UTType(filenameExtension: "mp4") {
            panel.allowedContentTypes = [mp4Type]
        }

        panel.begin { response in
            guard response == .OK, let destURL = panel.url else { return }
            videoDownloadService.downloadVideo(from: url, to: destURL)
        }
    }

    /// Session mode picker. Picks between Auto (derive from source), Live
    /// (per-chunk diarization, works on streams), and Static (whole-file
    /// diarization, requires bounded duration).
    ///
    /// Default is Auto. The Auto label gains a "(Live)" or "(Static)" suffix
    /// based on the currently-detected source so the user sees what's about
    /// to happen without having to commit to an explicit override. Picker is
    /// disabled while a session is active because mode is read at session
    /// start; toggling mid-stream wouldn't take effect and we don't want to
    /// imply otherwise.
    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Mode", isExpanded: $modeExpanded)
            if modeExpanded {
                Picker("", selection: $engine.sessionMode) {
                    ForEach(SessionMode.allCases) { mode in
                        Text(modeLabel(for: mode)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(engine.state.isActive)

                Text(engine.sessionMode.description)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                // Surface the user-forced-static-on-unknown-duration case. The
                // engine relaxed its guard for yt-dlp sources so the user can
                // override a wrong probe verdict (common for former-livestream
                // archives that yt-dlp can't classify). The escape hatch comes
                // with a footgun though — if the URL is actually live, the
                // fast-download flow will hang forever — so we surface the
                // tradeoff right where the user makes the choice.
                if forcedStaticOnUnknownDuration {
                    Text("Forcing Static — yt-dlp couldn't determine the duration. This works for VODs (recordings) but will hang on a true livestream. Cancel and switch to Live if the URL is actually streaming.")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// True when the user has explicitly chosen Static mode for a yt-dlp
    /// source whose duration probe didn't return a finite value. This is
    /// the case where the engine would previously have hard-errored on
    /// Start; now it proceeds with a warning. We surface that warning in
    /// the sidebar so the user sees the consequence before clicking Start.
    private var forcedStaticOnUnknownDuration: Bool {
        guard engine.sessionMode == .static else { return false }
        // `liveDetectedSource` reads the current URL input field directly
        // rather than the engine's last-committed `detectedSource`, so the
        // hint updates in real time as the user pastes/edits a URL.
        guard liveDetectedSource.requiresYTDlp else { return false }
        // .finite means we have a duration; anything else (.probing,
        // .live, .idle, .failed) means we don't and the engine would
        // previously have rejected the Start.
        switch engine.probeStatus {
        case .finite: return false
        default: return true
        }
    }

    /// Label for a mode in the picker. For .auto, append the resolved mode in
    /// parens so the user can see what Auto would pick right now ("Auto (Live)"
    /// for streams, "Auto (Static, 24:13)" for finite sources). The duration
    /// suffix is included when the engine's eager probe (Phase 8) has
    /// returned a finite value; otherwise we just show the resolved mode.
    private func modeLabel(for mode: SessionMode) -> String {
        guard mode == .auto else { return mode.displayName }
        let resolved = previewAutoMode()
        // Append duration when we have it AND the resolution is Static.
        // For Live mode, duration would be misleading (we may have a
        // partial value mid-probe; better to omit until probing finishes).
        if resolved == .static, let durationStr = probedDurationLabel() {
            return "Auto (Static, \(durationStr))"
        }
        // Probing state — show that explicitly so the user knows the
        // sidebar is going to update once the probe finishes.
        if engine.probeStatus == .probing {
            return "Auto (Probing…)"
        }
        return "Auto (\(resolved.displayName))"
    }

    /// Best-effort preview of what `.auto` would resolve to. Consults the
    /// engine's probe status first — when a finite duration is known, that's
    /// the authoritative signal. Falls back to URL classification when not
    /// yet probed (yt-dlp sources before Start; URLs in pre-probe states).
    private func previewAutoMode() -> SessionMode {
        // Eager probe came back with a finite duration → Static.
        if case .finite(let seconds) = engine.probeStatus, seconds >= 10 {
            return .static
        }
        // Eager probe ran and concluded Live → Live.
        if engine.probeStatus == .live {
            return .live
        }
        // Local files default to Static even before the probe lands —
        // AVURLAsset is synchronous so probe completes nearly instantly.
        // Senate.gov hearings are also Static by default — the vast
        // majority of senate.gov ISVP content is archived (`type=arch`),
        // and the SenateGovExtractor probe lands in ~500 ms-1 s so any
        // mismatched preview here is short-lived. Defaulting senate.gov
        // to Static avoids a brief "Live" flicker in the sidebar mode
        // chip while the probe completes.
        switch liveDetectedSource {
        case .localFile, .senateGov: return .static
        default:                     return .live
        }
    }

    /// True when the configuration is heading toward Live mode and the user
    /// should be warned about using SpeakerKit (which is designed for static
    /// whole-file diarization). Mirrors `refinementControlsEnabled`'s logic
    /// but doesn't require "not currently active" — we want the warning to
    /// show during a session too, so the user can correlate the slowness
    /// they're experiencing with the diarizer choice.
    private var diarizationLiveModeWarning: Bool {
        switch engine.sessionMode {
        case .live: return true
        case .static: return false
        case .auto: return previewAutoMode() == .live
        }
    }

    /// Human-readable mm:ss for the probed duration. Returns nil when no
    /// finite-duration probe result is available.
    private func probedDurationLabel() -> String? {
        guard case .finite(let seconds) = engine.probeStatus else { return nil }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private var transcriptionEngineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Transcription Engine", isExpanded: $transcriptionEngineExpanded)
            if transcriptionEngineExpanded {

            Picker("", selection: $engine.transcriptionEngine) {
                ForEach(TranscriptionEngineKind.allCases) { kind in
                    Text(kind.shortName).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(engine.state.isActive)
            // One-time convenience: the first time the user selects
            // Parakeet, flip the diarizer to Sortformer to match. Both
            // are the MLX-streaming pair and they're typically used
            // together; defaulting the user into that pairing once
            // saves a click. After this fires once, the latch in
            // `parakeetSortformerAutopairFired` prevents it from ever
            // running again — whatever diarizer choice the user makes
            // from that point on is respected, even if they switch
            // engines back to WhisperKit and then back to Parakeet.
            // See the @AppStorage doc comment above for why this lives
            // in UserDefaults rather than as in-memory state.
            .onChange(of: engine.transcriptionEngine) { _, newValue in
                guard newValue == .parakeet,
                      !parakeetSortformerAutopairFired else { return }
                engine.diarizationEngine = .sortformer
                parakeetSortformerAutopairFired = true
            }

            Text(engine.transcriptionEngine.blurb)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            // Model picker switches based on selected engine
            VStack(alignment: .leading, spacing: 4) {
                Text("Model")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                switch engine.transcriptionEngine {
                case .parakeetEOU:
                    // Single-model engine — no picker. The 120M EOU
                    // model downloads automatically via FluidAudio's
                    // hub on first session start.
                    Text("Parakeet EOU 120M — single streaming model, downloaded automatically on first use. English only, no punctuation; pair with a refined-pass model for polished text.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                case .whisperKit:
                    // Group wrapper lets us have a local `let` binding next to
                    // the Picker + modelStatusRow within a @ViewBuilder switch
                    // case (plain `let` statements aren't allowed at the top
                    // level of a ViewBuilder block, but they're fine inside
                    // an explicit Group's closure).
                    Group {
                        Picker("", selection: $engine.whisperModelName) {
                            ForEach(visibleWhisperModels, id: \.self) { m in
                                Text(whisperDisplayName(m)).tag(m)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .disabled(engine.state.isActive)

                        // Per-model status + download button. Sits directly under
                        // the picker so the indicator is tied visually to the
                        // model the user is staring at. Without this the first
                        // transcription on a fresh install silently blocks for
                        // tens of seconds while WhisperKit fetches weights from
                        // Hugging Face; this row makes that visible and lets the
                        // user trigger the fetch ahead of time.
                        let currentWhisperModel = engine.whisperModelName
                        modelStatusRow(
                            key: .whisper(modelName: currentWhisperModel),
                            downloadAction: {
                                // Capture the current model name into the closure
                                // so the prefetch reads the value SwiftUI saw at
                                // body-eval time on MainActor, rather than
                                // re-reading the engine's @Published property
                                // from a non-isolated Task.
                                Task {
                                    await modelDownloadManager.downloadWhisperModel(
                                        name: currentWhisperModel
                                    )
                                }
                            }
                        )
                    }
                case .parakeet:
                    Group {
                        Picker("", selection: $engine.parakeetModelName) {
                            ForEach(visibleParakeetModels, id: \.self) { m in
                                Text(parakeetDisplayName(m)).tag(m)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .disabled(engine.state.isActive)

                        let currentParakeetModel = engine.parakeetModelName
                        modelStatusRow(
                            key: .parakeet(modelRepo: currentParakeetModel),
                            downloadAction: {
                                Task {
                                    await modelDownloadManager.downloadParakeetModel(
                                        repo: currentParakeetModel
                                    )
                                }
                            }
                        )
                    }
                }
            }

            // Language picker (Whisper only — Parakeet is English-only)
            if engine.transcriptionEngine == .whisperKit {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Language")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $engine.selectedLanguageCode) {
                        ForEach(TranscriptionEngine.availableLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(engine.state.isActive)

                    if engine.selectedLanguageCode == nil {
                        Text("Auto-detect can be unreliable on short audio chunks. If transcription comes back empty, try setting an explicit language.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            }
        }
    }

    private var diarizationEngineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Speaker Diarization", isExpanded: $diarizationEngineExpanded)
            if diarizationEngineExpanded {

            Picker("", selection: $engine.diarizationEngine) {
                ForEach(DiarizationEngineKind.allCases) { kind in
                    Text(diarizationShortName(kind)).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(engine.state.isActive)

            // Per-diarizer model status + download button. Sortformer and
            // SpeakerKit each fetch weights from Hugging Face on first use
            // (SpeakerKit's "~30s warm-up before first labels appear" is
            // really the first-run weight download), so the same indicator
            // we attach to the transcription model picker belongs here.
            // The `.off` case has no model to download, so we skip the row
            // entirely — drawing a row that says "Not downloaded" for the
            // no-op backend would be confusing.
            switch engine.diarizationEngine {
            case .off:
                EmptyView()
            case .speakerKit:
                modelStatusRow(
                    key: .speakerKit,
                    downloadAction: {
                        Task { await modelDownloadManager.downloadSpeakerKitModel() }
                    }
                )
            case .sortformer:
                modelStatusRow(
                    key: .sortformer,
                    downloadAction: {
                        Task { await modelDownloadManager.downloadSortformerModel() }
                    }
                )
            case .fluidAudio:
                modelStatusRow(
                    key: .fluidAudio,
                    downloadAction: {
                        Task { await modelDownloadManager.downloadFluidAudioModel() }
                    }
                )
            }

            Text(engine.diarizationEngine.blurb)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            // SpeakerKit is the pyannote-based offline-style backend — heavy,
            // designed for whole-file static-mode diarization. In live mode
            // it runs once per audio chunk, and the chunk pipeline awaits it
            // alongside transcription before pulling the next chunk; on small
            // (5s) chunks this dominates wall-clock and starves the raw pass.
            // Sortformer is the streaming MLX backend designed for live use.
            // Surface the recommendation when the user picks the inverted
            // combo. We check the same conditions as `refinementControlsEnabled`
            // (explicit .live OR auto-resolves-to-live) so the warning fires
            // even when the user has overridden the mode picker.
            if engine.diarizationEngine == .speakerKit && diarizationLiveModeWarning {
                Text("SpeakerKit is designed for static (whole-file) diarization. In Live mode it gates each chunk and slows raw transcription noticeably — consider Sortformer for Live sessions.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            }
        }
    }

    // MARK: - Refinement (multi-pass live mode)

    /// Multi-pass live refinement controls (Phase 6, design §3.5). Toggles
    /// the engine's `refinementEnabled` plus the two timing knobs
    /// `refineWindowSeconds` / `refineCadenceSeconds`. The whole section is
    /// disabled when the resolved mode isn't Live or a session is active —
    /// these are session-start parameters, not runtime tuning. We keep it
    /// visible (rather than hidden) when not in Live mode so the sidebar
    /// layout doesn't jump around as the user changes modes; matches the
    /// "always visible, conditionally disabled" pattern of the existing
    /// sections.
    ///
    /// What the section communicates:
    ///   - Toggle: on means raw 5s chunks + 30s rolling refinement pass.
    ///     Off means today's single-pass live.
    ///   - Window: how long each refinement pass covers. 30s is Whisper's
    ///     native training window so accuracy peaks there.
    ///   - Cadence: how often a window fires. Equal to window = no overlap;
    ///     smaller would overlap but isn't supported yet (Phase 4 clamps).
    private var refinementSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Refinement", isExpanded: $refinementExpanded)
            if refinementExpanded {

            Toggle(isOn: $engine.refinementEnabled) {
                Text("Multi-pass refinement")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!refinementControlsEnabled)

            Text("Show low-latency raw text first, then replace each 30s window with higher-accuracy output. Live mode only.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            // Split-engine controls. Lets the user pair a fast streaming
            // engine (typically Parakeet) on the raw pass with a heavier
            // accuracy-first engine (typically Whisper) on the refined pass.
            // The handoff doc §13 endorsed this as the right way to enable
            // Parakeet in live mode: an opt-in setting, not a forced default.
            //
            // Visibility: only shown when refinement is on AND we're in (or
            // expect to be in) Live mode — same gate as the timing sliders.
            // Disabled while a session is active because changing engines
            // mid-session would tear down loaded backends.
            //
            // When the user picks the same engine in both slots the
            // configuration is equivalent to having the toggle off; the
            // engine treats them as the "Phase 3 option β" mirror config and
            // logs a single transcriber line. No correctness issue, just
            // wasted UI clarity.
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $engine.useSplitRefinedEngine) {
                    Text("Use a different engine for refined pass")
                        .font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                if engine.useSplitRefinedEngine {
                    HStack {
                        Text("Refined")
                            .font(.system(size: 11))
                        Spacer()
                        Picker("", selection: $engine.refinedTranscriptionEngine) {
                            ForEach(TranscriptionEngineKind.allCases) { kind in
                                Text(kind.shortName).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .fixedSize()
                    }

                    // Refined-slot model picker. Independent from the raw
                    // model — same engine kind can use different models
                    // in the two slots (e.g. Whisper Medium raw + Large
                    // v3 Turbo refined for an accuracy boost on the
                    // refinement pass). When the engine kinds match
                    // between slots, this picker just sits alongside the
                    // raw one — the user can pick different models or
                    // the same, both work.
                    refinedModelPicker

                    // Surface the canonical-pair hint when the user picks the
                    // recommended combination, and a soft warning when they
                    // pick the inverted combo (slow engine raw + fast engine
                    // refined). We don't block the inverted combo — the
                    // engine handles any pairing — but the warning hints at
                    // the latency/accuracy mismatch.
                    if engine.transcriptionEngine == .parakeet
                        && engine.refinedTranscriptionEngine == .whisperKit {
                        Text("Parakeet for low-latency display; Whisper for the 30s refinement pass. This is the configuration the split was designed for.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if engine.transcriptionEngine == .whisperKit
                        && engine.refinedTranscriptionEngine == .parakeet {
                        Text("This pairs the slower engine on raw with the faster one on refined — usually you want it the other way around.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if engine.transcriptionEngine == engine.refinedTranscriptionEngine {
                        Text("Both slots use the same engine; toggling this off has the same effect.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .disabled(!refinementParametersEnabled)
            .opacity(refinementParametersEnabled ? 1.0 : 0.5)

            // Post-finish re-diarization. Independent of the multi-pass
            // refinement toggle above — this fires at end-of-session
            // regardless of whether refinement was active. Conceptually
            // adjacent to it (both are "improve the transcript after the
            // raw pass has run") so we place the toggle in the same
            // section, but its enablement uses a separate computed
            // property: live mode AND a diarizer is enabled AND no
            // session running. Refinement-on is NOT required.
            //
            // Engine picker: lets the user choose which diarization backend
            // runs the whole-file pass. Defaults to SpeakerKit for
            // backward compat. Independent of the live diarizer choice
            // — a user can have Sortformer streaming for low-latency
            // live labels and FluidAudio offline for the final relabel.
            // `.off` is filtered out since "rediarize with nothing"
            // would defeat the toggle's purpose.
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $engine.postFinishRediarizeEnabled) {
                    Text("Re-diarize when finished")
                        .font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                if engine.postFinishRediarizeEnabled {
                    HStack {
                        Text("Engine")
                            .font(.system(size: 11))
                        Spacer()
                        Picker("", selection: $engine.rediarizeEngine) {
                            ForEach(DiarizationEngineKind.allCases.filter { $0 != .off }) { kind in
                                Text(kind.rawValue).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .fixedSize()
                    }
                }

                Text("After transcription ends, run a one-shot whole-file diarization pass using the selected engine and re-label every segment. Usually more accurate than the live (streaming) diarizer at the cost of holding the full audio in memory for the session (≈230 MB/hour).")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!postFinishRediarizeControlsEnabled)
            .opacity(postFinishRediarizeControlsEnabled ? 1.0 : 0.5)

            // Timing knobs. Only meaningful when refinement is on AND we're
            // in Live mode; double-gate the disable so they don't suggest
            // applicability they don't have. Sliders rather than text inputs
            // for fast experimentation; bounds chosen to keep within
            // architecturally-supported ranges (window ≤ cadence).
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Window")
                        .font(.system(size: 11))
                    Spacer()
                    Text("\(Int(engine.refineWindowSeconds))s")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $engine.refineWindowSeconds, in: 10...60, step: 5)
                    .controlSize(.small)
            }
            .disabled(!refinementParametersEnabled)
            .opacity(refinementParametersEnabled ? 1.0 : 0.5)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Cadence")
                        .font(.system(size: 11))
                    Spacer()
                    Text("\(Int(engine.refineCadenceSeconds))s")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                // Cadence ≥ window: Phase 4's scheduler clamps internally,
                // but enforcing here keeps the UI honest. Lower bound tracks
                // window's lower bound; upper bound is generous (3× max
                // window) since "refine less often" is a valid choice.
                Slider(value: $engine.refineCadenceSeconds,
                       in: max(10, engine.refineWindowSeconds)...180,
                       step: 5)
                    .controlSize(.small)
            }
            .disabled(!refinementParametersEnabled)
            .opacity(refinementParametersEnabled ? 1.0 : 0.5)
            }
        }
    }

    /// Refined-slot model picker. Used inside `refinementSection` when
    /// split mode is on. Mirrors the raw-engine model picker structure
    /// (same lists, same display names, same modelStatusRow per-row) but
    /// binds against the engine's refined-slot model properties so the
    /// two slots can independently hold different models.
    ///
    /// **Why a `@ViewBuilder` helper rather than inlining.** The switch
    /// on `engine.refinedTranscriptionEngine` produces different picker
    /// content per case (Whisper has language options, Parakeet has its
    /// own model list). Pulling it out keeps the parent body compact and
    /// matches the structure already used for the raw engine block.
    @ViewBuilder
    private var refinedModelPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Refined Model")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            switch engine.refinedTranscriptionEngine {
            case .parakeetEOU:
                // EOU on the refined slot is architecturally wrong —
                // it's a stateful streaming model, and refinement
                // re-transcribes windows out of stream order. Steer
                // users away rather than hard-blocking.
                Text("Parakeet EOU is streaming-only and not suitable as a refined-pass model. Choose WhisperKit or Parakeet (MLX) here instead.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .whisperKit:
                Group {
                    Picker("", selection: $engine.refinedWhisperModelName) {
                        ForEach(visibleWhisperModels, id: \.self) { m in
                            Text(whisperDisplayName(m)).tag(m)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(engine.state.isActive)

                    // Status row for the refined-slot model. Mirrors the
                    // raw picker's status row exactly — surfaces download
                    // state for whichever model is selected here, with
                    // its own prefetch button. This is critical because
                    // the refined model may be different from the raw
                    // one (the whole point of this feature) and the user
                    // needs to be able to prefetch it independently.
                    let currentRefinedWhisperModel = engine.refinedWhisperModelName
                    modelStatusRow(
                        key: .whisper(modelName: currentRefinedWhisperModel),
                        downloadAction: {
                            Task {
                                await modelDownloadManager.downloadWhisperModel(
                                    name: currentRefinedWhisperModel
                                )
                            }
                        }
                    )
                }
            case .parakeet:
                Group {
                    Picker("", selection: $engine.refinedParakeetModelName) {
                        ForEach(visibleParakeetModels, id: \.self) { m in
                            Text(parakeetDisplayName(m)).tag(m)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(engine.state.isActive)

                    let currentRefinedParakeetModel = engine.refinedParakeetModelName
                    modelStatusRow(
                        key: .parakeet(modelRepo: currentRefinedParakeetModel),
                        downloadAction: {
                            Task {
                                await modelDownloadManager.downloadParakeetModel(
                                    repo: currentRefinedParakeetModel
                                )
                            }
                        }
                    )
                }
            }
        }
    }

    /// True when the refinement *toggle* itself should be interactive: Live
    /// (or Auto→Live) mode AND no session currently running. The window/
    /// cadence sliders use a stricter rule (`refinementParametersEnabled`)
    /// that additionally requires the toggle to be on.
    private var refinementControlsEnabled: Bool {
        let modeAllowsRefinement: Bool
        switch engine.sessionMode {
        case .live: modeAllowsRefinement = true
        case .static: modeAllowsRefinement = false
        case .auto:
            // Same preview logic as `modeLabel(for:)`: local files are
            // assumed Static, everything else Live. Engine re-evaluates at
            // Start; this is just the sidebar-time best guess.
            modeAllowsRefinement = (previewAutoMode() == .live)
        }
        return modeAllowsRefinement && !engine.state.isActive
    }

    /// True when the window/cadence sliders should be interactive — same
    /// rule as the toggle plus "the toggle is actually on." Separate
    /// computed property so the visual disable+dim treatment can apply to
    /// the slider block without affecting the toggle row above.
    private var refinementParametersEnabled: Bool {
        refinementControlsEnabled && engine.refinementEnabled
    }

    /// True when the post-finish re-diarization toggle should be
    /// interactive. Independent of the multi-pass refinement toggle: this
    /// fires at session end regardless of whether refinement was active.
    ///   - live mode (in static mode SpeakerKit already runs whole-file as
    ///     the primary diarization pass; the toggle would be redundant)
    ///   - a diarizer is enabled (nothing to re-diarize if `.off`)
    ///   - no session is running (changing this mid-session can't
    ///     retroactively start accumulating the full-audio buffer)
    private var postFinishRediarizeControlsEnabled: Bool {
        let modeAllowsRediarize: Bool
        switch engine.sessionMode {
        case .live: modeAllowsRediarize = true
        case .static: modeAllowsRediarize = false
        case .auto:
            modeAllowsRediarize = (previewAutoMode() == .live)
        }
        return modeAllowsRediarize
            && engine.diarizationEngine != .off
            && !engine.state.isActive
    }

    // MARK: - Keyword watcher

    /// Sidebar block where the user manages the keyword auto-pin list and notification
    /// toggle. Layout:
    ///   • input field + add button (Return submits)
    ///   • flowing chips of currently watched keywords (× to remove)
    ///   • toggle: notify on hit (with auth status surfaced inline)
    private var keywordsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Keyword Watcher", isExpanded: $keywordsExpanded)
            if keywordsExpanded {

            Text("Auto-pin segments containing any of these.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                TextField("Add keyword…", text: $keywordDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(commitKeywordDraft)

                Button(action: commitKeywordDraft) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .controlSize(.small)
                .disabled(keywordDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Add keyword (Return)")
            }

            if !engine.watchedKeywords.isEmpty {
                KeywordChipFlow(
                    keywords: engine.watchedKeywords,
                    onRemove: removeKeyword
                )
            }

            Divider()
                .padding(.vertical, 2)

            // Notification toggle + auth status indicator. We use the toggle's
            // onChange to request authorization the moment the user opts in, rather
            // than waiting for the first keyword hit (which would feel laggy and
            // could miss the prompt window if the OS suppresses it under load).
            Toggle(isOn: $engine.notifyOnKeywordHit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notify on hit")
                        .font(.system(size: 12))
                    Text(notificationStatusText)
                        .font(.system(size: 10))
                        .foregroundStyle(notificationStatusColor)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .onChange(of: engine.notifyOnKeywordHit) { _, newValue in
                guard newValue else { return }
                Task {
                    // Re-check first in case the user previously denied and then
                    // changed it in System Settings — no need to re-prompt.
                    await notificationService.refreshAuthorizationStatus()
                    if !notificationService.isAuthorized {
                        await notificationService.requestAuthorization()
                    }
                }
            }

            // If the user enabled notifications but the system has denied them, make
            // it explicit. Unsigned dev builds frequently hit this silently.
            if engine.notifyOnKeywordHit && !notificationService.isAuthorized {
                Text("Notifications won't be delivered. Enable StreamScribe in System Settings → Notifications.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }
        }
    }

    /// Commit the current draft, splitting on commas/newlines so paste-in lists work.
    /// De-dupes against existing keywords (case-insensitive). Empty entries are dropped.
    private func commitKeywordDraft() {
        let raw = keywordDraft
        let candidates = raw
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return }

        let existingLower = Set(engine.watchedKeywords.map { $0.lowercased() })
        var current = engine.watchedKeywords
        var seenInBatch = Set<String>()
        for c in candidates {
            let key = c.lowercased()
            if existingLower.contains(key) || seenInBatch.contains(key) { continue }
            seenInBatch.insert(key)
            current.append(c)
        }
        engine.watchedKeywords = current
        keywordDraft = ""
    }

    private func removeKeyword(_ keyword: String) {
        engine.watchedKeywords.removeAll {
            $0.caseInsensitiveCompare(keyword) == .orderedSame
        }
    }

    private var notificationStatusText: String {
        notificationService.authorizationDescription
    }

    private var notificationStatusColor: Color {
        switch notificationService.authorizationStatus {
        case .denied: return .orange
        case .authorized, .provisional, .ephemeral: return .secondary
        default: return Color.secondary.opacity(0.6)
        }
    }

    // MARK: - Speaker spotter

    /// Sidebar block for the Speaker Spotter feature: notify the user
    /// when a specific person (selected from voiceprint templates)
    /// starts speaking during a live session.
    ///
    /// **Layout**:
    ///   • search field (filters templates as you type)
    ///   • suggestions list (visible when search text is non-empty;
    ///     shows matching templates not yet in the spotted list)
    ///   • chips of currently-spotted speakers (× to remove)
    ///   • toggle: notify on hit (with auth status surfaced inline)
    ///
    /// **Selection-only semantics.** The search field never commits
    /// directly — only template names from the suggestions list can
    /// be added to `engine.spottedSpeakers`. Free-form text entry
    /// is intentionally not supported because spotting works by
    /// matching identified-segment names against template names;
    /// adding a name that has no template would silently never
    /// trigger.
    private var speakerSpotterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Speaker Spotter", isExpanded: $spotterExpanded)
            if spotterExpanded {

                Text("Notify when these speakers start speaking.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                // Search field. Filters the suggestions list below.
                // No Add button — entries can only come from the
                // suggestions list, which enforces template-name
                // validity.
                TextField("Search voice templates…", text: $speakerSearchDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                // Suggestions list. Visible when there's a search
                // query AND we have matches (or "no matches" message).
                // Hidden when the field is empty to keep the sidebar
                // compact.
                if !speakerSearchDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                    speakerSuggestionsList
                }

                // Selected speakers as chips. Same FlowLayout-based
                // chips used by the keyword watcher — visual
                // consistency between the two adjacent features.
                if !engine.spottedSpeakers.isEmpty {
                    KeywordChipFlow(
                        keywords: engine.spottedSpeakers,
                        onRemove: removeSpottedSpeaker
                    )
                }

                Divider()
                    .padding(.vertical, 2)

                // Notify toggle + auth status indicator. Wired the
                // same way as the keyword watcher's toggle: requesting
                // notification authorization on opt-in rather than at
                // first hit.
                Toggle(isOn: $engine.notifyOnSpeakerHit) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notify on hit")
                            .font(.system(size: 12))
                        Text(notificationStatusText)
                            .font(.system(size: 10))
                            .foregroundStyle(notificationStatusColor)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: engine.notifyOnSpeakerHit) { _, newValue in
                    guard newValue else { return }
                    Task {
                        await notificationService.refreshAuthorizationStatus()
                        if !notificationService.isAuthorized {
                            await notificationService.requestAuthorization()
                        }
                    }
                }

                if engine.notifyOnSpeakerHit && !notificationService.isAuthorized {
                    Text("Notifications won't be delivered. Enable StreamScribe in System Settings → Notifications.")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The filtered-templates suggestions list. Extracted so the main
    /// section body stays readable.
    ///
    /// **Filter logic.** Case-insensitive substring match against
    /// template names, with already-spotted templates excluded
    /// (don't suggest adding the same speaker twice). Sorted
    /// alphabetically — most useful for hearings where the user
    /// scans a familiar list of senator names.
    ///
    /// **Capped at 8 visible rows** to prevent the sidebar from
    /// growing unbounded with broad searches against a large
    /// template library. The list IS scrollable past 8, but the
    /// height cap keeps the other sections accessible.
    @ViewBuilder
    private var speakerSuggestionsList: some View {
        let matches = filteredSpeakerTemplates
        if matches.isEmpty {
            Text("No matching templates")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches, id: \.id) { template in
                        Button {
                            addSpottedSpeaker(template.name)
                        } label: {
                            HStack {
                                Text(template.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 180)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
        }
    }

    /// Templates matching the current search query, excluding any
    /// already in `engine.spottedSpeakers`, sorted alphabetically.
    /// Recomputed on every render — cost is O(templates) which is
    /// fine for the expected scale (dozens to low hundreds of
    /// templates).
    private var filteredSpeakerTemplates: [VoiceprintService.Voiceprint] {
        let query = speakerSearchDraft
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        let alreadySpotted = Set(engine.spottedSpeakers)
        return VoiceprintService.shared.templates
            .filter { template in
                !alreadySpotted.contains(template.name) &&
                (query.isEmpty || template.name.lowercased().contains(query))
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Add a speaker to the spotted list. Validates against the
    /// current template list (defense in depth — the UI should only
    /// surface valid names, but this guards against stale state if
    /// templates are reloaded mid-add).
    private func addSpottedSpeaker(_ name: String) {
        guard VoiceprintService.shared.templates.contains(where: { $0.name == name }) else { return }
        guard !engine.spottedSpeakers.contains(name) else { return }
        engine.spottedSpeakers.append(name)
        speakerSearchDraft = ""
    }

    private func removeSpottedSpeaker(_ name: String) {
        engine.spottedSpeakers.removeAll { $0 == name }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Tools", isExpanded: $toolsExpanded)
            if toolsExpanded {

            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                Text("ffmpeg")
                    .font(.system(size: 11, design: .monospaced))
                Spacer()
                Text(ffmpegStatusText)
                    .font(.system(size: 10))
                    .foregroundStyle(toolManager.ffmpegPath != nil ? Color.secondary : Color.red)
            }

            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                Text("yt-dlp")
                    .font(.system(size: 11, design: .monospaced))
                Spacer()
                Text(ytDlpStatusText)
                    .font(.system(size: 10))
                    .foregroundStyle(ytDlpStatusColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Inline progress bar while downloading
            if case .downloading(let p) = toolManager.ytDlpStatus {
                ProgressView(value: p)
                    .controlSize(.mini)
            }

            // Deno is required by yt-dlp for YouTube extraction (n-param JS
            // challenges). Auto-downloaded; user can manually update.
            HStack(spacing: 8) {
                Image(systemName: "curlybraces")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                Text("deno")
                    .font(.system(size: 11, design: .monospaced))
                Spacer()
                Text(denoStatusText)
                    .font(.system(size: 10))
                    .foregroundStyle(denoStatusColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Inline progress bar for Deno download/extraction. Reusing a
            // determinate ProgressView for the download phase and an indeterminate
            // one for the extract phase since extract has no meaningful progress
            // signal (it's a single unzip call that takes a couple seconds).
            switch toolManager.denoStatus {
            case .downloading(let p):
                ProgressView(value: p)
                    .controlSize(.mini)
            case .extracting:
                ProgressView()
                    .controlSize(.mini)
                    .progressViewStyle(.linear)
            default:
                EmptyView()
            }

            // Browser cookies picker. Some YouTube content (live streams, age-
            // gated videos, members-only) returns 403 without a real session
            // cookie, even when extraction succeeds. Picking a browser here
            // makes yt-dlp pass `--cookies-from-browser <name>`, which clears
            // those errors at the cost of a Keychain access prompt the first
            // time. Default is None — we don't want to surprise users who
            // never hit those errors with an unprompted permission dialog.
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                Text("Cookies")
                    .font(.system(size: 11))
                Spacer()
                Picker("Browser", selection: $toolManager.cookieBrowser) {
                    ForEach(CookieBrowser.allCases) { browser in
                        Text(browser.rawValue).tag(browser)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
                .fixedSize()
            }

            // Help text for the cookies picker. Only visible when a browser is
            // selected, to keep the sidebar tidy when this feature is off.
            if toolManager.cookieBrowser != .none {
                Text("yt-dlp will use \(toolManager.cookieBrowser.rawValue) cookies. macOS may prompt for Keychain access on first use.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Cookie-permission warning. Shown when keychain priming
            // surfaced a known issue — most commonly Safari needing
            // Full Disk Access (which is a TCC restriction, NOT a
            // Keychain issue, despite the picker's helper text). The
            // banner gives a one-click path to System Settings via
            // NSWorkspace, which is far more discoverable than asking
            // the user to navigate Privacy & Security menus manually.
            if let issue = toolManager.cookiePrimingIssue {
                cookieIssueBanner(for: issue)
            }

            // TLS-validation override. Corporate networks that intercept
            // HTTPS with a private root certificate can break yt-dlp's
            // SSL handshake even when the underlying connection is
            // legitimate. Passing `--no-check-certificate` tells yt-dlp
            // to skip verification. Off by default — weakening TLS is a
            // real security tradeoff, and we surface it as an explicit
            // opt-in rather than a hidden workaround.
            Toggle(isOn: $toolManager.disableTLSCheck) {
                Text("Skip TLS certificate check")
                    .font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            if toolManager.disableTLSCheck {
                Text("yt-dlp will pass --no-check-certificate. Only enable this if your corporate network does HTTPS interception and you can't add their root certificate to the system trust store.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // SSL_CERT_FILE override. Less drastic than the
            // skip-check toggle above — this lets the user point
            // yt-dlp at a custom CA bundle (e.g. their corporate
            // root) so TLS validation succeeds without being
            // disabled. The value is exported as `SSL_CERT_FILE` in
            // every yt-dlp child process's environment.
            //
            // Auto-detect tries `ProcessInfo` env first, then parses
            // `~/.zshrc` / `~/.bash_profile` for `export
            // SSL_CERT_FILE=`. The user-picked path takes precedence
            // when set.
            //
            // We use a file picker rather than a free-form text field
            // so the user can't fat-finger the path — the most common
            // reason "I pasted the path but it doesn't work" turns
            // out to be an invisible whitespace character or a path
            // pointing at a moved/renamed file. NSOpenPanel guarantees
            // we get back a real, currently-existing file.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.badge.gearshape")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                    Text("SSL cert file")
                        .font(.system(size: 11))
                    Spacer()
                    Button("Choose…") { chooseSSLCertFile() }
                        .controlSize(.small)
                    // Clear is only meaningful when the user has set
                    // an override. Hiding the button otherwise keeps
                    // the row compact when the field's at its default
                    // (auto-detect) state.
                    if !toolManager.customSSLCertFile.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button {
                            toolManager.customSSLCertFile = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear override (fall back to auto-detect)")
                    }
                }

                // Show the current effective path with its source.
                // Three cases:
                //   1. User override set → show the path + "Custom".
                //   2. Auto-detected → show the path + "Auto-detected".
                //   3. Neither → show a "No cert override; using system trust store".
                if let effective = toolManager.effectiveSSLCertFile {
                    let userOverride = !toolManager.customSSLCertFile.trimmingCharacters(in: .whitespaces).isEmpty
                    let badge = userOverride ? "Custom" : "Auto-detected"
                    HStack(spacing: 4) {
                        Text(badge)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.15))
                            )
                            .foregroundStyle(.secondary)
                        Text(effective)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(effective)
                    }
                } else {
                    Text("No custom cert; yt-dlp uses the system trust store.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            // Custom yt-dlp binary path. The bundled yt-dlp ships as a
            // PyInstaller bundle which ignores SSL_CERT_FILE entirely
            // (certifi is baked into the binary), so the only escape
            // hatch on corporate-TLS-interception networks is to point
            // StreamScribe at a different yt-dlp build whose Python
            // uses the system OpenSSL — typically `pip install yt-dlp`
            // or `brew install yt-dlp`.
            //
            // Empty = use bundled (default). Non-empty + executable =
            // use the picked binary for every yt-dlp invocation
            // (probe, download, live pipe, URL resolve). The bundled
            // binary stays on disk and remains updatable via the
            // button below in case the user wants to revert.
            VStack(alignment: .leading, spacing: 4) {
                // Suggestion banner. Shown when:
                //   - an externally-installed yt-dlp was detected at
                //     launch (Homebrew, pip, MacPorts location), AND
                //   - the user hasn't already set a custom path (so
                //     we're not nagging users who already chose), AND
                //   - the detected path is different from what's
                //     currently in the custom field (covers the case
                //     where the user already set it to the detected
                //     path).
                // One click writes the detected path into
                // `customYTDlpPath`, which our resolver picks up
                // automatically on the next yt-dlp invocation.
                if let detected = toolManager.detectedExternalYTDlpPath,
                   toolManager.customYTDlpPath.trimmingCharacters(in: .whitespaces).isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Found external yt-dlp")
                                .font(.system(size: 11, weight: .medium))
                            Text(detected)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(detected)
                        }
                        Spacer(minLength: 4)
                        Button("Use this") {
                            toolManager.customYTDlpPath = detected
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.08))
                    )
                }

                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                    Text("Custom yt-dlp")
                        .font(.system(size: 11))
                    Spacer()
                    Button("Choose…") { chooseCustomYTDlp() }
                        .controlSize(.small)
                    if !toolManager.customYTDlpPath.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button {
                            toolManager.customYTDlpPath = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear override (use bundled yt-dlp)")
                    }
                }

                // Show what's actually being used. Three states:
                //   1. Override set + valid → "Custom" badge + path.
                //   2. Override set + missing/non-executable → red
                //      warning ("falling back to bundled").
                //   3. No override → "Bundled".
                let trimmedOverride = toolManager.customYTDlpPath.trimmingCharacters(in: .whitespaces)
                if !trimmedOverride.isEmpty {
                    let validOverride = FileManager.default.isExecutableFile(atPath: trimmedOverride)
                    HStack(spacing: 4) {
                        Text(validOverride ? "Custom" : "Invalid")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(validOverride ? Color.secondary.opacity(0.15) : Color.red.opacity(0.2))
                            )
                            .foregroundStyle(validOverride ? Color.secondary : Color.red)
                        Text(trimmedOverride)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(validOverride ? Color.secondary : Color.red)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(trimmedOverride)
                    }
                    if !validOverride {
                        Text("Not executable — falling back to bundled yt-dlp.")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                } else {
                    Text("Using bundled yt-dlp.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Button("Update yt-dlp Now") {
                Task { await toolManager.updateYTDlpNow() }
            }
            .controlSize(.small)
            .disabled(updateButtonDisabled)

            Button("Update Deno Now") {
                Task { await toolManager.updateDenoNow() }
            }
            .controlSize(.small)
            .disabled(denoUpdateButtonDisabled)
            }
        }
    }

    private var ffmpegStatusText: String {
        toolManager.ffmpegPath != nil ? "Bundled" : "Missing"
    }

    /// Pick a CA bundle file via NSOpenPanel. Filtered to common cert
    /// extensions (.pem most common, plus .crt/.cer for users with
    /// converted files). The picker can also show hidden directories
    /// (`/etc/ssl/`, `~/Library/...`) which is where corporate certs
    /// sometimes live — without that the user would be stuck trying
    /// to type the path manually anyway.
    ///
    /// On selection, writes the path to `toolManager.customSSLCertFile`.
    /// `didSet` persists it to UserDefaults and any subsequent yt-dlp
    /// invocation reads it through `effectiveSSLCertFile`.
    private func chooseSSLCertFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose SSL Certificate File"
        panel.message = "Select a CA bundle (.pem) that yt-dlp should trust."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.allowedContentTypes = ["pem", "crt", "cer", "der"].compactMap {
            UTType(filenameExtension: $0)
        }
        // Allow showing files without a recognized type too — some
        // corporate bundles ship without an extension or with an
        // unusual one. The user's choice is final; we don't second-
        // guess based on extension.
        panel.allowsOtherFileTypes = true

        if panel.runModal() == .OK, let url = panel.url {
            toolManager.customSSLCertFile = url.path
        }
    }

    /// Pick a custom yt-dlp binary via NSOpenPanel. No extension
    /// filter — yt-dlp installs have no extension on macOS/Linux
    /// (`/opt/homebrew/bin/yt-dlp`, `~/Library/Python/3.x/bin/yt-dlp`).
    /// `showsHiddenFiles = true` so the user can reach
    /// `~/.local/bin/` and similar dotfile-adjacent paths.
    ///
    /// On selection writes the path to `toolManager.customYTDlpPath`.
    /// The picker doesn't validate the file is actually yt-dlp — we
    /// trust the user knows what they're picking, and the next
    /// invocation will surface any failure clearly anyway.
    private func chooseCustomYTDlp() {
        let panel = NSOpenPanel()
        panel.title = "Choose yt-dlp Binary"
        panel.message = "Select an alternative yt-dlp executable (e.g. installed via pip or brew)."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        // No type filter — yt-dlp installs are extension-less on
        // macOS/Linux. Pick anything; we verify executability after.
        panel.allowsOtherFileTypes = true

        if panel.runModal() == .OK, let url = panel.url {
            toolManager.customYTDlpPath = url.path
        }
    }

    private var ytDlpStatusText: String {
        // Show version if we have one + we're idle, otherwise show the live status label.
        if let v = toolManager.ytDlpVersion {
            switch toolManager.ytDlpStatus {
            case .ready, .unknown: return "v\(v)"
            default: return toolManager.ytDlpStatus.label
            }
        }
        return toolManager.ytDlpStatus.label
    }

    private var ytDlpStatusColor: Color {
        switch toolManager.ytDlpStatus {
        case .error: return .red
        case .checking, .downloading: return .yellow
        default: return .secondary
        }
    }

    private var updateButtonDisabled: Bool {
        if engine.state.isActive { return true }
        switch toolManager.ytDlpStatus {
        case .checking, .downloading: return true
        default: return false
        }
    }

    private var denoStatusText: String {
        if let v = toolManager.denoVersion {
            switch toolManager.denoStatus {
            case .ready, .unknown: return "v\(v)"
            default: return toolManager.denoStatus.label
            }
        }
        return toolManager.denoStatus.label
    }

    private var denoStatusColor: Color {
        switch toolManager.denoStatus {
        case .error: return .red
        case .checking, .downloading, .extracting: return .yellow
        default: return .secondary
        }
    }

    private var denoUpdateButtonDisabled: Bool {
        if engine.state.isActive { return true }
        switch toolManager.denoStatus {
        case .checking, .downloading, .extracting: return true
        default: return false
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Session", isExpanded: $statusExpanded)
            if statusExpanded {

            HStack {
                statusDot
                Text(engine.state.displayLabel)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if engine.elapsedSeconds > 0 {
                statRow(label: "Elapsed", value: formatDuration(engine.elapsedSeconds))
            }

            // Progress for static sources: show fraction + a thin progress bar.
            // For live streams progressFraction is nil so this whole block is hidden.
            if let progress = engine.progressFraction {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Progress")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        if let total = engine.totalDurationSeconds {
                            Text("of \(formatDuration(total))")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    ProgressView(value: progress)
                        .controlSize(.small)
                }
            }

            if engine.realtimeFactor > 0 {
                HStack {
                    Text("Speed")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.2f×", engine.realtimeFactor))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(realtimeFactorColor)
                    Text("realtime")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            if !engine.segments.isEmpty {
                statRow(label: "Segments", value: "\(engine.segments.count)")
                let speakers = Set(engine.segments.compactMap { $0.speaker })
                if !speakers.isEmpty {
                    statRow(label: "Speakers", value: "\(speakers.count)")
                }
            }
            if let lang = engine.detectedLanguage {
                statRow(label: "Language", value: lang.uppercased())
            }
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            if engine.state.isActive {
                primaryButton(action: onStop, label: "Stop",
                              systemImage: "stop.fill", tint: .red)
                    // Disable Stop while finalizing — the user already
                    // clicked it; we're waiting on in-flight refinement.
                    // Button stays visible (the .disabled treatment is
                    // a visual grey-out, not a removal) so the user can
                    // see the state hasn't been ignored.
                    .disabled(engine.state.isFinalizing)
            } else {
                primaryButton(action: onStart, label: "Start",
                              systemImage: "play.fill", tint: nil)
                    .disabled(urlInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Button(action: onExport) {
                Image(systemName: "square.and.arrow.up")
            }
            .controlSize(.large)
            .help("Export transcript (⌘E)")
            .disabled(engine.segments.isEmpty)
        }
        .padding(16)
    }

    /// Primary action button used for Start and Stop. Stays readable when the
    /// host window loses focus by switching from `.borderedProminent` (system
    /// inactive treatment fades these to near-invisible) to `.bordered` (a
    /// stable neutral grey that remains legible). The focused state keeps
    /// the prominent tint so the primary action still pops when the user is
    /// in the window.
    ///
    /// `@ViewBuilder` instead of returning a generic `some View` because
    /// `.buttonStyle(.borderedProminent)` and `.buttonStyle(.bordered)` are
    /// different concrete types and SwiftUI's opaque return types can't
    /// unify them across an if/else.
    @ViewBuilder
    private func primaryButton(action: @escaping () -> Void,
                               label: String,
                               systemImage: String,
                               tint: Color?) -> some View {
        if controlActiveState == .key || controlActiveState == .active {
            Button(action: action) {
                Label(label, systemImage: systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint ?? .accentColor)
            .controlSize(.large)
        } else {
            Button(action: action) {
                Label(label, systemImage: systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    // MARK: - Bits

    /// Section header row: small-caps title with a chevron that rotates
    /// 90° between expanded (▾, pointing down) and collapsed (▸,
    /// pointing right). Tapping anywhere on the row toggles the
    /// binding. The whole row is `contentShape(Rectangle())` so the
    /// hit-target is the full width of the sidebar, not just the text.
    ///
    /// Plain-button style + no accessory background: the chevron is
    /// the only visual change a user should notice. Section content
    /// (rendered below the header in each section's `VStack`) is
    /// gated on the binding and animates in/out via the standard
    /// SwiftUI `withAnimation` block surrounding the toggle.
    private func sectionHeader(_ title: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Render an actionable banner for a cookie-priming failure. Each
    /// case maps to specific guidance and (for the cases where it
    /// makes sense) a button that resolves the issue in one click.
    ///
    /// The Safari/Full-Disk-Access case is the high-value one — without
    /// this banner, a user picking Safari just gets silence and a
    /// later YouTube probe failure with no obvious link to "you need
    /// to grant Full Disk Access in System Settings." With the banner
    /// + button, it's a guided fix.
    ///
    /// Visual style: subtle, non-alarming. The cookie picker isn't a
    /// critical-path setting (most users transcribe public content
    /// without cookies), so a heavy red error block would be
    /// disproportionate. Orange exclamation icon + tertiary text +
    /// inline link button matches the rest of the sidebar's helper-
    /// text vocabulary.
    @ViewBuilder
    private func cookieIssueBanner(for issue: ToolManager.CookiePrimingIssue) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .frame(width: 16, alignment: .top)
            VStack(alignment: .leading, spacing: 4) {
                switch issue {
                case .safariNeedsFullDiskAccess:
                    Text("Safari cookies need Full Disk Access. Grant it in System Settings, then re-select Safari.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        // Deep link to Full Disk Access in System Settings.
                        // The "Privacy_AllFiles" anchor is the canonical
                        // identifier for the Full Disk Access pane and has
                        // been stable across macOS Ventura/Sonoma/Sequoia.
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 9))
                            Text("Open System Settings")
                                .font(.system(size: 10))
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                case .keychainDenied(let browser):
                    Text("Keychain access denied for \(browser) cookies. Re-grant in Keychain Access.app, or pick a different browser.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .ytdlpUnavailable(let path):
                    Text("Couldn't run yt-dlp at \(path). Check the Tools section for a custom binary path.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .generic(let stderr):
                    Text("Cookie access failed: \(stderr.isEmpty ? "unknown error" : stderr)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Compact "status + Download button" row for a single ML model. Sits
    /// directly under each model picker (Whisper, Parakeet, Sortformer,
    /// SpeakerKit) so the indicator is visually tied to the model the user
    /// is choosing. Visual conventions mirror `toolsSection`'s yt-dlp and
    /// Deno rows so the sidebar reads as one consistent pattern: small icon,
    /// short label, colored status text on the right, optional inline
    /// `ProgressView` below.
    ///
    /// `key` identifies which model's status to read. `downloadAction` is
    /// the closure to run when the user taps Download — different per model
    /// because each backend has its own `downloadXModel` entry point on the
    /// manager. We pass it as a closure rather than deriving it from `key`
    /// here so the call sites are explicit about which backend they're
    /// triggering — easier to grep, and keeps this view dumb.
    ///
    /// Button is disabled both during an active session (model can't change
    /// mid-run) and while a download is already in flight (avoid double-
    /// start; the manager's `runDownload` also guards this defensively).
    @ViewBuilder
    private func modelStatusRow(
        key: ModelDownloadManager.ModelKey,
        downloadAction: @escaping () -> Void
    ) -> some View {
        let status = modelDownloadManager.status(key)
        // Hide the row entirely when the model is cached or we haven't probed
        // yet. The user's request was explicit: "download buttons should be
        // hidden when models are detected automatically." Showing a row with
        // "Downloaded" and no button reads as static noise; absence is the
        // clearer signal that the model is ready and nothing needs to happen.
        // The `.unknown` skip avoids a "Not downloaded" flash on launch
        // before `refreshAllOnDiskStatuses` completes.
        switch status {
        case .unknown, .cached:
            EmptyView()
        default:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: modelStatusIcon(status))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                    Text(status.label)
                        .font(.system(size: 10))
                        .foregroundStyle(modelStatusColor(status))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    // Download button shown for the two states where it's
                    // actionable: explicit "not downloaded" and "error" (a
                    // retry, semantically). Hidden during `.downloading`
                    // and `.loading` (in flight) and `.ready` (already
                    // loaded this session).
                    if showsDownloadButton(status) {
                        Button("Download") { downloadAction() }
                            .controlSize(.small)
                            .disabled(engine.state.isActive)
                    }
                }

                // Progress visualization. Linear bar in both cases; the
                // difference is determinate vs indeterminate:
                //   - `.downloading` with a known fraction → determinate
                //     `ProgressView(value:)`. R2 mirror downloads
                //     surface a real percentage via
                //     `URLSessionDownloadDelegate`; FluidAudio surfaces
                //     an approximate one via disk polling. Both update
                //     several times a second so the bar moves visibly.
                //   - `.downloading` with no fraction → indeterminate
                //     barberpole. Hit when the delegate hasn't fired
                //     the first chunk yet (first few hundred ms of
                //     download), or when the HuggingFace fallback path
                //     runs (no per-byte visibility into the library's
                //     own loader).
                //   - `.loading` → indeterminate. Tensor deserialization
                //     happens inside MLX/CoreML with no progress
                //     callback we can subscribe to. 5-15 seconds for a
                //     2 GB Parakeet on Apple Silicon; the elapsed-time
                //     label makes it clear the process is alive.
                switch status {
                case .downloading(_, let progress):
                    if let progress {
                        ProgressView(value: max(0.0, min(1.0, progress)))
                            .progressViewStyle(.linear)
                            .controlSize(.mini)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .controlSize(.mini)
                    }
                case .loading:
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                default:
                    EmptyView()
                }
            }
        }
    }

    /// SF Symbol name for a model status. Picks an icon that matches the
    /// state semantics: arrow-down for "needs fetching," gear for
    /// "loading into memory," exclamation for error, etc. The icon
    /// column gives the row a fixed left margin that aligns with the
    /// other tool/status rows in the sidebar.
    private func modelStatusIcon(_ status: ModelDownloadManager.ModelStatus) -> String {
        switch status {
        case .unknown:        return "questionmark.circle"
        case .cached:         return "checkmark.circle"
        case .notDownloaded:  return "arrow.down.circle"
        case .downloading:    return "arrow.down.circle.dotted"
        case .loading:        return "gearshape.2"
        case .ready:          return "checkmark.seal"
        case .error:          return "exclamationmark.triangle"
        }
    }

    /// Matches the color conventions used by `ytDlpStatusColor` /
    /// `denoStatusColor` so all status text in the sidebar reads as part of
    /// one system: yellow for "in flight," red for error, secondary gray
    /// for everything else.
    private func modelStatusColor(_ status: ModelDownloadManager.ModelStatus) -> Color {
        switch status {
        case .error:                   return .red
        case .downloading, .loading:   return .yellow
        default:                       return .secondary
        }
    }

    /// Whether the Download button should appear for the given status. Shown
    /// only when the user can actionably trigger a download: weights aren't
    /// on disk (`.notDownloaded`) or the last attempt failed (`.error`,
    /// which doubles as the retry path). Hidden during `.downloading` and
    /// `.loading` since the work is already happening.
    private func showsDownloadButton(_ status: ModelDownloadManager.ModelStatus) -> Bool {
        switch status {
        case .notDownloaded, .error: return true
        default:                     return false
        }
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .overlay(
                Circle().stroke(statusColor.opacity(0.3), lineWidth: 4)
                    .scaleEffect(engine.state == .streaming ? 1.6 : 1)
                    .opacity(engine.state == .streaming ? 0 : 1)
                    .animation(
                        engine.state == .streaming
                            ? .easeOut(duration: 1.2).repeatForever(autoreverses: false)
                            : .default,
                        value: engine.state
                    )
            )
    }

    private var statusColor: Color {
        switch engine.state {
        case .idle: return .gray
        case .preparing: return .yellow
        case .streaming: return .green
        case .finishing: return .blue
        // Finalizing is a teardown sibling of `.finishing` — same blue
        // status indicator. Both mean "wrapping up, don't quit yet."
        case .finalizing: return .blue
        case .error: return .red
        }
    }

    /// Color the realtime factor: red < 0.8× (falling behind), yellow 0.8–1.2× (borderline),
    /// green ≥ 1.2× (comfortable margin). Useful when comparing engines under load.
    private var realtimeFactorColor: Color {
        let r = engine.realtimeFactor
        if r < 0.8 { return .red }
        if r < 1.2 { return .yellow }
        return .green
    }

    /// Detect source from current input on the fly. `engine.detectedSource` is only
    /// updated on Start, but we want the label/icon to react as the user types or picks.
    private var liveDetectedSource: StreamSource {
        let trimmed = urlInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .unknown }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return .localFile
        }
        if let url = URL(string: trimmed), url.scheme != nil {
            return StreamSource.detect(from: url)
        }
        return .unknown
    }

    private var sourceLabel: String {
        let s = liveDetectedSource
        // For local files, surface the basename so the user sees what they picked.
        if s == .localFile && !urlInput.isEmpty {
            let path = urlInput.hasPrefix("file://")
                ? URL(string: urlInput)?.path ?? urlInput
                : urlInput
            return (path as NSString).lastPathComponent
        }
        return s == .unknown && !urlInput.isEmpty
            ? "URL will be auto-detected"
            : s.rawValue
    }

    private var sourceIcon: String {
        switch liveDetectedSource {
        case .youtube:      return "play.rectangle"
        case .twitter:      return "bubble.left.and.bubble.right.fill"
        case .facebook:     return "person.2.fill"
        case .instagram:    return "camera.fill"
        case .threads:      return "at"
        case .applePodcast: return "mic.fill"
        case .soundcloud:   return "waveform.circle.fill"
        case .senateGov:    return "building.columns.fill"
        case .criticalMention: return "eye.fill"
        case .granicus:     return "building.2.fill"
        case .hls:          return "antenna.radiowaves.left.and.right"
        case .directAudio:  return "waveform"
        case .localFile:    return "doc.fill"
        case .unknown:      return "questionmark.circle"
        }
    }

    /// Whisper models shown in the picker — essentials by default,
    /// the full list when `showAllModels` is on. Always includes the
    /// currently-selected model even if not in the visible set, so
    /// the picker can render its own selection (a Picker can't show
    /// a selection that's not in its ForEach data).
    private var visibleWhisperModels: [String] {
        let base = showAllModels
            ? TranscriptionEngine.availableWhisperModels
            : TranscriptionEngine.essentialWhisperModels
        if base.contains(engine.whisperModelName) {
            return base
        }
        // Current selection is outside the visible set — append it so
        // the Picker renders correctly. Happens if a user switches off
        // Show All while having a non-essential model selected.
        return base + [engine.whisperModelName]
    }

    /// Parakeet models shown in the picker. Same essential-vs-all
    /// pattern as Whisper, with the same current-selection safety net.
    private var visibleParakeetModels: [String] {
        let base = showAllModels
            ? TranscriptionEngine.availableParakeetModels
            : TranscriptionEngine.essentialParakeetModels
        if base.contains(engine.parakeetModelName) {
            return base
        }
        return base + [engine.parakeetModelName]
    }

    private func whisperDisplayName(_ raw: String) -> String {
        switch raw {
        case "openai_whisper-tiny.en":                          return "Tiny (English) — 39 MB"
        case "openai_whisper-base.en":                          return "Base (English) — 74 MB"
        case "openai_whisper-small.en":                         return "Small (English) — 244 MB"
        case "openai_whisper-medium.en":                        return "Medium (English) — 769 MB ⚡ — Fastest"
        case "openai_whisper-large-v3":                         return "Large v3 — 1.5 GB"
        case "openai_whisper-large-v3-v20240930":               return "Large v3 (Sep 2024) — 1.5 GB"
        case "openai_whisper-large-v3-v20240930_turbo":         return "Large v3 Turbo — 1.5 GB — Most accurate"
        case "openai_whisper-large-v3-v20240930_turbo_632MB":   return "Large v3 Turbo (4-bit) — 632 MB — Balanced (recommended)"
        default:
            return raw.replacingOccurrences(of: "openai_whisper-", with: "")
        }
    }

    private func parakeetDisplayName(_ raw: String) -> String {
        // Strip the org prefix and decorate with rough size hints
        let short = raw.replacingOccurrences(of: "mlx-community/", with: "")
        switch raw {
        case "mlx-community/parakeet-tdt_ctc-1.1b":    return "TDT-CTC 1.1B — Native PnC (recommended)"
        case "mlx-community/parakeet-tdt-0.6b-v3":     return "TDT 0.6B v3 — Smaller, requires PnC restoration"
        case "mlx-community/parakeet-tdt-0.6b-v2":     return "TDT 0.6B v2"
        case "mlx-community/parakeet-tdt-1.1b":        return "TDT 1.1B — No PnC, slightly faster"
        case "mlx-community/parakeet-tdt_ctc-110m":    return "TDT-CTC 110M (fastest)"
        case "mlx-community/parakeet-ctc-0.6b":        return "CTC 0.6B"
        case "mlx-community/parakeet-ctc-1.1b":        return "CTC 1.1B"
        case "mlx-community/parakeet-rnnt-0.6b":       return "RNN-T 0.6B"
        case "mlx-community/parakeet-rnnt-1.1b":       return "RNN-T 1.1B"
        default: return short
        }
    }

    private func diarizationShortName(_ kind: DiarizationEngineKind) -> String {
        switch kind {
        case .off:        return "Off"
        case .speakerKit: return "SpeakerKit"
        case .sortformer: return "Sortformer (MLX)"
        case .fluidAudio: return "FluidAudio"
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Keyword chip flow

/// A simple wrapping row of removable keyword chips. Uses the SwiftUI `Layout`
/// protocol (macOS 13+) to flow chips left-to-right and wrap to a new line when
/// they overrun the available width.
///
/// The "× to remove" affordance is per-chip and lives in the chip itself rather
/// than in a separate edit mode — keyword lists are typically small (a few words)
/// and the user already has one click for add, so making remove a single click
/// keeps symmetry.
private struct KeywordChipFlow: View {
    let keywords: [String]
    let onRemove: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(keywords, id: \.self) { kw in
                KeywordChip(text: kw, onRemove: { onRemove(kw) })
            }
        }
    }
}

private struct KeywordChip: View {
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove keyword")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.accentColor.opacity(0.18))
        )
        .overlay(
            Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 0.5)
        )
        .foregroundStyle(Color.accentColor)
    }
}

/// Minimal flow layout: place subviews left-to-right with `spacing` gaps, wrap
/// when they exceed the proposed width. We keep this self-contained rather than
/// pulling in a layout package — chip lists are the only place we need it.
///
/// Sizing model:
///   • sizeThatFits returns the bounding box that the laid-out chips would fill,
///     given a finite width. Heights stack by row.
///   • placeSubviews mirrors that traversal but issues actual placements.
///
/// Caveat: assumes left-aligned, top-aligned. No vertical centering across rows
/// of mixed-height items — fine for chips which are uniform height.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Width available for layout. nil width means "as much as you want" (e.g. in
        // a horizontal scroll view) — fall back to a reasonable default.
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            // If this subview won't fit on the current row, wrap to a new row.
            // Note `> maxWidth` not `>=` so a single subview wider than maxWidth
            // still places (and gets clipped/overflowed by parent) rather than
            // looping forever.
            if rowWidth + (rowWidth > 0 ? spacing : 0) + size.width > maxWidth, rowWidth > 0 {
                widestRow = max(widestRow, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                if rowWidth > 0 { rowWidth += spacing }
                rowWidth += size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        widestRow = max(widestRow, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: widestRow, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            // Wrap to new row if this chip would overflow.
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
