import Foundation
import Combine
import CryptoKit
import Security

/// Locates and manages the external CLI tools the app shells out to.
///
/// **ffmpeg** is bundled in the app bundle's Resources. We look it up at
/// `Bundle.main.url(forResource: "ffmpeg", ...)`. If missing, we surface a clear error
/// rather than silently falling back to PATH (except in dev where a Homebrew ffmpeg is
/// allowed as a fallback).
///
/// **yt-dlp** is auto-downloaded to `~/Library/Application Support/StreamScribe/yt-dlp`
/// on first use, and refreshed in the background whenever a newer GitHub release is
/// available. yt-dlp ships every few weeks specifically to track YouTube's signature
/// changes, so a bundled yt-dlp would go stale within weeks.
///
/// Isolation note: this class is *not* `@MainActor`. The published-state writes hop to
/// MainActor explicitly. Network downloads happen off the main actor so the UI stays
/// responsive while a 30 MB binary streams in.
final class ToolManager: ObservableObject {

    static let shared = ToolManager()

    // MARK: - Published status

    @Published private(set) var ytDlpVersion: String?       // e.g. "2025.10.31"
    @Published private(set) var ytDlpStatus: YTDlpStatus = .unknown
    @Published private(set) var lastUpdateCheck: Date?

    /// Deno is required by yt-dlp ≥ late-2025 to solve YouTube's n-parameter JavaScript
    /// challenges. Without it, YouTube extraction degrades to "No video formats found"
    /// errors on live streams and many regular videos. We auto-download it on first
    /// need, mirroring the yt-dlp pattern but with separate state because its release
    /// cadence is much slower (so background refresh on every launch is overkill).
    @Published private(set) var denoVersion: String?         // e.g. "2.5.4"
    @Published private(set) var denoStatus: DenoStatus = .unknown

    /// Last cookie-priming failure, or nil if priming hasn't run yet or
    /// the most recent run succeeded. Set on the main actor from inside
    /// `runKeychainPrimer`'s caller wrapper. The SidebarView observes
    /// this to render a warning banner below the cookie picker when
    /// permissions need to be granted (most commonly: Safari needs
    /// Full Disk Access).
    ///
    /// The struct shape — rather than just a String — lets the UI
    /// distinguish recoverable cases (Safari/TCC: open System Settings)
    /// from generic failures (yt-dlp missing, network down, etc.)
    /// without parsing strings in the view layer.
    @Published private(set) var cookiePrimingIssue: CookiePrimingIssue?

    enum CookiePrimingIssue: Equatable {
        /// Safari cookies couldn't be read because StreamScribe lacks
        /// Full Disk Access. Resolution: System Settings → Privacy &
        /// Security → Full Disk Access → enable StreamScribe.
        case safariNeedsFullDiskAccess
        /// User clicked Deny on the Keychain prompt for a Chromium-
        /// family browser. Cookies will fail until they re-grant via
        /// Keychain Access.app, or switch to a different browser.
        /// The associated string is a display name (e.g. "Chrome")
        /// for the banner copy.
        case keychainDenied(browser: String)
        /// Generic failure — a known browser priming returned an
        /// unexpected status, or yt-dlp ran but returned a non-zero
        /// exit with output that didn't match any specific known
        /// pattern. The associated string is the truncated stderr/
        /// status for display.
        case generic(stderr: String)
        /// yt-dlp couldn't be launched at all (binary missing, etc.).
        /// Retained from the earlier subprocess-based primer for
        /// completeness, though the current Security-framework
        /// primer doesn't generate this case.
        case ytdlpUnavailable(path: String)
    }

    /// Browser whose cookies yt-dlp should use when resolving network URLs.
    /// Lives on ToolManager (not the engine) so the engine's published surface
    /// stays unchanged — this is purely a yt-dlp concern. Setter is public so
    /// the sidebar picker can bind to it; mutation hops to MainActor via the
    /// usual published-property pathway since this class isn't actor-isolated.
    ///
    /// Persisted in UserDefaults under `Self.cookieBrowserDefaultsKey`. The
    /// initial value is loaded from UserDefaults via `loadInitialCookieBrowser()`
    /// at instance-construction time, and every subsequent change writes back
    /// through the `didSet` observer. `didSet` doesn't fire during the init
    /// store, so there's no read-write loop on startup.
    ///
    /// Default: `.none` — we don't enable cookie reading silently because
    /// that would surprise users with Keychain prompts they didn't ask for.
    /// This default only applies on a fresh install; once the user picks a
    /// browser, the choice is sticky across app restarts.
    @Published var cookieBrowser: CookieBrowser = ToolManager.loadInitialCookieBrowser() {
        didSet {
            // Skip the write when nothing actually changed. SwiftUI's
            // two-way binding through `$toolManager.cookieBrowser` can
            // re-publish the same value during view rebuilds; a write per
            // rebuild is harmless but wasteful and pollutes UserDefaults
            // change observers downstream.
            guard oldValue != cookieBrowser else { return }
            UserDefaults.standard.set(cookieBrowser.rawValue, forKey: Self.cookieBrowserDefaultsKey)

            // Clear any stale issue from a previous browser selection
            // so the banner doesn't show outdated guidance while the
            // new browser's prime is in flight. The primer will
            // re-publish if a new issue is detected.
            cookiePrimingIssue = nil

            // Prime the appropriate access mechanism for this browser
            // directly, without spawning yt-dlp. Each browser family
            // stores cookies differently:
            //
            //   Chromium family (Chrome, Brave, Edge, Arc): the cookie
            //   database is encrypted, and the encryption key lives
            //   in macOS Keychain under "<Browser Name> Safe Storage".
            //   We query that keychain entry directly via the
            //   Security framework — this is the SAME keychain entry
            //   yt-dlp would ask for, just accessed without the
            //   subprocess detour. macOS fires its standard "wants to
            //   access X cookies" prompt; user grants or denies.
            //
            //   Firefox: cookies.sqlite is unencrypted, no Keychain
            //   needed. Nothing to prime.
            //
            //   Safari: cookies live in Safari's TCC-protected
            //   container, so the issue is Full Disk Access, not
            //   Keychain. We detect by trying to read the file
            //   directly — if it's not readable, we know FDA isn't
            //   granted and surface the banner.
            //
            // Running on a detached Task because SecItemCopyMatching
            // is synchronous and can block waiting for user response
            // to the prompt. Main thread stays responsive.
            let browser = cookieBrowser
            Task.detached(priority: .userInitiated) {
                Self.primeCookieAccess(for: browser)
            }
        }
    }

    /// Skip TLS certificate validation in yt-dlp by passing
    /// `--no-check-certificate`. Off by default — TLS validation is a
    /// real security control and we don't want to weaken it without
    /// user opt-in. The use case is corporate networks where a
    /// middlebox does TLS interception with a self-signed root that
    /// the system trust store doesn't have, so legitimate yt-dlp
    /// requests fail SSL handshake even though the connection is
    /// otherwise valid. Surfaces in the Tools section right under
    /// the Cookies row.
    ///
    /// Same UserDefaults persistence pattern as `cookieBrowser`:
    /// loaded at init via the static helper, written back through
    /// `didSet` on every change, skip-when-unchanged to avoid SwiftUI
    /// rebuild churn writing duplicate values.
    @Published var disableTLSCheck: Bool = ToolManager.loadInitialDisableTLSCheck() {
        didSet {
            guard oldValue != disableTLSCheck else { return }
            UserDefaults.standard.set(disableTLSCheck, forKey: Self.disableTLSCheckDefaultsKey)
        }
    }

    /// User-supplied path to a CA bundle file. When non-empty, this is
    /// passed to every yt-dlp child process via `SSL_CERT_FILE` in its
    /// environment, so yt-dlp's underlying TLS stack trusts the
    /// corporate root that the system trust store doesn't have. Empty
    /// string means "fall back to auto-detect" — see `detectedSSLCertFile`.
    ///
    /// Distinct from `disableTLSCheck` because they solve different
    /// problems: the disable flag turns OFF verification entirely
    /// (suitable when nothing else works); this one ADDS a trusted
    /// root (suitable when the user knows what cert their middlebox
    /// presents and prefers proper validation). When both are set
    /// the disable flag wins because yt-dlp ignores `SSL_CERT_FILE`
    /// in `--no-check-certificate` mode.
    ///
    /// Same UserDefaults persistence pattern as the other settings
    /// in this class.
    @Published var customSSLCertFile: String = ToolManager.loadInitialCustomSSLCertFile() {
        didSet {
            guard oldValue != customSSLCertFile else { return }
            UserDefaults.standard.set(customSSLCertFile, forKey: Self.customSSLCertFileDefaultsKey)
        }
    }

    /// User-supplied path to a yt-dlp binary that overrides the bundled
    /// one. The use case is the bundled PyInstaller yt-dlp on
    /// corporate-TLS-interception networks: it ships with `certifi`
    /// baked in and ignores `SSL_CERT_FILE` entirely, so the only way
    /// to make it trust a custom CA is to use a different yt-dlp build
    /// — typically one installed via `pip install yt-dlp` or `brew
    /// install yt-dlp` whose Python uses the system's OpenSSL.
    ///
    /// Empty string means "use the bundled binary" (current behavior).
    /// Non-empty + executable file present means StreamScribe uses
    /// THAT binary for every yt-dlp invocation (probe, download, live
    /// pipe, URL resolve) — completely replacing the bundled one for
    /// that session. The bundled binary stays on disk and remains
    /// auto-updatable in case the user wants to revert.
    @Published var customYTDlpPath: String = ToolManager.loadInitialCustomYTDlpPath() {
        didSet {
            guard oldValue != customYTDlpPath else { return }
            UserDefaults.standard.set(customYTDlpPath, forKey: Self.customYTDlpPathDefaultsKey)
        }
    }

    /// Auto-detected path to an externally-installed yt-dlp (Homebrew,
    /// pip, MacPorts). Populated at `bootstrap()` by scanning common
    /// install locations. Distinct from `customYTDlpPath` (the user's
    /// explicit override) — this is just a suggestion the UI can
    /// surface when no override is set and a working yt-dlp is found
    /// somewhere on disk.
    ///
    /// Why we surface this: on corporate-TLS-interception networks the
    /// bundled PyInstaller yt-dlp has no working SSL workaround (we've
    /// established this empirically — neither `SSL_CERT_FILE` nor
    /// `REQUESTS_CA_BUNDLE` env vars take effect in the bundled
    /// binary). Users on those networks need to install yt-dlp
    /// themselves via pip/brew. Auto-detecting saves them the step of
    /// finding and pasting the path.
    @Published private(set) var detectedExternalYTDlpPath: String?

    /// Path picked up automatically from the user's environment.
    /// Checked at init in this order: process environment (set when
    /// launching from Terminal), then `~/.zshrc` and
    /// `~/.bash_profile` parsing for `export SSL_CERT_FILE=...`
    /// lines. nil if nothing found.
    ///
    /// Read-only from the UI's perspective; the user can see what
    /// we auto-detected as a hint in the Tools section. `customSSLCertFile`
    /// (if non-empty) takes precedence.
    @Published private(set) var detectedSSLCertFile: String?

    /// The path that actually gets passed to yt-dlp child processes,
    /// resolved at call time. User-override wins; falls back to
    /// auto-detected; nil = no `SSL_CERT_FILE` env var set, yt-dlp
    /// uses its built-in CA bundle.
    var effectiveSSLCertFile: String? {
        let trimmed = customSSLCertFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return detectedSSLCertFile
    }

    /// UserDefaults key for the persisted cookie-browser choice. Namespaced
    /// under `toolManager.` to keep our preferences grouped and avoid
    /// collisions with future settings.
    private static let cookieBrowserDefaultsKey = "toolManager.cookieBrowser"

    /// UserDefaults key for the persisted "skip TLS validation" toggle.
    private static let disableTLSCheckDefaultsKey = "toolManager.disableTLSCheck"

    /// UserDefaults key for the persisted custom SSL cert file path.
    private static let customSSLCertFileDefaultsKey = "toolManager.customSSLCertFile"

    /// UserDefaults key for the persisted custom yt-dlp binary path.
    private static let customYTDlpPathDefaultsKey = "toolManager.customYTDlpPath"

    /// Load the persisted cookie-browser choice from UserDefaults, falling
    /// back to `.none` if no value is stored or if the stored raw value
    /// doesn't match any current `CookieBrowser` case (e.g. user downgraded
    /// the app after picking a browser added in a newer release — we'd
    /// rather reset to none than crash or carry a phantom value).
    ///
    /// `static` because it's called from the property's default-value
    /// initializer, which runs before `self` is available.
    private static func loadInitialCookieBrowser() -> CookieBrowser {
        guard let raw = UserDefaults.standard.string(forKey: cookieBrowserDefaultsKey),
              let browser = CookieBrowser(rawValue: raw) else {
            return .none
        }
        return browser
    }

    /// Trigger the appropriate macOS access prompt for the
    /// newly-selected cookie browser, without spawning yt-dlp.
    ///
    /// **Why direct instead of subprocess.** The earlier version of
    /// this code ran yt-dlp with `--cookies-from-browser` to make it
    /// open the browser's cookie store, which in turn triggered the
    /// macOS Keychain prompt as a side effect. That worked for
    /// browsers that use Keychain (Chrome-family), but had several
    /// downsides:
    ///   - 5-15 second latency from spawning yt-dlp, doing a YouTube
    ///     round-trip, and parsing the response
    ///   - Required network access — failed on offline or blocked
    ///     networks even though we only wanted to prime local access
    ///   - For Safari (TCC, not Keychain) and Firefox (unencrypted,
    ///     no Keychain), the subprocess approach was either failing
    ///     or doing pointless work
    ///
    /// **Direct approach.** Each Chromium-family browser stores its
    /// cookie encryption key under a known Keychain service/account.
    /// We query that entry via `SecItemCopyMatching`, which is the
    /// Security framework call that yt-dlp itself uses underneath.
    /// On first call for a given app, macOS shows the standard
    /// Keychain access prompt; on subsequent calls (or if the user
    /// granted "Always Allow") it returns silently. Either way, the
    /// outcome tells us whether yt-dlp will succeed later.
    ///
    /// Firefox doesn't use Keychain (cookies live in an unencrypted
    /// SQLite file), so no prompt is needed — we just clear any
    /// prior issue and return.
    ///
    /// Safari doesn't use Keychain either; its cookies live in
    /// `~/Library/Containers/com.apple.Safari/...`, protected by TCC
    /// (Full Disk Access). We detect missing FDA by trying to read
    /// the cookies file directly — if it's not readable, we surface
    /// the .safariNeedsFullDiskAccess banner.
    ///
    /// Each branch publishes its outcome (nil for success, an issue
    /// case otherwise) via `publishCookieIssue`.
    private static func primeCookieAccess(for browser: CookieBrowser) {
        switch browser {
        case .none:
            // Nothing selected — clear any prior issue and return.
            publishCookieIssue(nil)

        case .chrome:
            primeKeychainEntry(service: "Chrome Safe Storage",
                               account: "Chrome",
                               displayName: "Chrome")
        case .brave:
            primeKeychainEntry(service: "Brave Safe Storage",
                               account: "Brave",
                               displayName: "Brave")
        case .edge:
            primeKeychainEntry(service: "Microsoft Edge Safe Storage",
                               account: "Microsoft Edge",
                               displayName: "Microsoft Edge")
        case .arc:
            primeKeychainEntry(service: "Arc Safe Storage",
                               account: "Arc",
                               displayName: "Arc")

        case .firefox:
            // Firefox doesn't encrypt cookies with a Keychain-stored
            // key. The cookies.sqlite file is in the user's home dir
            // with normal POSIX permissions — readable without any
            // additional grant.
            print("[ToolManager] Firefox cookies don't use Keychain — no prompt needed")
            publishCookieIssue(nil)

        case .safari:
            checkSafariFullDiskAccess()
        }
    }

    /// Query a single Keychain entry by service + account. macOS shows
    /// its standard access prompt the first time we ask; subsequent
    /// calls return the cached decision.
    ///
    /// **Return data, then discard immediately.** `kSecReturnData: true`
    /// is what tells macOS we actually want the secret value — which
    /// is what triggers the access prompt. We don't keep the data
    /// (it's just the cookie encryption key, which we don't need
    /// — yt-dlp will fetch it itself when it runs); the local
    /// `result` variable goes out of scope when this function returns.
    /// What we keep is the OSStatus, which tells us whether access
    /// was granted, denied, or whether the entry exists at all.
    ///
    /// **Status interpretation:**
    ///   errSecSuccess (0): access granted, all good
    ///   errSecItemNotFound (-25300): no such entry — user probably
    ///     hasn't run this browser yet, so there's no cookie key in
    ///     Keychain. Not really an error from our perspective; if
    ///     cookies aren't there, yt-dlp's eventual extraction will
    ///     fail clearly when it tries to use them.
    ///   errSecUserCanceled (-128): user clicked Deny on the prompt.
    ///   errSecAuthFailed (-25293): persistent deny — the user
    ///     previously chose "Deny" and macOS is enforcing that
    ///     without re-prompting.
    ///   anything else: unexpected — log it for diagnostics.
    private static func primeKeychainEntry(
        service: String,
        account: String,
        displayName: String
    ) {
        print("[ToolManager] Priming Keychain access for '\(service)'…")
        let startTime = Date()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        result = nil  // discard the key value immediately

        let elapsed = Date().timeIntervalSince(startTime)
        print(String(
            format: "[ToolManager] Keychain prime '%@': finished in %.2fs (OSStatus %d)",
            service, elapsed, Int(status)
        ))

        switch status {
        case errSecSuccess:
            print("[ToolManager] Keychain access GRANTED for \(displayName)")
            publishCookieIssue(nil)

        case errSecItemNotFound:
            // The keychain entry doesn't exist. Most likely: user
            // hasn't launched this browser yet, or never accessed a
            // site that caused it to store a cookie. yt-dlp will
            // fail gracefully later if cookies are needed and absent.
            print("[ToolManager] Keychain entry not present for \(displayName) — browser may not have stored cookies yet")
            publishCookieIssue(nil)

        case errSecUserCanceled, errSecAuthFailed:
            print("[ToolManager] Keychain access DENIED for \(displayName)")
            publishCookieIssue(.keychainDenied(browser: displayName))

        default:
            // Catch-all for unexpected statuses. errSecMissingEntitlement
            // (-34018) and a few others can show up in unusual signing/
            // sandbox configurations.
            let message = "OSStatus \(status) when accessing \(displayName) keychain"
            print("[ToolManager] \(message)")
            publishCookieIssue(.generic(stderr: message))
        }
    }

    /// Detect whether StreamScribe has Full Disk Access by trying to
    /// read Safari's cookies file directly. No yt-dlp needed; no
    /// network needed. If the file isn't readable, the user needs to
    /// grant FDA in System Settings.
    ///
    /// The path is the standard Safari cookies location and has been
    /// stable across macOS Big Sur through Sequoia.
    private static func checkSafariFullDiskAccess() {
        let cookiesPath = NSString(string:
            "~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"
        ).expandingTildeInPath

        // Two-stage check: existence + readability. If the file
        // doesn't exist at all, that's a "user never launched Safari"
        // situation, not a permission issue — distinguish so the
        // banner doesn't tell the user to grant FDA when there's
        // nothing to read anyway.
        let fm = FileManager.default
        if !fm.fileExists(atPath: cookiesPath) {
            print("[ToolManager] Safari cookies file not found at \(cookiesPath) — Safari may not have been launched yet")
            publishCookieIssue(nil)
            return
        }
        if fm.isReadableFile(atPath: cookiesPath) {
            print("[ToolManager] Safari cookies readable — Full Disk Access OK")
            publishCookieIssue(nil)
        } else {
            print("[ToolManager] Safari cookies NOT readable — Full Disk Access needed")
            publishCookieIssue(.safariNeedsFullDiskAccess)
        }
    }

    /// Hop to the main actor to update the `@Published cookiePrimingIssue`.
    /// `runKeychainPrimer` is static and runs on a detached Task off the
    /// main actor; this is the single hop point so callers don't sprinkle
    /// `MainActor.run` blocks throughout the diagnostic code.
    private static func publishCookieIssue(_ issue: CookiePrimingIssue?) {
        Task { @MainActor in
            ToolManager.shared.cookiePrimingIssue = issue
        }
    }

    /// Load the persisted `disableTLSCheck` flag. UserDefaults returns
    /// `false` for missing-or-non-bool, which matches our intended
    /// default (TLS checking ON), so this is a one-liner.
    private static func loadInitialDisableTLSCheck() -> Bool {
        UserDefaults.standard.bool(forKey: disableTLSCheckDefaultsKey)
    }

    /// Load the persisted user-override SSL cert file path. Empty
    /// string is fine and meaningful: "no override; use auto-detect."
    private static func loadInitialCustomSSLCertFile() -> String {
        UserDefaults.standard.string(forKey: customSSLCertFileDefaultsKey) ?? ""
    }

    /// Load the persisted custom yt-dlp path. Empty string means "use
    /// bundled" (default behavior).
    private static func loadInitialCustomYTDlpPath() -> String {
        UserDefaults.standard.string(forKey: customYTDlpPathDefaultsKey) ?? ""
    }

    /// Auto-detect an `SSL_CERT_FILE` path the user has configured for
    /// their shell. Two strategies:
    ///
    ///   1. **Process environment**: `ProcessInfo.processInfo.environment["SSL_CERT_FILE"]`.
    ///      Set when the app was launched from a terminal (`open
    ///      StreamScribe.app` from a shell, or `npm start` style
    ///      tooling). Most reliable signal when present.
    ///
    ///   2. **Shell config parsing**: macOS GUI apps launched from
    ///      Finder/Dock/Spotlight don't inherit the user's shell
    ///      environment — `SSL_CERT_FILE` set in `~/.zshrc` or
    ///      `~/.bash_profile` won't appear in the process env. Fall
    ///      back to grepping those files for `export SSL_CERT_FILE=...`
    ///      so the GUI-launch case picks up the same value the
    ///      Terminal-launch case would.
    ///
    /// Returns the resolved path, or nil if no setting found. We DON'T
    /// validate that the file exists — yt-dlp itself will error if the
    /// path is bad, and surfacing a "file missing" error here would be
    /// misleading for a value the user might fix without restarting
    /// StreamScribe.
    ///
    /// Tilde expansion is applied so values like `~/certs/corp.pem`
    /// work. Quote characters (' and ") around the value (common in
    /// shell configs) are stripped.
    static func detectSSLCertFileFromEnvironment() -> String? {
        // Strategy 1: process environment.
        if let envValue = ProcessInfo.processInfo.environment["SSL_CERT_FILE"],
           !envValue.isEmpty {
            return expandPath(envValue)
        }

        // Strategy 2: shell config files. Order matters — zsh is
        // default on macOS 10.15+ so check it first.
        guard let home = ProcessInfo.processInfo.environment["HOME"] else {
            return nil
        }
        let candidatePaths = [
            "\(home)/.zshrc",
            "\(home)/.zshenv",
            "\(home)/.bash_profile",
            "\(home)/.bashrc",
            "\(home)/.profile",
        ]
        for path in candidatePaths {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }
            if let value = parseSSLCertFileExport(from: contents) {
                return expandPath(value)
            }
        }
        return nil
    }

    /// Parse an `export SSL_CERT_FILE=...` line out of shell config
    /// content. Returns the right-hand-side value (quotes stripped),
    /// or nil if no such line.
    ///
    /// Matches both `export SSL_CERT_FILE=value` and the bare
    /// `SSL_CERT_FILE=value` form (zsh allows both). Skips commented
    /// lines (`#` at start, possibly after whitespace).
    private static func parseSSLCertFileExport(from contents: String) -> String? {
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            // Trim leading `export ` if present.
            var body = line
            if body.hasPrefix("export ") {
                body = String(body.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard body.hasPrefix("SSL_CERT_FILE=") else { continue }
            var value = String(body.dropFirst("SSL_CERT_FILE=".count))
            // Strip wrapping quotes — `="foo"` and `='foo'` are common.
            if value.count >= 2 {
                let first = value.first!
                let last = value.last!
                if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                    value = String(value.dropFirst().dropLast())
                }
            }
            // Trim any trailing inline comment (` # comment`).
            if let hashIdx = value.firstIndex(of: "#") {
                value = String(value[..<hashIdx]).trimmingCharacters(in: .whitespaces)
            }
            value = value.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            return value
        }
        return nil
    }

    /// Expand leading `~` to the user's home directory. yt-dlp would
    /// otherwise see a literal `~` and fail to find the file.
    private static func expandPath(_ path: String) -> String {
        if path.hasPrefix("~/"), let home = ProcessInfo.processInfo.environment["HOME"] {
            return home + String(path.dropFirst())
        }
        if path == "~", let home = ProcessInfo.processInfo.environment["HOME"] {
            return home
        }
        return path
    }

    /// Scan well-known install locations for an externally-installed
    /// yt-dlp. Returns the first executable file found, or nil. Order
    /// matters — earlier paths are higher precedence:
    ///
    ///   1. `/opt/homebrew/bin/yt-dlp` — Homebrew on Apple Silicon
    ///   2. `/usr/local/bin/yt-dlp` — Homebrew on Intel, manual installs
    ///   3. `~/Library/Python/*/bin/yt-dlp` — pip --user (this is where
    ///      `pip install --user yt-dlp` lands on macOS; we enumerate
    ///      the directory because the Python version varies)
    ///   4. `~/.local/bin/yt-dlp` — alternate pip --user location
    ///   5. `/opt/local/bin/yt-dlp` — MacPorts
    ///
    /// Returns the first match. Glob-style scans (item 3) prefer
    /// higher Python versions when multiple are present (3.14 > 3.13
    /// > 3.12, etc.), since newer Python typically means newer SSL/TLS
    /// support.
    ///
    /// Why this is fine to run synchronously on the main launch path:
    /// `isExecutableFile` is a `stat()` call, ~microseconds per path,
    /// and we probe at most ~10 paths total even after enumerating
    /// `~/Library/Python/`. Negligible vs. the rest of bootstrap.
    static func detectExternalYTDlp() -> String? {
        var candidates: [String] = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
        ]

        // pip --user location: scan ~/Library/Python/* for any yt-dlp
        // binary, sorted descending so newer Python wins. Wrapped in
        // a guard because the parent dir may not exist on systems
        // that never used pip.
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            let pythonRoot = "\(home)/Library/Python"
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: pythonRoot) {
                // Sort descending so 3.14 sorts before 3.13 sorts
                // before 3.12. String compare works because we're
                // comparing same-prefix version strings; "3.14" >
                // "3.13" lexicographically.
                let sorted = entries.sorted(by: >)
                for entry in sorted {
                    candidates.append("\(pythonRoot)/\(entry)/bin/yt-dlp")
                }
            }
            candidates.append("\(home)/.local/bin/yt-dlp")
        }

        candidates.append("/opt/local/bin/yt-dlp")  // MacPorts

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Build a child-process environment dictionary that includes
    /// `SSL_CERT_FILE` (when we have a value) on top of the inherited
    /// process environment. Pass the returned dict to `Process.environment`
    /// before launching yt-dlp.
    ///
    /// When neither user-override nor auto-detect produced a value,
    /// returns nil — caller should leave `process.environment` at its
    /// default (inherit the parent's env unchanged), which is the
    /// existing behavior for everything else in this app.
    func ytDlpChildEnvironment() -> [String: String]? {
        guard let certPath = effectiveSSLCertFile else {
            // Log once-per-resolve so users can ⌘L the log viewer and
            // confirm exactly which cert (if any) is being used by
            // yt-dlp. Quiet "no override" path uses a single line per
            // invocation; the override path adds the resolved value.
            print("[ToolManager] yt-dlp: no SSL_CERT_FILE override (using system default trust store)")
            return nil
        }
        var env = ProcessInfo.processInfo.environment
        env["SSL_CERT_FILE"] = certPath
        // Indicate which source the path came from so the log helps
        // diagnose "did my override take effect?" vs "is the
        // auto-detected value being picked up?" — without making the
        // user open a debugger.
        let source: String = {
            let userTyped = customSSLCertFile.trimmingCharacters(in: .whitespacesAndNewlines)
            if !userTyped.isEmpty { return "user-selected" }
            return "auto-detected"
        }()
        // File-existence sanity check. A missing path almost always
        // means a typo or the file was deleted/moved; surfacing it
        // here lets the user fix it without first running yt-dlp and
        // seeing a confusing error.
        let exists = FileManager.default.isReadableFile(atPath: certPath)
        let existsTag = exists ? "exists" : "MISSING ON DISK"
        print("[ToolManager] yt-dlp: SSL_CERT_FILE=\(certPath) (\(source), \(existsTag))")
        return env
    }

    enum YTDlpStatus: Equatable {
        case unknown
        case checking
        case downloading(progress: Double)   // 0.0…1.0
        case ready
        case error(String)

        var label: String {
            switch self {
            case .unknown: return "Not checked"
            case .checking: return "Checking for updates…"
            case .downloading(let p): return "Downloading yt-dlp… \(Int(p * 100))%"
            case .ready: return "Up to date"
            case .error(let msg): return "Error: \(msg)"
            }
        }
    }

    /// Same shape as `YTDlpStatus`. Kept as a separate type rather than a generic
    /// "ToolStatus" because the user-facing labels differ ("Downloading Deno…" vs
    /// "Downloading yt-dlp…") and the small amount of duplication is clearer than
    /// threading a name parameter through every label call.
    enum DenoStatus: Equatable {
        case unknown
        case checking
        case downloading(progress: Double)
        case extracting
        case ready
        case error(String)

        var label: String {
            switch self {
            case .unknown: return "Not checked"
            case .checking: return "Checking for updates…"
            case .downloading(let p): return "Downloading Deno… \(Int(p * 100))%"
            case .extracting: return "Extracting Deno…"
            case .ready: return "Up to date"
            case .error(let msg): return "Error: \(msg)"
            }
        }
    }

    // MARK: - Paths (non-isolated, safe to call from any context)

    var ffmpegPath: String? {
        Bundle.main.url(forResource: "ffmpeg", withExtension: nil)?.path
    }

    var ytDlpPath: String {
        Self.appSupportDir.appendingPathComponent("yt-dlp").path
    }

    /// The yt-dlp path that callers should ACTUALLY use for spawning.
    /// User override wins when it's set and points at an executable
    /// file on disk; otherwise falls back to the bundled binary.
    ///
    /// **Why a computed property and not @Published.** This is read
    /// once per yt-dlp invocation (typically a few times per session)
    /// from various actor contexts. Making it computed avoids the
    /// MainActor isolation that @Published implies, and a stale-by-a-
    /// few-ms result is harmless — the value gets re-read on every
    /// spawn anyway. The user-typed path lives in `@Published
    /// customYTDlpPath` so SwiftUI updates the UI label when it
    /// changes; this just composes that with the existence check.
    ///
    /// **Empty-string vs. missing-file handling.** Distinguished
    /// deliberately: empty string is the user's intent ("use bundled"),
    /// while a non-empty path that points at a missing/non-executable
    /// file is a configuration error. We fall back to bundled in
    /// both cases, but the latter logs a warning so the user can
    /// figure out what happened (typo, file moved, etc).
    var effectiveYTDlpPath: String {
        let override = customYTDlpPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if override.isEmpty {
            return ytDlpPath
        }
        if FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        print("[ToolManager] Custom yt-dlp path '\(override)' not executable; falling back to bundled binary.")
        return ytDlpPath
    }

    /// Path to our auto-downloaded Deno binary. Sits in the same Application Support
    /// directory as yt-dlp. The file is the actual `deno` executable — we extract it
    /// from the GitHub release zip into this exact name during install.
    var denoPath: String {
        Self.appSupportDir.appendingPathComponent("deno").path
    }

    private static var appSupportDir: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("StreamScribe", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private var versionFilePath: String {
        Self.appSupportDir.appendingPathComponent("yt-dlp.version").path
    }

    private var denoVersionFilePath: String {
        Self.appSupportDir.appendingPathComponent("deno.version").path
    }

    // MARK: - Public API

    /// Called once at app launch. Loads the cached version, kicks off a background
    /// update check. Doesn't block — the app can run without yt-dlp until a YouTube URL
    /// is entered.
    func bootstrap() {
        loadCachedVersion()
        loadCachedDenoVersion()
        // Probe shell config for SSL_CERT_FILE so the auto-detect
        // value is available for the UI to display and (if no user
        // override is set) to use for yt-dlp child processes. Cheap
        // — reads at most 3 small text files — so it's fine on the
        // main launch path.
        let detected = Self.detectSSLCertFileFromEnvironment()
        Task { @MainActor in
            self.detectedSSLCertFile = detected
        }
        if let d = detected {
            print("[ToolManager] Auto-detected SSL_CERT_FILE: \(d)")
        } else {
            print("[ToolManager] No SSL_CERT_FILE auto-detected from environment or shell configs.")
        }

        // Probe for an externally-installed yt-dlp (Homebrew, pip,
        // MacPorts). When found, the UI surfaces it as a suggestion
        // for users hitting SSL issues with the bundled binary —
        // they can one-click switch instead of having to find and
        // paste the path manually. Synchronous because the scan is
        // ~microseconds and the UI wants the value immediately.
        let externalYTDlp = Self.detectExternalYTDlp()
        Task { @MainActor in
            self.detectedExternalYTDlpPath = externalYTDlp
        }
        if let ext = externalYTDlp {
            print("[ToolManager] Detected external yt-dlp at: \(ext)")
        } else {
            print("[ToolManager] No external yt-dlp found in common install locations.")
        }

        Task.detached { [weak self] in
            await self?.refreshIfNeeded()
        }
        // Deno doesn't need a refresh-on-launch — its release cadence is slow and a
        // mismatched version isn't a security/functionality emergency the way a
        // stale yt-dlp is. We just confirm the cached binary still exists.
    }

    /// Ensure yt-dlp exists on disk and return the path callers should
    /// invoke. Two paths:
    ///
    ///   - **Custom override set + valid:** return it immediately. We
    ///     skip the bundled-binary download step here — if the user
    ///     pointed at their own yt-dlp, they don't want us silently
    ///     reaching for the bundled one too.
    ///   - **No override (or override invalid):** check the bundled
    ///     binary; if missing, download the latest release; return
    ///     the bundled path.
    func ensureYTDlpAvailable() async throws -> String {
        let override = customYTDlpPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            print("[ToolManager] yt-dlp: using custom binary at \(override)")
            return override
        }
        if !override.isEmpty {
            // Override set but not executable. Log so the user has a
            // breadcrumb in the log viewer; fall back to bundled.
            print("[ToolManager] yt-dlp: custom binary at '\(override)' not executable; falling back to bundled.")
        }
        if FileManager.default.isExecutableFile(atPath: ytDlpPath) {
            return ytDlpPath
        }
        try await downloadLatest()
        return ytDlpPath
    }

    /// Force a fresh download regardless of cached version. Backed by the menu item
    /// "Update yt-dlp Now…".
    func updateYTDlpNow() async {
        do {
            try await downloadLatest()
        } catch {
            await setStatus(.error(error.localizedDescription))
        }
    }

    /// Background update check. Fetches the latest release tag from GitHub and
    /// compares against the cached version. If newer, downloads it.
    func refreshIfNeeded() async {
        await setStatus(.checking)
        do {
            let latest = try await fetchLatestVersionTag()
            await MainActor.run { self.lastUpdateCheck = Date() }

            let currentVersion = await MainActor.run { self.ytDlpVersion }

            if let current = currentVersion, current == latest,
               FileManager.default.isExecutableFile(atPath: ytDlpPath) {
                await setStatus(.ready)
                return
            }

            // Either no cached version, mismatched version, or binary missing — refresh.
            try await downloadLatest()
        } catch {
            // Don't escalate to error if we have a working cached binary; the user can
            // still use yt-dlp, they just don't get the latest version this session.
            if FileManager.default.isExecutableFile(atPath: ytDlpPath) {
                await setStatus(.ready)
            } else {
                await setStatus(.error(error.localizedDescription))
            }
        }
    }

    // MARK: - Internals

    private func loadCachedVersion() {
        let cachedVersion = (try? String(contentsOfFile: versionFilePath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let exists = FileManager.default.isExecutableFile(atPath: ytDlpPath)
        Task { @MainActor in
            self.ytDlpVersion = cachedVersion
            if exists { self.ytDlpStatus = .ready }
        }
    }

    /// Hit GitHub's API and return the latest release tag (e.g. "2025.10.31").
    private func fetchLatestVersionTag() async throws -> String {
        let url = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("StreamScribe", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ToolError.updateFetchFailed("yt-dlp release fetch HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        struct Release: Decodable { let tag_name: String }
        let release = try JSONDecoder().decode(Release.self, from: data)
        return release.tag_name
    }

    /// Download the `yt-dlp_macos` binary from the latest release, verify its SHA-256
    /// against the published checksum, and atomically replace the on-disk binary.
    /// Runs entirely off the main actor (only `setStatus` hops back).
    private func downloadLatest() async throws {
        print("[ToolManager] yt-dlp update starting…")
        let tag = try await fetchLatestVersionTag()
        let base = "https://github.com/yt-dlp/yt-dlp/releases/download/\(tag)"
        let binaryURL = URL(string: "\(base)/yt-dlp_macos")!
        let sumsURL   = URL(string: "\(base)/SHA2-256SUMS")!

        await setStatus(.downloading(progress: 0))

        // Pull the SHA sums file first; it's tiny and lets us verify the binary later.
        let (sumsData, sumsResp) = try await URLSession.shared.data(from: sumsURL)
        guard (sumsResp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ToolError.updateFetchFailed("Could not fetch yt-dlp SHA2-256SUMS")
        }
        let expectedSum = try Self.parseExpectedSum(
            from: sumsData, filename: "yt-dlp_macos"
        )

        // Stream the binary download with progress callbacks.
        // We use URLSession.shared.bytes for progress reporting but read in
        // chunks rather than byte-by-byte. The AsyncBytes sequence yields
        // individual bytes; collecting them one-at-a-time into Data is ~40M
        // iterations for a 40MB binary — each with a cooperative suspension
        // point and a Data.append. That made downloads take minutes even on
        // fast connections. Instead we use the bulk .data(from:) API for the
        // actual download (single allocation, no per-byte overhead) and give
        // up per-byte progress. Since the download is ~40MB and typically
        // completes in a few seconds on broadband, the tradeoff is fine —
        // we show indeterminate "Downloading…" and jump to "Verifying…"
        // when the response arrives.
        await setStatus(.downloading(progress: 0))
        let (data, binResp) = try await URLSession.shared.data(from: binaryURL)
        guard let httpBin = binResp as? HTTPURLResponse, httpBin.statusCode == 200 else {
            throw ToolError.updateFetchFailed("yt-dlp download HTTP \((binResp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        await setStatus(.downloading(progress: 1.0))

        // Verify SHA-256 (CPU-bound, on this task's executor — not main).
        let actualSum = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        guard actualSum.lowercased() == expectedSum.lowercased() else {
            throw ToolError.checksumMismatch(expected: expectedSum, actual: actualSum)
        }
        print("[ToolManager] yt-dlp \(tag) downloaded and verified.")

        // Atomic replace: write to temp file, chmod, then move into place.
        let dest = ytDlpPath
        let tmpURL = URL(fileURLWithPath: dest + ".tmp")
        try data.write(to: tmpURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tmpURL.path
        )
        if FileManager.default.fileExists(atPath: dest) {
            try FileManager.default.removeItem(atPath: dest)
        }
        try FileManager.default.moveItem(atPath: tmpURL.path, toPath: dest)

        // Persist the new version tag.
        try tag.write(toFile: versionFilePath, atomically: true, encoding: .utf8)

        await MainActor.run {
            self.ytDlpVersion = tag
            self.ytDlpStatus = .ready
            self.lastUpdateCheck = Date()
        }
        print("[ToolManager] yt-dlp \(tag) installed at \(dest)")
    }

    /// Hop to MainActor to publish a status change.
    @MainActor
    private func publishStatus(_ s: YTDlpStatus) {
        self.ytDlpStatus = s
    }

    private func setStatus(_ s: YTDlpStatus) async {
        await publishStatus(s)
    }

    /// Parse a SHA2-256SUMS file (lines like `<hex>  <filename>`) and return the
    /// hash for the requested filename. Some shasum implementations write `<hex> *<filename>`
    /// (binary mode) — we tolerate either.
    private static func parseExpectedSum(from data: Data, filename: String) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolError.updateFetchFailed("Could not decode SHA2-256SUMS")
        }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let name = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " *"))
            if name == filename {
                return String(parts[0])
            }
        }
        throw ToolError.updateFetchFailed("Could not find \(filename) in SHA2-256SUMS")
    }

    // MARK: - Deno

    /// Asset filename Deno publishes for this Mac's architecture. Build-time
    /// detection — a Mac binary is already arch-fixed, so this is a constant
    /// per build (no runtime branching cost). If you ever ship a universal
    /// binary you'd need to detect at runtime via `uname` or sysctlbyname.
    private static var denoAssetName: String {
        #if arch(arm64)
        return "deno-aarch64-apple-darwin.zip"
        #else
        return "deno-x86_64-apple-darwin.zip"
        #endif
    }

    /// Ensure Deno exists on disk. If missing, downloads and extracts the latest
    /// release before returning. Used by the YouTube extraction path so that
    /// yt-dlp's `--js-runtimes deno:<path>` flag has a real target.
    func ensureDenoAvailable() async throws -> String {
        if FileManager.default.isExecutableFile(atPath: denoPath) {
            return denoPath
        }
        try await downloadLatestDeno()
        return denoPath
    }

    /// Force a fresh Deno download regardless of cached version. Backed by a
    /// menu/sidebar item.
    func updateDenoNow() async {
        do {
            try await downloadLatestDeno()
        } catch {
            await setDenoStatus(.error(error.localizedDescription))
        }
    }

    private func loadCachedDenoVersion() {
        let cachedVersion = (try? String(contentsOfFile: denoVersionFilePath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let exists = FileManager.default.isExecutableFile(atPath: denoPath)
        Task { @MainActor in
            self.denoVersion = cachedVersion
            if exists { self.denoStatus = .ready }
        }
    }

    /// Hit GitHub's API and return Deno's latest release tag (e.g. "v2.5.4").
    /// Note: Deno tags include the `v` prefix; we strip it for display but keep
    /// it for URL construction.
    private func fetchLatestDenoTag() async throws -> String {
        let url = URL(string: "https://api.github.com/repos/denoland/deno/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("StreamScribe", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ToolError.updateFetchFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) fetching Deno release")
        }
        struct Release: Decodable { let tag_name: String }
        let release = try JSONDecoder().decode(Release.self, from: data)
        return release.tag_name
    }

    /// Download the architecture-appropriate Deno zip, verify its SHA-256 against
    /// the published per-asset checksum file, unzip via macOS's `/usr/bin/unzip`,
    /// chmod the binary, and atomically install. Runs entirely off MainActor.
    private func downloadLatestDeno() async throws {
        print("[ToolManager] Deno install starting…")
        await setDenoStatus(.checking)

        let tag = try await fetchLatestDenoTag()
        let assetName = Self.denoAssetName
        let base = "https://github.com/denoland/deno/releases/download/\(tag)"
        let zipURL = URL(string: "\(base)/\(assetName)")!
        // Deno publishes per-asset checksum files: e.g. "deno-aarch64-apple-darwin.zip.sha256sum"
        // contains a single line of the form "<hex>  <filename>".
        let sumURL = URL(string: "\(base)/\(assetName).sha256sum")!

        await setDenoStatus(.downloading(progress: 0))

        // Pull the checksum first so we can verify after download.
        let (sumData, sumResp) = try await URLSession.shared.data(from: sumURL)
        guard (sumResp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ToolError.updateFetchFailed("Could not fetch Deno checksum")
        }
        let expectedSum = try Self.parseExpectedSum(from: sumData, filename: assetName)

        // Bulk download — same rationale as the yt-dlp path above. Deno's
        // zip is ~30-40 MB; byte-by-byte iteration via AsyncBytes was the
        // bottleneck (tens of millions of cooperative suspension points).
        await setDenoStatus(.downloading(progress: 0))
        let (data, binResp) = try await URLSession.shared.data(from: zipURL)
        guard let httpBin = binResp as? HTTPURLResponse, httpBin.statusCode == 200 else {
            throw ToolError.updateFetchFailed("HTTP \((binResp as? HTTPURLResponse)?.statusCode ?? -1) downloading Deno")
        }
        await setDenoStatus(.downloading(progress: 1.0))

        // Verify SHA-256.
        let actualSum = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        guard actualSum.lowercased() == expectedSum.lowercased() else {
            throw ToolError.checksumMismatch(expected: expectedSum, actual: actualSum)
        }
        print("[ToolManager] Deno \(tag) downloaded and verified.")

        // Write zip to a temp location, then run /usr/bin/unzip to extract. We use
        // the system unzip rather than a Swift ZIP library because we don't have
        // any zip dependency in the project and adding one for this single use
        // would be heavy. /usr/bin/unzip is on every macOS install.
        await setDenoStatus(.extracting)
        let zipTmpURL = URL(fileURLWithPath: denoPath + ".zip.tmp")
        let extractDir = URL(fileURLWithPath: denoPath + ".extract.tmp")
        let fm = FileManager.default

        // Clean up any stale temp dir from a previous failed install.
        try? fm.removeItem(at: extractDir)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try data.write(to: zipTmpURL, options: .atomic)
        defer { try? fm.removeItem(at: zipTmpURL) }
        defer { try? fm.removeItem(at: extractDir) }

        try await runUnzip(zipPath: zipTmpURL.path, destinationPath: extractDir.path)

        // Deno's zip contains a single binary named "deno" at the archive root.
        // Verify and move it into place.
        let extractedBinary = extractDir.appendingPathComponent("deno")
        guard fm.fileExists(atPath: extractedBinary.path) else {
            throw ToolError.updateFetchFailed("Deno zip did not contain expected 'deno' binary")
        }

        // Atomic install: chmod, then move into final path.
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extractedBinary.path)
        if fm.fileExists(atPath: denoPath) {
            try fm.removeItem(atPath: denoPath)
        }
        try fm.moveItem(atPath: extractedBinary.path, toPath: denoPath)

        // Strip macOS quarantine attribute if present. Without this, Gatekeeper
        // may block the binary from running. Apps spawning child processes
        // typically don't get blocked but the attribute can still cause the
        // first-launch "downloaded from internet" prompt — clearing it
        // sidesteps that. Failure is non-fatal; if xattr isn't present or
        // the attribute wasn't set, we just continue.
        _ = try? await runProcessOnce(
            executable: "/usr/bin/xattr",
            arguments: ["-d", "com.apple.quarantine", denoPath]
        )

        // Persist the version (strip the leading 'v' for display nicety).
        let displayVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        try displayVersion.write(toFile: denoVersionFilePath, atomically: true, encoding: .utf8)

        await MainActor.run {
            self.denoVersion = displayVersion
            self.denoStatus = .ready
        }
        print("[ToolManager] Deno \(tag) installed at \(denoPath)")
    }

    /// Spawn `/usr/bin/unzip` to extract a zip file into a destination directory.
    /// Throws if unzip exits non-zero. Runs on a background queue (we await its
    /// termination via a checked continuation).
    private func runUnzip(zipPath: String, destinationPath: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            // -q quiet, -o overwrite without prompting (for retries),
            // -d destination directory.
            proc.arguments = ["-qo", zipPath, "-d", destinationPath]
            let errPipe = Pipe()
            proc.standardError = errPipe
            proc.standardOutput = Pipe()  // discard
            proc.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let err = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: err, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unzip failed (exit \(p.terminationStatus))"
                    cont.resume(throwing: ToolError.updateFetchFailed("unzip: \(msg)"))
                }
            }
            do {
                try proc.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    /// Best-effort run of an external process. Used for fire-and-forget housekeeping
    /// like clearing quarantine xattr — we don't care about output, only that we
    /// awaited completion before continuing.
    private func runProcessOnce(executable: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = arguments
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            proc.terminationHandler = { _ in cont.resume() }
            do {
                try proc.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    @MainActor
    private func publishDenoStatus(_ s: DenoStatus) {
        self.denoStatus = s
    }

    private func setDenoStatus(_ s: DenoStatus) async {
        await publishDenoStatus(s)
    }
}

enum ToolError: LocalizedError {
    case ffmpegMissing
    case ytDlpMissing
    case updateFetchFailed(String)
    case checksumMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .ffmpegMissing:
            return "ffmpeg binary not found in app bundle. The app build is incomplete — see SETUP.md for how to add ffmpeg to Resources."
        case .ytDlpMissing:
            return "yt-dlp is not installed yet. The app will download it from GitHub on first use; check your network connection."
        case .updateFetchFailed(let msg):
            // Used by both yt-dlp and Deno install paths; the message text from
            // the call site already names the tool ("Could not fetch Deno
            // checksum", "yt-dlp: ...") so we don't prefix here.
            return msg
        case .checksumMismatch(let exp, let got):
            return "Downloaded binary checksum mismatch.\nExpected: \(exp)\nGot: \(got)"
        }
    }
}
