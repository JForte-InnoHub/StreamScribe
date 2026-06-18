import Foundation
import SwiftUI
import AppKit

/// Lightweight GitHub-Releases-backed update checker. Polls
/// `JForte-InnoHub/StreamScribe` once per app launch (subject to a 24-hour
/// throttle) and surfaces newer releases via a SwiftUI alert wired up in
/// `StreamScribeApp`.
///
/// **Why GitHub Releases (not Sparkle).** Sparkle is the gold-standard Mac
/// auto-updater but adds significant complexity: EdDSA signing keys for
/// each release, an `appcast.xml` feed, build-script integration, and
/// edge-case handling for in-place replacement when the app's install
/// location varies (some users in ~/Applications, some in ~/Downloads, some
/// in /Applications without admin). This checker covers most of the
/// user-experience win — users know when updates exist and can act on
/// them — at a fraction of the implementation cost. We can revisit Sparkle
/// if there's actual user demand for silent auto-updates.
///
/// **Throttling and persistence.** Last-check timestamp is stored in
/// UserDefaults so the 24h gate survives app restarts. Manual "Check for
/// Updates" in Settings bypasses the gate (and the skip-version filter).
/// Skip-version state lets a user dismiss a particular release without
/// being re-prompted on every launch.
///
/// **Version comparison.** Uses `compare(_:options: .numeric)` which
/// handles the "1.10.0 > 1.9.0" case that simple string comparison gets
/// wrong. Sufficient for standard semantic versions; doesn't handle
/// pre-release suffixes (e.g. "1.0.0-beta") specially, but we're not
/// shipping pre-releases via this channel.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    // MARK: - Configuration

    private static let repoOwner = "JForte-InnoHub"
    private static let repoName = "StreamScribe"
    private static let checkIntervalHours: Double = 24

    private static let lastCheckKey = "updateChecker.lastCheckDate"
    private static let skippedVersionKey = "updateChecker.skippedVersion"

    // MARK: - Published state

    /// The latest release found, if it's newer than the running version
    /// and not skipped. Nil when up-to-date, after a skip, or after the
    /// alert is dismissed. The app's `.alert` modifier observes this and
    /// shows the update dialog whenever it transitions to non-nil.
    @Published var updateAvailable: Release?

    /// True while a check is in flight. Used by Settings to disable the
    /// Check button and show a spinner during the network round-trip.
    @Published var isChecking: Bool = false

    /// Last network/parse error, surfaced in the Settings UI under the
    /// Check button if non-nil. Cleared at the start of each check.
    @Published var lastCheckError: String?

    // MARK: - Public API

    /// Currently-running version, read from the bundle Info.plist.
    /// Falls back to "0.0.0" if the key is missing (which it shouldn't
    /// be for a properly-configured app — that's a project misconfiguration).
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Check on app launch. No-ops if the last check was less than
    /// `checkIntervalHours` ago — keeps the GitHub API call out of the
    /// hot launch path on subsequent same-day launches.
    func checkOnLaunchIfDue() async {
        if let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date {
            let hoursSinceLastCheck = Date().timeIntervalSince(last) / 3600.0
            if hoursSinceLastCheck < Self.checkIntervalHours {
                return
            }
        }
        await check(force: false)
    }

    /// Manual "Check for Updates" from Settings. Always runs, ignores
    /// both the 24h throttle and any skip-version state — the user is
    /// explicitly asking, so they want a definitive answer.
    func checkNow() async {
        await check(force: true)
    }

    /// Persist a "don't bother me about this version again" preference.
    /// Cleared automatically when a newer release than the skipped one
    /// appears (the comparison in `check` looks at the running version,
    /// not the skipped one — but the skip filter only matches an exact
    /// version string, so any newer release passes through).
    func skipVersion(_ version: String) {
        UserDefaults.standard.set(version, forKey: Self.skippedVersionKey)
        updateAvailable = nil
    }

    /// Dismiss the alert without skipping the version. Re-shows on the
    /// next 24h check if the update is still available.
    func dismissAlert() {
        updateAvailable = nil
    }

    // MARK: - Internal

    private init() {}

    private func check(force: Bool) async {
        isChecking = true
        lastCheckError = nil
        defer { isChecking = false }

        // Update the "last checked" timestamp regardless of outcome —
        // if we fail (network down, GitHub down), we still wait a day
        // before retrying so we don't hammer the API on a broken
        // network. The Settings button gives users an out-of-band
        // way to retry sooner.
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

        let release: Release
        do {
            release = try await fetchLatestRelease()
        } catch {
            print("[UpdateChecker] check failed: \(error.localizedDescription)")
            lastCheckError = error.localizedDescription
            updateAvailable = nil
            return
        }

        // Skip-version filter — only honored for automatic launch checks,
        // not manual "Check for Updates" requests.
        if !force,
           let skipped = UserDefaults.standard.string(forKey: Self.skippedVersionKey),
           skipped == release.version {
            updateAvailable = nil
            return
        }

        if Self.compareVersions(currentVersion, release.version) == .orderedAscending {
            print("[UpdateChecker] update available: \(currentVersion) → \(release.version)")
            updateAvailable = release
        } else {
            print("[UpdateChecker] up-to-date (running \(currentVersion), latest \(release.version))")
            updateAvailable = nil
        }
    }

    /// Fetch the latest release from GitHub's API. Public repo so no auth
    /// is required; we still set the standard `Accept` and API version
    /// headers GitHub recommends.
    private func fetchLatestRelease() async throws -> Release {
        let urlString = "https://api.github.com/repos/\(Self.repoOwner)/\(Self.repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            throw UpdateError.invalidURL
        }

        var request = URLRequest(url: url)
        // 15 s timeout — page fetches typically complete in well under
        // a second. The timeout is for pathological cases (corporate
        // firewall, captive portal) where the request would otherwise
        // hang indefinitely and prolong app launch.
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }
        if http.statusCode == 404 {
            throw UpdateError.noReleasesPublished
        }
        if http.statusCode != 200 {
            throw UpdateError.httpStatus(http.statusCode)
        }

        let decoded: GitHubReleaseJSON
        do {
            decoded = try JSONDecoder().decode(GitHubReleaseJSON.self, from: data)
        } catch {
            throw UpdateError.parseError(error.localizedDescription)
        }

        // Strip a leading "v" if present so version comparison works
        // against the bundle short version string (which is just digits).
        let version = decoded.tag_name.hasPrefix("v")
            ? String(decoded.tag_name.dropFirst())
            : decoded.tag_name

        // Find the DMG asset for a direct download URL, if present.
        // Not strictly required since we open the release page anyway,
        // but kept for completeness — could be used in a future "Download
        // in-app" flow that doesn't bounce through the browser.
        let dmgAsset = decoded.assets.first { $0.name.hasSuffix(".dmg") }
        let downloadURL = dmgAsset.flatMap { URL(string: $0.browser_download_url) }

        guard let pageURL = URL(string: decoded.html_url) else {
            throw UpdateError.invalidResponse
        }

        let publishedDate: Date? = decoded.published_at.flatMap {
            ISO8601DateFormatter().date(from: $0)
        }

        return Release(
            version: version,
            tagName: decoded.tag_name,
            pageURL: pageURL,
            downloadURL: downloadURL,
            body: decoded.body ?? "",
            publishedAt: publishedDate
        )
    }

    /// Compare two version strings using numeric collation so that
    /// "1.10.0" sorts above "1.9.0" rather than below it (which is
    /// what default string comparison would do — "1.1" < "1.9" < "1.10"
    /// lexicographically gives the wrong answer for the last pair).
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        return a.compare(b, options: .numeric)
    }

    // MARK: - Nested types

    /// A GitHub release in the shape this checker cares about. The
    /// `pageURL` is the human-facing release page (the "Download" button
    /// opens this); the optional `downloadURL` is the direct DMG link
    /// if the release has one attached.
    struct Release: Equatable, Identifiable {
        let version: String          // "1.2.3" — leading "v" stripped
        let tagName: String          // "v1.2.3" — original tag
        let pageURL: URL             // https://github.com/.../releases/tag/v1.2.3
        let downloadURL: URL?        // Direct DMG link if available
        let body: String             // Release notes (Markdown)
        let publishedAt: Date?

        var id: String { tagName }
    }

    private struct GitHubReleaseJSON: Decodable {
        let tag_name: String
        let html_url: String
        let body: String?
        let published_at: String?
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
    }

    enum UpdateError: LocalizedError {
        case invalidURL
        case invalidResponse
        case noReleasesPublished
        case httpStatus(Int)
        case parseError(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Update check URL is malformed."
            case .invalidResponse:
                return "GitHub returned an unexpected response."
            case .noReleasesPublished:
                return "No published releases found on GitHub yet."
            case .httpStatus(let code):
                return "GitHub returned HTTP \(code) — try again later."
            case .parseError(let detail):
                return "Couldn't parse GitHub's response: \(detail)"
            }
        }
    }
}
