import SwiftUI

/// First-time-setup welcome sheet. Shown on launch when the user hasn't
/// yet completed setup (tracked via the `hasCompletedFirstTimeSetup`
/// AppStorage flag). Existing users with `cookieBrowser` already
/// configured get the flag backfilled at launch and never see this
/// sheet — see the `.task` in StreamScribeApp.
///
/// **Scope.** Currently focuses on the one decision new users actually
/// have to make: cookie browser selection. Other onboarding-relevant
/// settings are now sensible defaults (TLS check skip defaults ON for
/// corporate networks, tools auto-update on launch). If future settings
/// need explicit user input on first launch, add more sections here
/// rather than spawning multiple sheets.
///
/// **Sizing.** Fixed 480 × 580 to fit the header + cookies card + button
/// row at standard system font size without scrolling. Adjust both
/// dimensions if content grows.
struct WelcomeView: View {
    @EnvironmentObject private var toolManager: ToolManager

    /// `NotificationService` is injected so the Notifications card's
    /// toggle can call `requestAuthorization()` on Continue. Same
    /// singleton instance the rest of the app uses; sees status
    /// changes immediately via the @Published `isAuthorized` flag.
    @EnvironmentObject private var notificationService: NotificationService

    /// Whether to request system notification permission when the user
    /// clicks Continue. Default ON because most users benefit from
    /// keyword-hit alerts during long live transcriptions (otherwise
    /// they have to keep the app window visible to know when a
    /// flagged term appeared). Users on metered or quiet-mode
    /// preferences can flip it off here. Idempotent — clicking with
    /// authorization already granted does nothing.
    @State private var enableNotificationsOnContinue: Bool = true
    @Environment(\.dismiss) private var dismiss

    @AppStorage("hasCompletedFirstTimeSetup")
    private var hasCompletedFirstTimeSetup: Bool = false

    /// Browser selection within the welcome flow. Defaults to Chrome
    /// because it works on the broadest mix of macOS versions and
    /// network configurations, and the Keychain-backed cookie store is
    /// the most reliable across the supported browsers (Safari uses
    /// TCC, which requires per-app full-disk access; Firefox stores
    /// cookies unencrypted which is fine but less standard). The Picker
    /// also offers a "skip" option for users who already have other
    /// auth flows worked out and don't want to grant cookie access.
    @State private var selectedBrowser: CookieBrowser = .chrome

    /// Whether to kick off downloads of the recommended models when the
    /// user clicks Continue. Default ON because:
    ///   - These are the default engines (Parakeet TDT-CTC 1.1B for
    ///     transcription, FluidAudio for diarization); without them,
    ///     the first session blocks on a multi-minute download
    ///   - The download runs in the background — sheet dismisses
    ///     immediately, user sees progress in the sidebar
    ///   - Users on metered or corporate networks who don't want this
    ///     can flip it off here, or skip the welcome flow entirely
    ///
    /// Skipped automatically if the models are already on disk (e.g.
    /// the user reset the welcome sheet via the Debug menu after
    /// downloading earlier). Same idempotency guarantee that
    /// `downloadXModel` calls have themselves.
    @State private var downloadModelsOnContinue: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // Everything above the action row scrolls. FIELD FAILURE
            // (2026-07): the sheet was a fixed 480x960 frame — taller
            // than the usable height of smaller displays (13" MacBook
            // ≈ 870pt visible). macOS sheets clip rather than scroll,
            // so the Continue/Skip row was pushed off-screen with no
            // way to reach it — the welcome flow was undismissable on
            // those machines (Esc technically worked via the
            // presentation binding, but nothing communicated that).
            // Fix: the informational content scrolls, the action row
            // is pinned OUTSIDE the scroll area so it is always
            // visible, and the sheet height caps to the current
            // screen (see `sheetHeight`).
            ScrollView {
                scrollableContent
            }

            Divider()

            // Action row. Continue is the default action (Return key);
            // Skip lets users opt out of the cookies prompt entirely.
            // Both flip hasCompletedFirstTimeSetup so the sheet doesn't
            // re-show next launch. Pinned below the ScrollView — never
            // clipped regardless of display size.
            HStack {
                Button("Skip for Now") {
                    completeSetup(
                        applyingBrowser: false,
                        applyingDownloads: false,
                        applyingNotifications: false
                    )
                }
                .controlSize(.large)

                Spacer()

                Button("Continue") {
                    completeSetup(
                        applyingBrowser: true,
                        applyingDownloads: downloadModelsOnContinue,
                        applyingNotifications: enableNotificationsOnContinue
                    )
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 480, height: Self.sheetHeight)
    }

    /// Sheet height adapted to the screen the app is on. 960pt is the
    /// design-ideal height (all cards visible without scrolling); on
    /// displays whose visible frame can't fit that, the sheet shrinks
    /// to fit (minus 120pt of margin for the host window's title bar
    /// and breathing room) and the content scrolls instead. Floored at
    /// 420pt so a pathological screen value can't collapse the sheet
    /// below the header + one card + action row. `NSScreen.main` is
    /// the screen with keyboard focus — correct for a first-launch
    /// sheet attached to the key window.
    private static var sheetHeight: CGFloat {
        let ideal: CGFloat = 960
        let minimum: CGFloat = 420
        guard let visible = NSScreen.main?.visibleFrame.height else { return ideal }
        return max(minimum, min(ideal, visible - 120))
    }

    /// The informational content of the welcome flow — everything
    /// except the pinned Skip/Continue action row. Lives in a
    /// ScrollView in `body`, so it may be any height.
    private var scrollableContent: some View {
        VStack(spacing: 0) {
            // Header — branding + welcome line.
            VStack(spacing: 14) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                Text("Welcome to StreamScribe")
                    .font(.title)
                    .fontWeight(.semibold)
                Text("Let's get you set up to transcribe online video and audio.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 32)
            .padding(.bottom, 24)

            Divider()

            // Cookies setup card. The one decision the user actually has
            // to make in this flow — the rest of setup is automatic
            // (tools auto-update, TLS skip defaults on).
            VStack(alignment: .leading, spacing: 14) {
                Label("Browser Cookies", systemImage: "lock.shield.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text("Some videos require a login — private uploads, paid content, age-gated material. StreamScribe can use your browser's cookies to authenticate without you re-logging in. Pick which browser:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Browser", selection: $selectedBrowser) {
                    Text("Chrome (recommended)").tag(CookieBrowser.chrome)
                    Text("Safari").tag(CookieBrowser.safari)
                    Text("Firefox").tag(CookieBrowser.firefox)
                    Text("Skip — set up later").tag(CookieBrowser.none)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)

                // Keychain prompt warning. Shown for browsers that
                // trigger a Keychain prompt (Chrome family); hidden for
                // Safari/Firefox/None where the prompt mechanism differs
                // or doesn't apply.
                if selectedBrowser == .chrome {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Click **Always Allow** on the Keychain prompt")
                                .font(.caption)
                                .fontWeight(.medium)
                            Text("macOS will ask whether StreamScribe can read Chrome's stored cookies. Choosing Always Allow means it won't ask again on every video.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(6)
                }
            }
            .padding(20)
            .background(Color.gray.opacity(0.06))
            .cornerRadius(10)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 8)

            // Models setup card. Mirrors the cookies card visually
            // (rounded gray panel, header label, description, control)
            // so the welcome flow feels like a single coherent
            // checklist. Differs in mechanics: clicking Continue with
            // this toggle on fires background downloads of the default
            // engines — no system prompt, no per-model decision, no
            // blocking wait. Progress is visible in the main sidebar
            // after the sheet dismisses.
            VStack(alignment: .leading, spacing: 14) {
                Label("Models", systemImage: "cube.box.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text("StreamScribe needs a transcription model and a speaker diarization model. The recommended defaults are downloaded once and reused across sessions:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Bulleted list of what gets fetched. Each row has the
                // model name + the size + a one-line "what it does"
                // so users on metered connections can make an
                // informed decision about whether to defer the download.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Parakeet TDT-CTC 1.1B").font(.callout).fontWeight(.medium)
                            Text("Speech-to-text with native punctuation. ~2 GB.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("FluidAudio").font(.callout).fontWeight(.medium)
                            Text("Identifies different speakers. ~250 MB.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 4)

                Toggle("Download now (recommended)", isOn: $downloadModelsOnContinue)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }
            .padding(20)
            .background(Color.gray.opacity(0.06))
            .cornerRadius(10)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            // Notifications card. Mirrors the cookies/models cards
            // visually so the welcome flow reads as a unified
            // checklist. Permission is opt-in here rather than at
            // first-keyword-hit because asking later (mid-session,
            // when the user might be busy following along) hits a
            // worse moment — they'd see the system prompt, lose
            // focus on the transcript, and possibly miss the very
            // event the notification was about. Asking up-front
            // sidesteps that.
            VStack(alignment: .leading, spacing: 14) {
                Label("Notifications", systemImage: "bell.badge.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text("StreamScribe can send a system notification when a flagged keyword appears in the transcript — useful for long live sessions where you don't want to keep the window in focus the whole time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Enable notifications", isOn: $enableNotificationsOnContinue)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }
            .padding(20)
            .background(Color.gray.opacity(0.06))
            .cornerRadius(10)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            // "Change later" note — sets expectations that this isn't
            // a one-shot decision, lowering the stakes of clicking
            // Continue with whatever browser they have handy.
            Text("You can change this anytime in Settings → Tools.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                // Replaces the Spacer(minLength: 16) that sat here when
                // this content lived directly in `body` — Spacers are
                // inert inside a ScrollView (unbounded height), so plain
                // bottom padding provides the gap instead.
                .padding(.bottom, 20)
        }
    }

    /// Mark setup as complete, optionally apply the picked browser,
    /// optionally kick off model downloads, and optionally request
    /// system notification permission.
    ///
    /// Setting `cookieBrowser` triggers the existing `didSet` in
    /// ToolManager which primes Keychain/TCC/Firefox-cookie access
    /// asynchronously — that's where the user sees the "Always Allow"
    /// prompt for Chrome. We dismiss the sheet immediately rather than
    /// waiting for the prime to complete; the prompt appears over the
    /// main app window which is the right UX (the prompt is a system
    /// modal, not part of our flow).
    ///
    /// Model downloads, when `applyingDownloads` is true, run in
    /// parallel `Task`s on the singleton ModelDownloadManager. The
    /// downloads are independent — Parakeet doesn't depend on
    /// FluidAudio or vice versa — so concurrent fetches halve the
    /// wall-clock wait. Progress appears in the sidebar as soon as
    /// the user dismisses this sheet; no blocking, no completion
    /// callback needed at this layer.
    ///
    /// Notification authorization, when `applyingNotifications` is
    /// true, fires a Task that calls `NotificationService.shared.
    /// requestAuthorization()` — which surfaces the macOS system
    /// permission prompt. The prompt appears over the main app
    /// window after the sheet dismisses; identical UX to how Chrome
    /// cookie access works. The function is idempotent: if the user
    /// already authorized previously (the welcome flow can re-show
    /// via the Debug menu), the call no-ops without re-prompting.
    private func completeSetup(applyingBrowser: Bool, applyingDownloads: Bool, applyingNotifications: Bool) {
        if applyingBrowser && selectedBrowser != .none {
            toolManager.cookieBrowser = selectedBrowser
        }
        if applyingDownloads {
            // Spawn one Task per model. ModelDownloadManager guards
            // against double-downloads internally, so even if the user
            // somehow re-triggered the welcome flow with downloads
            // already in flight, the second call would no-op cleanly.
            //
            // Parakeet model identifier comes from
            // TranscriptionEngine.defaultParakeetModel — sourcing from
            // there ensures this welcome card always points at whatever
            // we've currently shipped as the default (today
            // TDT-CTC 1.1B), without WelcomeView holding its own
            // hardcoded copy of the repo name that could drift.
            Task {
                await ModelDownloadManager.shared.downloadParakeetModel(
                    repo: TranscriptionEngine.defaultParakeetModel
                )
            }
            Task {
                await ModelDownloadManager.shared.downloadFluidAudioModel()
            }
        }
        if applyingNotifications {
            // Fire-and-forget the auth request. The system prompt
            // appears over the main app window after the sheet
            // dismisses. We refresh status first in case auth was
            // already granted in a previous run (welcome flow can
            // re-show via Debug menu); the refresh + skip pattern
            // mirrors what SidebarView does on its own auth toggle.
            Task {
                await notificationService.refreshAuthorizationStatus()
                if !notificationService.isAuthorized {
                    await notificationService.requestAuthorization()
                }
            }
        }
        hasCompletedFirstTimeSetup = true
        dismiss()
    }
}

#Preview {
    WelcomeView()
        .environmentObject(ToolManager.shared)
}
