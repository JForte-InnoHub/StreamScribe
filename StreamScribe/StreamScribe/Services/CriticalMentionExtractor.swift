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
                return "Not a Critical Mention clip URL."
            case .extractionFailed(let reason):
                return "Critical Mention extraction failed: \(reason)"
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

    /// Resolve a `app.criticalmention.com/app/#/clip/public/<uuid>`
    /// page URL to its HLS stream URL. Throws on structural failure
    /// (unrecognized URL shape) or timeout.
    ///
    /// **Public clips only for now.** Private clips would require a
    /// Critical Mention login session that the headless WKWebView
    /// doesn't have. If the URL contains `/clip/private/` or the
    /// extractor times out on a public URL, the error message will
    /// hint at authentication as a likely cause.
    static func resolve(url: URL) async throws -> Resolved {
        // Sanity-check the URL shape before launching WebKit — the
        // WebKit dance costs 3-8 seconds; failing fast on obviously
        // wrong URLs saves the user time.
        guard let host = url.host?.lowercased(),
              host.hasSuffix("criticalmention.com") else {
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
