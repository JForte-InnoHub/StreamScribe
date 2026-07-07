import Foundation

/// Resolves senate.gov hearing-page URLs and ISVP player URLs to their
/// underlying HLS m3u8 URLs, plus extracts a human-readable title from the
/// page. Replaces yt-dlp for senate.gov sources — see
/// `StreamSource.senateGov` and its routing in `AudioStreamExtractor` and
/// `TranscriptionEngine.beginProbe`.
///
/// **Why a dedicated extractor.** Senate.gov hosts hours-long hearings and
/// regulatory testimony on a Player called ISVP ("Integrated Senate Video
/// Player"), embedded as an iframe on every committee subdomain
/// (`help.senate.gov`, `banking.senate.gov`, etc.). The ISVP URL itself has
/// the shape:
///
///     https://www.senate.gov/isvp/?type={live|arch}&comm={committee}&filename={file}&...
///
/// and from those params plus a hardcoded committee → stream-ID table the
/// m3u8 URL is fully derivable. yt-dlp has a ~140-line `senategov` extractor
/// that does the same lookup, but routing through yt-dlp's process spawn,
/// HF Hub cache check, generic-extractor fallback chain, and our own
/// two-stage probe with URL-resolution fallback adds 6–9 seconds vs.
/// ~500 ms for a single URLSession page fetch + regex match.
///
/// **Committee ID mapping.** The 7-digit `stream_id` per committee is the
/// authoritative value from yt-dlp's senategov.py source (commit 68221ec).
/// Senate.gov changes its CDN infrastructure occasionally — when that
/// happens, yt-dlp's source updates faster than we will, so on extractor
/// failure the caller can fall back to yt-dlp (see the routing logic in
/// AudioStreamExtractor and TranscriptionEngine).
///
/// **Fallback URL alternatives.** yt-dlp tries up to four URL shapes per
/// hearing (primary live-srs, msl3archive backup, two legacy formats).
/// We try the primary first since it covers ~all modern content; the
/// fallback list is in `Self.alternativeURLs` for completeness if a future
/// failure points us at a hearing where only an older format works.
enum SenateGovExtractor {

    // MARK: - Public API

    /// Parsed result from resolving a senate.gov URL.
    struct ResolvedStream {
        /// The HLS m3u8 URL ffmpeg can read directly. The primary
        /// `www-senate-gov-media-srs.akamaized.net/hls/live/...` URL —
        /// covers all modern hearings. Older content may need one of
        /// the fallback URL shapes in `alternativeURLs`, but the
        /// caller hits ffmpeg first against this primary; ffmpeg's
        /// "Invalid data found in input" error is the signal to try
        /// fallbacks.
        let m3u8URL: URL

        /// All resolvable m3u8 URL candidates in priority order
        /// (primary first). Provided so the caller can iterate on
        /// ffmpeg failure if the primary returns 404.
        let alternativeURLs: [URL]

        /// True for live streams (`type=live`), false for archived
        /// VOD (`type=arch` or missing — default arch). Used by the
        /// probe path to short-circuit duration detection: live
        /// streams skip the ffmpeg duration probe and go straight
        /// to Live mode.
        let isLive: Bool

        /// Human-readable title from the hearing page's <title> tag
        /// or og:title meta tag. Nil if extracted from an ISVP URL
        /// directly (no page context) or if title parsing failed.
        let title: String?

        /// Committee code (e.g. "help", "banking"). Useful for
        /// logging / display.
        let committee: String

        /// Filename identifier (e.g. "help061726"). Useful for
        /// logging / display.
        let filename: String
    }

    /// Errors the extractor can throw. The caller should generally
    /// catch these and fall back to yt-dlp (the senate.gov yt-dlp
    /// extractor handles edge cases like older URL shapes our
    /// hardcoded mapping doesn't know about).
    enum ExtractorError: LocalizedError {
        case notSenateGovURL(URL)
        case pageHTMLFetchFailed(URL, underlying: Error)
        case pageHTMLNotUTF8(URL)
        case isvpIframeNotFound(URL)
        case isvpURLMalformed(String)
        case missingISVPParams(URL)
        case unknownCommittee(String)
        case m3u8URLConstructionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notSenateGovURL(let u):
                return "URL is not a senate.gov page or ISVP URL: \(u.absoluteString)"
            case .pageHTMLFetchFailed(let u, let e):
                return "Failed to fetch senate.gov page \(u.absoluteString): \(e.localizedDescription)"
            case .pageHTMLNotUTF8(let u):
                return "Senate.gov page returned non-UTF-8 HTML: \(u.absoluteString)"
            case .isvpIframeNotFound(let u):
                return "No m3u8 stream URL found on senate.gov page: \(u.absoluteString) — the page didn't load a stream within 10 s. The hearing may not be live yet, may not have been archived yet, or the page may have failed to load (check network)."
            case .isvpURLMalformed(let s):
                return "ISVP URL on the page is malformed: \(s)"
            case .missingISVPParams(let u):
                return "ISVP URL missing required 'comm' or 'filename' parameter: \(u.absoluteString)"
            case .unknownCommittee(let c):
                return "Unknown senate committee code: '\(c)'. The SenateGovExtractor committee mapping may be out of date — yt-dlp's senategov.py source is the authoritative reference."
            case .m3u8URLConstructionFailed(let s):
                return "Could not construct senate.gov m3u8 URL: \(s)"
            }
        }
    }

    /// Resolve a senate.gov URL (committee hearing page OR direct ISVP
    /// player URL) to its underlying HLS m3u8 stream.
    ///
    /// **Implementation: browser-based.** Uses `SenateGovBrowserExtractor`
    /// which loads the page in an off-screen `WKWebView`, lets the
    /// page's JavaScript run, and captures the m3u8 URL via injected
    /// `fetch`/`XMLHttpRequest`/`HTMLMediaElement.src` interceptors —
    /// the same approach browser extensions like FetchV use, and the
    /// only one that works reliably across senate.gov's mix of
    /// iframe-embedded (older committee sites) and JavaScript-loaded
    /// (newer Bitmovin-based committee sites) players.
    ///
    /// **Direct ISVP shortcut.** If the input URL is itself a
    /// senate.gov/isvp/?... URL (e.g. the user pasted the ISVP iframe
    /// URL directly, or a previous probe returned one), we skip the
    /// browser entirely and use the committee-mapping path to
    /// construct the m3u8. Faster (~50 ms vs ~2-3 s) and the result
    /// is identical for the ISVP-style cases.
    ///
    /// **Latency.** ~2-3 s for the WKWebView path on a healthy network
    /// (page load + JS execution + first m3u8 request). The old HTML
    /// scraping path was faster (~500 ms) but kept missing JS-loaded
    /// URLs; reliability wins over speed here.
    ///
    /// - Throws: `ExtractorError.isvpIframeNotFound` if no m3u8 URL is
    ///   observed within 10 s. Other error cases (notSenateGovURL,
    ///   etc.) only apply to the direct-ISVP shortcut path.
    static func resolve(url: URL) async throws -> ResolvedStream {
        // Direct ISVP URL: parse params from the URL itself, skip the
        // browser entirely. Faster than WKWebView and the committee
        // mapping is reliable for these well-structured URLs.
        if isISVPURL(url) {
            return try resolveFromISVPURL(url, pageTitle: nil)
        }

        // Reject non-senate.gov URLs up front.
        guard isSupportedSenateGovHost(url) else {
            throw ExtractorError.notSenateGovURL(url)
        }

        // Browser-based extraction. WKWebView loads the page, runs its
        // JavaScript, and our injected shim reports the m3u8 URL the
        // moment the player initialization tries to load it. The result
        // also carries the page <title> for display.
        guard let extraction = await SenateGovBrowserExtractor.resolve(pageURL: url) else {
            throw ExtractorError.isvpIframeNotFound(url)
        }

        let m3u8URL = extraction.m3u8URL

        // Best-effort parse of comm + filename from the m3u8 path for
        // logging / display metadata. URL shape:
        //   /hls/live/<stream_id>/<comm>/<filename>/master.m3u8
        var committee = ""
        var filename = ""
        let parts = m3u8URL.pathComponents
        if let liveIdx = parts.firstIndex(of: "live"), parts.count > liveIdx + 3 {
            committee = parts[liveIdx + 2]
            filename = parts[liveIdx + 3]
        }

        return ResolvedStream(
            m3u8URL: m3u8URL,
            alternativeURLs: [m3u8URL],
            isLive: false,  // ffmpeg probe determines this downstream
            title: extraction.pageTitle,
            committee: committee,
            filename: filename
        )
    }

    // MARK: - Committee mapping

    /// `(stream_num, stream_domain, stream_id, msl3_segment)` per committee
    /// code. Mirrors yt-dlp's senategov.py `_COMMITTEES` dict verbatim
    /// (commit 68221ec). The `stream_id` is the value used in the primary
    /// modern URL shape; the other tuple members are for legacy URL
    /// fallbacks.
    ///
    /// **If senate.gov adds a new committee or changes IDs**, update this
    /// table from yt-dlp's source. Or — simpler — catch the
    /// `unknownCommittee` error in routing and fall back to yt-dlp, which
    /// updates faster than we do.
    private struct CommitteeRecord {
        let streamNum: String
        let streamDomain: String
        let streamID: String      // 7-digit MSL3 stream ID, or empty
        let msl3Segment: String   // archive segment name
    }

    private static let committees: [String: CommitteeRecord] = [
        "ag":        .init(streamNum: "76440", streamDomain: "https://ag-f.akamaihd.net",        streamID: "2036803", msl3Segment: "agriculture"),
        "aging":     .init(streamNum: "76442", streamDomain: "https://aging-f.akamaihd.net",     streamID: "2036801", msl3Segment: "aging"),
        "approps":   .init(streamNum: "76441", streamDomain: "https://approps-f.akamaihd.net",   streamID: "2036802", msl3Segment: "appropriations"),
        "arch":      .init(streamNum: "",      streamDomain: "https://ussenate-f.akamaihd.net",  streamID: "",        msl3Segment: "arch"),
        "armed":     .init(streamNum: "76445", streamDomain: "https://armed-f.akamaihd.net",     streamID: "2036800", msl3Segment: "armedservices"),
        "banking":   .init(streamNum: "76446", streamDomain: "https://banking-f.akamaihd.net",   streamID: "2036799", msl3Segment: "banking"),
        "budget":    .init(streamNum: "76447", streamDomain: "https://budget-f.akamaihd.net",    streamID: "2036798", msl3Segment: "budget"),
        "cecc":      .init(streamNum: "76486", streamDomain: "https://srs-f.akamaihd.net",       streamID: "2036782", msl3Segment: "srs_cecc"),
        "commerce":  .init(streamNum: "80177", streamDomain: "https://commerce1-f.akamaihd.net", streamID: "2036779", msl3Segment: "commerce"),
        "csce":      .init(streamNum: "75229", streamDomain: "https://srs-f.akamaihd.net",       streamID: "2036777", msl3Segment: "srs_srs"),
        "dpc":       .init(streamNum: "76590", streamDomain: "https://dpc-f.akamaihd.net",       streamID: "",        msl3Segment: "dpc"),
        "energy":    .init(streamNum: "76448", streamDomain: "https://energy-f.akamaihd.net",    streamID: "2036797", msl3Segment: "energy"),
        "epw":       .init(streamNum: "76478", streamDomain: "https://epw-f.akamaihd.net",       streamID: "2036783", msl3Segment: "environment"),
        "ethics":    .init(streamNum: "76449", streamDomain: "https://ethics-f.akamaihd.net",    streamID: "2036796", msl3Segment: "ethics"),
        "finance":   .init(streamNum: "76450", streamDomain: "https://finance-f.akamaihd.net",   streamID: "2036795", msl3Segment: "finance_finance"),
        "foreign":   .init(streamNum: "76451", streamDomain: "https://foreign-f.akamaihd.net",   streamID: "2036794", msl3Segment: "foreignrelations"),
        "govtaff":   .init(streamNum: "76453", streamDomain: "https://govtaff-f.akamaihd.net",   streamID: "2036792", msl3Segment: "hsgac"),
        "help":      .init(streamNum: "76452", streamDomain: "https://help-f.akamaihd.net",      streamID: "2036793", msl3Segment: "help"),
        "indian":    .init(streamNum: "76455", streamDomain: "https://indian-f.akamaihd.net",    streamID: "2036791", msl3Segment: "indianaffairs"),
        "intel":     .init(streamNum: "76456", streamDomain: "https://intel-f.akamaihd.net",     streamID: "2036790", msl3Segment: "intelligence"),
        "intlnarc":  .init(streamNum: "76457", streamDomain: "https://intlnarc-f.akamaihd.net",  streamID: "",        msl3Segment: "internationalnarcoticscaucus"),
        "jccic":     .init(streamNum: "85180", streamDomain: "https://jccic-f.akamaihd.net",     streamID: "2036778", msl3Segment: "jccic"),
        "jec":       .init(streamNum: "76458", streamDomain: "https://jec-f.akamaihd.net",       streamID: "2036789", msl3Segment: "jointeconomic"),
        "judiciary": .init(streamNum: "76459", streamDomain: "https://judiciary-f.akamaihd.net", streamID: "2036788", msl3Segment: "judiciary"),
        "rpc":       .init(streamNum: "76591", streamDomain: "https://rpc-f.akamaihd.net",       streamID: "",        msl3Segment: "rpc"),
        "rules":     .init(streamNum: "76460", streamDomain: "https://rules-f.akamaihd.net",     streamID: "2036787", msl3Segment: "rules"),
        "saa":       .init(streamNum: "76489", streamDomain: "https://srs-f.akamaihd.net",       streamID: "2036780", msl3Segment: "srs_saa"),
        "smbiz":     .init(streamNum: "76461", streamDomain: "https://smbiz-f.akamaihd.net",     streamID: "2036786", msl3Segment: "smallbusiness"),
        "srs":       .init(streamNum: "75229", streamDomain: "https://srs-f.akamaihd.net",       streamID: "2031966", msl3Segment: "srs_srs"),
        "uscc":      .init(streamNum: "76487", streamDomain: "https://srs-f.akamaihd.net",       streamID: "2036781", msl3Segment: "srs_uscc"),
        "vetaff":    .init(streamNum: "76462", streamDomain: "https://vetaff-f.akamaihd.net",    streamID: "2036785", msl3Segment: "veteransaffairs"),
    ]

    // MARK: - URL classification

    private static func isISVPURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return (host == "www.senate.gov" || host == "senate.gov") && url.path.hasPrefix("/isvp")
    }

    private static func isSupportedSenateGovHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.hasSuffix(".senate.gov")
    }

    // MARK: - ISVP URL parsing & m3u8 construction

    private static func resolveFromISVPURL(_ isvpURL: URL, pageTitle: String?) throws -> ResolvedStream {
        guard let components = URLComponents(url: isvpURL, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            throw ExtractorError.isvpURLMalformed(isvpURL.absoluteString)
        }

        // Build a lookup of query params. ISVP URLs occasionally have
        // duplicate keys (e.g. `comm` appearing twice); take the LAST
        // occurrence as yt-dlp does — that's the most-recently-set value
        // in HTML form encoding.
        var params: [String: String] = [:]
        for item in queryItems {
            if let value = item.value {
                params[item.name.lowercased()] = value
            }
        }

        guard let comm = params["comm"]?.lowercased(),
              let filenameRaw = params["filename"] else {
            throw ExtractorError.missingISVPParams(isvpURL)
        }
        // Strip a trailing `.mp4` extension if present — the ISVP URL
        // sometimes includes it (`commerce011514.mp4`) but the m3u8
        // URL shape uses the bare ID. Matches yt-dlp's `remove_end`.
        let filename = filenameRaw.hasSuffix(".mp4")
            ? String(filenameRaw.dropLast(".mp4".count))
            : filenameRaw

        // `type=live` → live stream, otherwise archived VOD. Default to
        // arch when missing (matches the post-2024 yt-dlp behavior of
        // making `type` optional).
        let typeValue = params["type"]?.lowercased() ?? "arch"
        let isLive = (typeValue == "live")

        guard let record = committees[comm] else {
            throw ExtractorError.unknownCommittee(comm)
        }

        // Construct all four URL alternatives in yt-dlp's priority order.
        // Primary covers ~all modern content. Fallbacks added for parity
        // — older content occasionally needs them.
        var alternatives: [URL] = []

        // 1. Modern primary: media-srs CDN with stream ID. Used for both
        //    live and archive (the path says `/hls/live/` but is also the
        //    archive location post-2023).
        if !record.streamID.isEmpty {
            let primary = "https://www-senate-gov-media-srs.akamaized.net/hls/live/\(record.streamID)/\(comm)/\(filename)/master.m3u8"
            if let u = URL(string: primary) { alternatives.append(u) }
        }

        // 2. msl3archive CDN backup. Empirically rarely needed in 2025
        //    but kept for older archives.
        let backup = "https://www-senate-gov-msl3archive.akamaized.net/\(record.msl3Segment)/\(filename)_1/master.m3u8"
        if let u = URL(string: backup) { alternatives.append(u) }

        // 3. Legacy live URL shape (akamaihd domain, with stream num).
        if !record.streamNum.isEmpty {
            let legacyLive = "\(record.streamDomain)/i/\(filename)_1@\(record.streamNum)/master.m3u8"
            if let u = URL(string: legacyLive) { alternatives.append(u) }
        }

        // 4. Legacy archive URL shape (akamaihd domain, .mp4 suffix).
        let legacyArch = "\(record.streamDomain)/i/\(filename).mp4/master.m3u8"
        if let u = URL(string: legacyArch) { alternatives.append(u) }

        guard let primary = alternatives.first else {
            throw ExtractorError.m3u8URLConstructionFailed("No valid URLs constructed for committee '\(comm)'.")
        }

        return ResolvedStream(
            m3u8URL: primary,
            alternativeURLs: alternatives,
            isLive: isLive,
            title: pageTitle,
            committee: comm,
            filename: filename
        )
    }

    // MARK: - HTML parsing

    /// Find the senate.gov ISVP player URL in a page's HTML. Tries three
    /// progressively-broader strategies:
    ///
    /// 1. **Iframe `src=` match.** The classic embed pattern used by older
    ///    committee sites (banking, help, judiciary, etc.). Matches what
    ///    yt-dlp's `SenateGovIE` extractor does via
    ///    `SenateISVPIE.extract_from_webpage`. Catches the vast majority
    ///    of hearings.
    ///
    /// 2. **Free-form URL search.** Newer committee sites (Elementor /
    ///    WordPress builds) put the URL in `<a href>` popup launchers
    ///    or `data-*` attributes. Look for any `senate.gov/isvp?...` URL
    ///    anywhere in the HTML. **Crucially**, validates that the captured
    ///    URL doesn't have placeholder query values like `comm=commcode`
    ///    — some templates appear on the page in unsubstituted form with
    ///    real values injected at JS runtime, and a placeholder URL
    ///    can't be resolved to a real stream.
    ///
    /// 3. **Data extraction.** When strategies 1+2 fail (or only find
    ///    placeholders), look directly for `comm=<value>` and
    ///    `filename=<value>` as separate data attributes or JS variable
    ///    assignments, then construct the ISVP URL from those values.
    ///    Handles Elementor-style pages where the player widget exposes
    ///    its config as `data-comm="govtaff" data-filename="govtaff062326"`
    ///    on a container element.
    ///
    /// **Hard limit.** If the page constructs the ISVP URL purely from
    /// runtime JavaScript with no full URL string AND no data attributes
    /// or variable assignments visible in the static HTML, all three
    /// strategies fail. User workaround: open Network tab in browser,
    /// find the m3u8 URL, paste THAT into StreamScribe (auto-detects
    /// as `.hls`).
    private static func findISVPURL(in html: String) -> URL? {
        // Strategy 1: iframe src=. Fast-path for the common case.
        if let u = findISVPURLViaIframeSrc(in: html), !urlHasPlaceholders(u) {
            return u
        }
        // Strategy 2: free-form URL search across the whole HTML.
        if let u = findISVPURLViaFreeFormSearch(in: html), !urlHasPlaceholders(u) {
            return u
        }
        // Strategy 3: extract comm + filename from data attributes or
        // JS variable assignments, build the URL ourselves.
        return findISVPURLViaDataExtraction(in: html)
    }

    /// Iframe-`src=` strategy. The original pattern, kept verbatim
    /// behind a helper method so the new strategies stay separable.
    private static func findISVPURLViaIframeSrc(in html: String) -> URL? {
        let patterns = [
            #"src=["']([^"']*senate\.gov/isvp[^"']*)["']"#,
            #"src=["']([^"']*//(?:www\.)?senate\.gov/isvp[^"']*)["']"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            guard let match = regex.firstMatch(in: html, options: [], range: range),
                  match.numberOfRanges >= 2,
                  let captureRange = Range(match.range(at: 1), in: html) else {
                continue
            }
            if let u = normalizeAndDecode(String(html[captureRange])) {
                return u
            }
        }
        return nil
    }

    /// Free-form-URL strategy. Looks for any `senate.gov/isvp?...` URL
    /// anywhere in the HTML, regardless of HTML context. Returns the
    /// first match; the caller's placeholder check decides whether to
    /// accept it.
    private static func findISVPURLViaFreeFormSearch(in html: String) -> URL? {
        let pattern = #"https?://(?:www\.)?senate\.gov/isvp/?\?[^\s"'<>\\]+?(?=["'<>\s\\]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              let captureRange = Range(match.range, in: html) else {
            return nil
        }
        return normalizeAndDecode(String(html[captureRange]))
    }

    /// Data-extraction strategy. When the page embeds the player as
    /// a custom widget with config in data attributes or JS variables,
    /// the comm code + filename appear separately rather than as a
    /// full ISVP URL. Reconstruct the URL from those values.
    ///
    /// Patterns tried for each value, in order:
    ///   - `data-comm="govtaff"` / `data-filename="..."` (HTML attribute)
    ///   - `"comm":"govtaff"` / `"filename":"..."` (JSON config)
    ///   - `comm="govtaff"` / `filename="..."` (JS variable assignment)
    ///   - `comm=govtaff&filename=...` (unquoted query-string fragment)
    ///
    /// Each pattern's match is validated against `isPlaceholder` so
    /// the literal template values (`commcode`, `filename` as a value,
    /// `{{comm}}`, etc.) don't pollute the result.
    ///
    /// Type (live vs archived) defaults to arch when not found. If the
    /// page indicates live in any of the same patterns, use that. Live
    /// hearings still resolve to a playable m3u8 — the only place this
    /// matters is the `isLive` flag we return downstream.
    private static func findISVPURLViaDataExtraction(in html: String) -> URL? {
        let commPatterns = [
            #"data-comm=["']([a-z_]+)["']"#,
            #"["']comm["']\s*:\s*["']([a-z_]+)["']"#,
            #"\bcomm\s*=\s*["']([a-z_]+)["']"#,
            #"[?&]comm=([a-z_]+)(?:&|"|'|\s|$)"#,
        ]
        let filenamePatterns = [
            #"data-filename=["']([a-z0-9_]+)["']"#,
            #"["']filename["']\s*:\s*["']([a-z0-9_]+)["']"#,
            #"\bfilename\s*=\s*["']([a-z0-9_]+)["']"#,
            #"[?&]filename=([a-z0-9_]+)(?:&|"|'|\s|$)"#,
        ]
        let typePatterns = [
            #"data-type=["'](live|arch)["']"#,
            #"["']type["']\s*:\s*["'](live|arch)["']"#,
            #"[?&]type=(live|arch)(?:&|"|'|\s|$)"#,
        ]

        guard let comm = firstNonPlaceholderMatch(in: html, patterns: commPatterns) else {
            return nil
        }
        guard let filename = firstNonPlaceholderMatch(in: html, patterns: filenamePatterns) else {
            return nil
        }
        let type = firstNonPlaceholderMatch(in: html, patterns: typePatterns) ?? "arch"

        let urlString = "https://www.senate.gov/isvp/?type=\(type)&comm=\(comm)&filename=\(filename)"
        return URL(string: urlString)
    }

    /// Iterate `patterns` and return the first capture that isn't a
    /// placeholder. Each pattern is tried with case-insensitive matching.
    private static func firstNonPlaceholderMatch(in text: String, patterns: [String]) -> String? {
        for pattern in patterns {
            if let captured = matchFirstCapture(in: text, pattern: pattern), !isPlaceholder(captured) {
                return captured
            }
        }
        return nil
    }

    /// Find an m3u8 URL embedded directly in the page HTML. Used for
    /// committee sites that wrap playback in JavaScript players
    /// (Bitmovin, Video.js, etc.) rather than the classic ISVP iframe.
    /// Bitmovin specifically embeds its config as a JS object like
    /// `{source: {hls: "https://www-senate-gov-media-srs.akamaized.net/.../master.m3u8"}}`
    /// which is plain-text findable in the source.
    ///
    /// Matches any URL on senate.gov's known CDN hosts
    /// (`akamaized.net` for the modern senate CDN,
    /// `akamaihd.net` for legacy committee streams) that ends in
    /// `.m3u8`. Handles JSON-escaped forward slashes (`\/`) which
    /// appear when the config is embedded inside a JSON string.
    ///
    /// Returns the first match — Bitmovin configs typically have one
    /// `hls` entry that points at the master playlist; multi-bitrate
    /// alternatives live inside the playlist itself, not as separate
    /// page-level URLs.
    private static func findDirectM3U8URL(in html: String) -> URL? {
        let pattern = #"https?:(?:\\?/\\?/)[a-z0-9.-]*(?:akamaized\.net|akamaihd\.net)[^"'\s<>\\]*?\.m3u8"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              let captureRange = Range(match.range, in: html) else {
            return nil
        }
        // Unescape JSON-style escaped slashes — common in embedded
        // config objects: `"hls":"https:\/\/host\/path\/master.m3u8"`.
        let raw = String(html[captureRange])
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")
        return URL(string: raw)
    }

    /// Build a `ResolvedStream` from a direct m3u8 URL found on the page,
    /// when the ISVP-resolution path didn't yield a usable URL. Best-effort
    /// parses comm/filename from the URL path for the returned metadata,
    /// but the m3u8 URL itself is what matters for playback — even if
    /// path parsing produces empty strings, the stream still plays.
    ///
    /// **Why isLive defaults to false:** the senate.gov URL path uses
    /// `/hls/live/...` for both live AND archived content, so the path
    /// alone can't distinguish. Setting `isLive=false` makes the probe
    /// fall through to `probeRemoteDurationViaFFmpeg`, which correctly
    /// detects live streams (finite duration → static; missing duration
    /// or unbounded playlist → live). Slightly slower probe than a
    /// live-known-up-front result but the right answer regardless.
    private static func resolveFromDirectM3U8(_ m3u8URL: URL, pageTitle: String?) -> ResolvedStream {
        // Parse `/hls/live/<stream_id>/<comm>/<filename>/master.m3u8`
        // path for metadata. If the path format diverges, the parse
        // yields empty strings — log-quality cosmetics only, doesn't
        // affect playback.
        var committee = ""
        var filename = ""
        let parts = m3u8URL.pathComponents
        if let liveIdx = parts.firstIndex(of: "live"), parts.count > liveIdx + 3 {
            committee = parts[liveIdx + 2]
            filename = parts[liveIdx + 3]
        }
        return ResolvedStream(
            m3u8URL: m3u8URL,
            alternativeURLs: [m3u8URL],
            isLive: false,
            title: pageTitle,
            committee: committee,
            filename: filename
        )
    }

    /// True if `value` looks like an unsubstituted template placeholder
    /// rather than a real committee code or filename. Catches the common
    /// patterns: literal "commcode" / "filename" as values (Elementor
    /// puts these in templates), `{{...}}` Mustache-style placeholders,
    /// `$...` shell-style placeholders, and the JS-variable style
    /// where the parameter NAME ends up where its VALUE should be.
    private static func isPlaceholder(_ value: String) -> Bool {
        let v = value.lowercased()
        // Mustache-style {{var}}: require both opening and closing braces
        // so we don't false-positive on values that happen to start with
        // two open-brace characters but aren't templates.
        if v.hasPrefix("{{") && v.hasSuffix("}}") { return true }
        if v.hasPrefix("$") || v.hasPrefix("%") { return true }
        // The literal parameter names appearing as values — definitive
        // template-not-filled-in signal. The senate.gov ISVP URLs use
        // these exact parameter names so the inversion is unambiguous.
        return v == "commcode" || v == "comm" || v == "filename"
            || v == "type" || v == "stream_id" || v == "streamid"
    }

    /// True if any of the URL's query parameters contains a placeholder
    /// value. Used by the caller to reject template URLs found by
    /// strategy 1 or 2 in favor of falling through to strategy 3.
    private static func urlHasPlaceholders(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            return false
        }
        return items.contains { item in
            if let v = item.value { return isPlaceholder(v) }
            return false
        }
    }

    /// Decode HTML entities and normalize a captured ISVP URL string
    /// into a `URL`. Handles `&amp;`, `&quot;`, `&#39;`, plus
    /// protocol-relative (`//www.senate.gov/...`) and root-relative
    /// (`/isvp/...`) forms.
    private static func normalizeAndDecode(_ captured: String) -> URL? {
        var s = captured
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        if s.hasPrefix("//") {
            s = "https:" + s
        } else if s.hasPrefix("/isvp") {
            s = "https://www.senate.gov" + s
        } else if !s.hasPrefix("http") {
            return nil
        }
        return URL(string: s)
    }

    /// Extract the page <title>. Tries the og:title meta tag first (it's
    /// usually cleaner — committee pages tend to put the verbose
    /// "| Committee Name | senate.gov" tail in <title> but not og:title),
    /// then falls back to the plain <title>.
    ///
    /// Returns nil if neither is found. Caller treats nil as "no title
    /// available" — the rest of the pipeline already handles a nil title.
    private static func extractPageTitle(from html: String) -> String? {
        // og:title is the preferred source.
        if let og = matchFirstCapture(in: html, pattern: #"<meta\s+[^>]*property=["']og:title["']\s+[^>]*content=["']([^"']+)["']"#) {
            return og.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let og = matchFirstCapture(in: html, pattern: #"<meta\s+[^>]*content=["']([^"']+)["']\s+[^>]*property=["']og:title["']"#) {
            return og.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // <title> fallback. Strip the verbose "| Committee Name | senate.gov"
        // tail — anything from the first " | " onward is structural noise.
        if let title = matchFirstCapture(in: html, pattern: #"<title[^>]*>([^<]+)</title>"#) {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let pipeRange = trimmed.range(of: " | ") {
                return String(trimmed[trimmed.startIndex..<pipeRange.lowerBound])
            }
            return trimmed
        }
        return nil
    }

    private static func matchFirstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }
}
