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

    var body: some View {
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
            .padding(.bottom, 16)

            // "Change later" note — sets expectations that this isn't
            // a one-shot decision, lowering the stakes of clicking
            // Continue with whatever browser they have handy.
            Text("You can change this anytime in Settings → Tools.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            Spacer(minLength: 16)

            Divider()

            // Action row. Continue is the default action (Return key);
            // Skip lets users opt out of the cookies prompt entirely.
            // Both flip hasCompletedFirstTimeSetup so the sheet doesn't
            // re-show next launch.
            HStack {
                Button("Skip for Now") {
                    completeSetup(applyingBrowser: false)
                }
                .controlSize(.large)

                Spacer()

                Button("Continue") {
                    completeSetup(applyingBrowser: true)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 480, height: 580)
    }

    /// Mark setup as complete and optionally apply the picked browser.
    /// Setting `cookieBrowser` triggers the existing `didSet` in
    /// ToolManager which primes Keychain/TCC/Firefox-cookie access
    /// asynchronously — that's where the user sees the "Always Allow"
    /// prompt for Chrome. We dismiss the sheet immediately rather than
    /// waiting for the prime to complete; the prompt appears over the
    /// main app window which is the right UX (the prompt is a system
    /// modal, not part of our flow).
    private func completeSetup(applyingBrowser: Bool) {
        if applyingBrowser && selectedBrowser != .none {
            toolManager.cookieBrowser = selectedBrowser
        }
        hasCompletedFirstTimeSetup = true
        dismiss()
    }
}

#Preview {
    WelcomeView()
        .environmentObject(ToolManager.shared)
}
