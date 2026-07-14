import Foundation

/// Public interface for resolving Critical Mention clip page URLs to
/// their HLS stream URLs. Mirrors `SenateGovExtractor`'s role for
/// senate.gov — a thin wrapper over the browser-based extractor with
/// error handling and a stable result type.
///
/// Callers should use this rather than instantiating
/// `CriticalMentionBrowserExtractor` directly. The wrapper isolates
/// pipeline code from the WebKit dependency and gives a place to
/// hang future non-browser extraction paths (an HTTP-only path, if
/// one becomes feasible) without changing the calling sites.
enum CriticalMentionExtractor {

    /// Errors surfaced when extraction fails outright. Only reported
    /// for actionable failures — timeouts and page errors return nil
    /// via the browser extractor and become `.extractionFailed`.
    enum ExtractorError: LocalizedError {
        case invalidURL
        case extractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Not a supported player-page URL (Critical Mention or Granicus)."
            case .extractionFailed(let reason):
                return "Stream extraction failed: \(reason)"
            }
        }
    }

    /// Result of a resolve call. `m3u8URL` is the signed stream URL
    /// (usually short-lived — hours, not days), and `title` is the
    /// clip's page title if available.
    ///
    /// **Field name matches the senate.gov extractor's for symmetry**
    /// even though Critical Mention's URLs don't have `.m3u8` in the
    /// path — the field represents "the URL that speaks HLS," not
    /// "the URL literally containing .m3u8."
    struct Resolved {
        let m3u8URL: URL
        let title: String?
    }

    /// Resolve a browser-extracted page URL to its HLS stream URL.
    /// Accepts Critical Mention clip pages
    /// (`app.criticalmention.com/app/#/clip/public/<uuid>`) and
    /// Granicus player pages (`*.granicus.com/player/…`,
    /// `…/MediaPlayer.php…`) — both are JS players whose real m3u8
    /// only appears in network traffic, which the shared
    /// WKWebView sniffer captures. Throws on structural failure
    /// (unrecognized host) or timeout.
    ///
    /// **Public content only for now.** Private CM clips would
    /// require a login session the headless WKWebView doesn't have.
    static func resolve(url: URL) async throws -> Resolved {
        // Sanity-check the host before launching WebKit — the
        // WebKit dance costs 3-8 seconds; failing fast on obviously
        // wrong URLs saves the user time. Kept in sync with the
        // hosts `StreamSource.detect` routes to this extractor.
        guard let host = url.host?.lowercased(),
              host.hasSuffix("criticalmention.com")
                || host == "granicus.com"
                || host.hasSuffix(".granicus.com") else {
            throw ExtractorError.invalidURL
        }

        guard let extraction = await CriticalMentionBrowserExtractor.resolve(pageURL: url) else {
            throw ExtractorError.extractionFailed(
                "no stream URL observed within timeout. The clip may be private (requiring login), the page may have failed to load, or Critical Mention may have changed their page structure."
            )
        }

        return Resolved(
            m3u8URL: extraction.streamURL,
            title: extraction.pageTitle
        )
    }
}
