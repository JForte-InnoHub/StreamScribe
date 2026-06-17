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
                return "No ISVP video player iframe found on senate.gov page: \(u.absoluteString) — the page may not include a hearing video, or senate.gov may have changed its page structure."
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
    /// Performs at most one HTTP fetch (the page itself). The committee
    /// mapping is in-memory. Total latency on a typical broadband connection
    /// is ~300–700 ms, dominated by the page fetch.
    ///
    /// - Throws: `ExtractorError` on any failure. The caller should
    ///   consider falling back to yt-dlp on failure since some hearings
    ///   (typically older or on subdomains we don't have in our mapping)
    ///   work through yt-dlp's broader matching.
    static func resolve(url: URL) async throws -> ResolvedStream {
        // Direct ISVP URL: parse params from the URL itself, skip page fetch.
        if isISVPURL(url) {
            return try resolveFromISVPURL(url, pageTitle: nil)
        }

        // Hearing page: fetch HTML, find the ISVP iframe URL, then resolve.
        guard isSupportedSenateGovHost(url) else {
            throw ExtractorError.notSenateGovURL(url)
        }

        let html: String
        do {
            // 15 s timeout — page fetches normally complete in well under
            // a second on a healthy network. The timeout is for
            // pathological cases (corporate firewall, captive portal,
            // etc.) where the request would otherwise hang indefinitely.
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            // senate.gov occasionally serves slightly different HTML to
            // identified browsers vs default URLSession user-agent. A
            // generic Safari UA keeps us in the "normal browser" path
            // and avoids any 403 edge cases. Not strictly necessary in
            // testing but cheap insurance.
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let s = String(data: data, encoding: .utf8) else {
                throw ExtractorError.pageHTMLNotUTF8(url)
            }
            html = s
        } catch let e as ExtractorError {
            throw e
        } catch {
            throw ExtractorError.pageHTMLFetchFailed(url, underlying: error)
        }

        guard let isvpURL = findISVPURL(in: html) else {
            throw ExtractorError.isvpIframeNotFound(url)
        }

        // Extract the page's <title> for display. Best-effort — if it
        // fails, the stream still resolves with title=nil.
        let pageTitle = extractPageTitle(from: html)
        return try resolveFromISVPURL(isvpURL, pageTitle: pageTitle)
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

    /// Find the senate.gov ISVP iframe URL in a page's HTML. Looks for the
    /// classic pattern `src="https://www.senate.gov/isvp/..."` on iframes,
    /// the same pattern yt-dlp's `SenateGovIE` extractor uses (via
    /// `SenateISVPIE.extract_from_webpage`).
    ///
    /// Some hearing pages may have multiple iframes (the player plus, say,
    /// a Twitter embed) — we take the first match against the senate.gov
    /// ISVP URL pattern, which is reliably the player.
    private static func findISVPURL(in html: String) -> URL? {
        // Pattern: any src="..." (also handles src='...') containing
        // /senate.gov/isvp on either the www. host or the bare apex host.
        //
        // The capture group greedy-matches up to the closing quote.
        // Senate.gov ISVP URLs commonly contain `&`, `?`, `=`, alphanumerics,
        // and slashes — all permitted by the negated-character-class
        // `[^"']*`.
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
            var captured = String(html[captureRange])
            // Decode common HTML entities that appear in HREF values.
            captured = captured
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
            // Iframe src might be protocol-relative (`//www.senate.gov/...`)
            // — promote to https. Or relative — promote to www.senate.gov.
            if captured.hasPrefix("//") {
                captured = "https:" + captured
            } else if captured.hasPrefix("/isvp") {
                captured = "https://www.senate.gov" + captured
            } else if !captured.hasPrefix("http") {
                continue
            }
            if let u = URL(string: captured) {
                return u
            }
        }
        return nil
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
