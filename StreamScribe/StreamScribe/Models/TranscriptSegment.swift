import Foundation

/// Where this segment sits in the multi-pass refinement lifecycle.
///
/// Background: in live mode (with the multi-pass pipeline enabled — see
/// `MULTI_PASS_DESIGN.md`), small low-latency chunks are transcribed and
/// diarized first (the "raw" pass), then replaced wholesale when a larger
/// 30s rolling window produces higher-quality output (the "refined" pass).
/// Each segment carries its state through this lifecycle so the UI can
/// render it differently (subtle opacity + dot indicator for raw/pending)
/// without changing layout or competing for attention.
///
/// Default at the model level is `.refined` so that:
///   - Static mode is unaffected (its output is always the final pass).
///   - Single-pass live mode (today's behavior, used when refinement is
///     not enabled) renders identically to before.
///   - Only the multi-pass live pipeline explicitly stamps `.raw` and
///     transitions through `.pending` to `.refined`.
///
/// `Codable` so it survives JSON export; `String`-backed so the export
/// is human-readable rather than a numeric enum case.
enum SegmentRefinementState: String, Codable, Equatable {
    /// Emitted by the raw pass (Parakeet + Sortformer on small chunks).
    /// Not yet refined. UI renders these at slightly reduced opacity with
    /// a small "live" dot indicator.
    case raw

    /// Raw output exists, refinement is in progress for this range. UI
    /// renders as raw but with the dot pulsing — communicates "an update
    /// is coming." A segment in this state has not yet been replaced; the
    /// refined output will arrive via `replaceSegments(in:with:)`.
    case pending

    /// Either emitted directly by the refined pass (Whisper + SpeakerKit
    /// on a 30s window) or — for static mode and single-pass live mode —
    /// the only state a segment ever has. UI renders at full opacity, no
    /// indicator. Equivalent to "this is the final word on this segment."
    case refined
}

/// A single transcribed segment of audio with timing and speaker info.
struct TranscriptSegment: Identifiable, Equatable, Codable {
    let id: UUID
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var speaker: String?
    var isFinalized: Bool
    /// Position in the multi-pass refinement lifecycle. See
    /// `SegmentRefinementState` for semantics. Defaults to `.refined` —
    /// the multi-pass live pipeline stamps `.raw`/`.pending` explicitly
    /// when it's active, so static mode and single-pass live mode get the
    /// "no special UI treatment" path for free.
    var refinementState: SegmentRefinementState

    /// Optional word-level timing. Populated by WhisperKit when
    /// `wordTimestamps: true` is set in DecodingOptions; nil from backends
    /// or paths that don't emit word timing (Parakeet, WhisperKit before
    /// this was turned on, sub-segments created via the boundary-split
    /// path in `performRefinementPass`).
    ///
    /// Used by the refined-pass speaker-boundary splitter: when a refined
    /// segment's time range crosses a Sortformer speaker turn boundary,
    /// the splitter looks for the inter-word gap that brackets the
    /// boundary timestamp and emits two segments cut at that point.
    /// Without word timing the splitter can only fall back to "majority
    /// speaker wins the whole segment" — the historical behavior.
    ///
    /// Optional rather than always-empty so SwiftUI diffing and Codable
    /// encoding cheaply distinguish "no word info" from "we tried and got
    /// nothing." JSON export uses an explicit `ExportedSegment` mapping,
    /// so adding this field doesn't expose it externally — it's an
    /// internal channel between WhisperKit and the splitter.
    var words: [WordToken]?

    init(
        id: UUID = UUID(),
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        speaker: String? = nil,
        isFinalized: Bool = false,
        refinementState: SegmentRefinementState = .refined,
        words: [WordToken]? = nil
    ) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
        self.isFinalized = isFinalized
        self.refinementState = refinementState
        self.words = words
    }

    var duration: TimeInterval { end - start }

    /// Media time for a character offset within this segment's
    /// TRIMMED text — the word-level seek primitive.
    ///
    /// With word timings, the offset maps to its word by
    /// reconstructing the character walk (word texts joined by single
    /// spaces — the same construction the renderer and the splitter
    /// use), returning that word's real start time. If the
    /// reconstruction drifts from the actual text length (tokenizer
    /// mismatch), the word mapping is distrusted and interpolation is
    /// used instead. Without word timings, time interpolates linearly
    /// by character position.
    ///
    /// **Early bias, by design.** This is a SEEK primitive, and seek
    /// errors are asymmetric: landing late clips the word the user
    /// aimed at (bad), landing early plays a moment of lead-in
    /// (harmless, often useful). Each path subtracts a lead sized to
    /// its error profile — a small pad on word-clock times (covers
    /// player seek granularity clipping the first phoneme), a larger
    /// one on interpolation (covers the interpolation error itself).
    /// Clamped to the segment start, so the floor is the old
    /// segment-start behavior.
    func time(atCharacterOffset offset: Int) -> TimeInterval {
        let text = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let length = max(text.count, 1)
        let clamped = max(0, min(offset, length))
        let interpolated = start + duration * Double(clamped) / Double(length)

        let exactLead: TimeInterval = 0.15
        let interpolatedLead: TimeInterval = 0.6

        guard let words, !words.isEmpty else {
            return max(start, interpolated - interpolatedLead)
        }

        var cursor = 0
        var wordExact: TimeInterval? = nil
        for word in words {
            let w = word.text.trimmingCharacters(in: .whitespaces)
            guard !w.isEmpty else { continue }
            let wordEnd = cursor + w.count
            if clamped >= cursor && clamped <= wordEnd {
                wordExact = word.start
            }
            cursor = wordEnd + 1  // joining space
        }
        // Drift check: if the word texts don't reconstruct the
        // segment text (±3 chars tolerance), the mapping above may
        // have picked the wrong word — fall back to interpolation.
        if abs((cursor - 1) - text.count) > 3 || wordExact == nil {
            return max(start, interpolated - interpolatedLead)
        }
        return max(start, (wordExact ?? interpolated) - exactLead)
    }

    var formattedTimeRange: String {
        "\(Self.formatTime(start)) – \(Self.formatTime(end))"
    }

    static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "00:00" }
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

/// Word-level timing emitted by WhisperKit when `wordTimestamps: true` is
/// set on `DecodingOptions`. Timestamps are in the absolute stream timeline
/// — the backend remaps WhisperKit's per-chunk-relative numbers before
/// returning the result.
///
/// `text` is the raw token text from Whisper, leading whitespace and all,
/// because WhisperKit preserves how Whisper tokenizes (a word starts with
/// " word" not "word"). Display/export code that wants clean text should
/// `trimmingCharacters(in: .whitespaces)`; the splitter doesn't touch the
/// text at all, it only uses the timestamps.
struct WordToken: Equatable, Codable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// A run of consecutive segments attributed to the same speaker (or all unattributed,
/// when speaker is nil). Used for both the rendered transcript view and text exports
/// so the two stay consistent — what users see on screen is what they get in the file.
struct SpeakerGroup: Identifiable {
    let speaker: String?
    var segments: [TranscriptSegment]

    /// Stable identity for SwiftUI: the first segment's id. Appending more segments
    /// to a group keeps its id, so the view diffs correctly on incremental updates.
    var id: UUID { segments.first?.id ?? UUID() }

    var start: TimeInterval { segments.first?.start ?? 0 }
    var end: TimeInterval { segments.last?.end ?? 0 }

    /// The "least refined" state across the group's segments. A group is shown
    /// as raw/pending if *any* of its constituent segments hasn't been refined
    /// yet — a paragraph is only as solid as its weakest sentence. Refined is
    /// the optimistic case (full opacity, no indicator), which is what every
    /// segment defaults to outside the multi-pass live pipeline.
    var refinementState: SegmentRefinementState {
        if segments.contains(where: { $0.refinementState == .raw }) { return .raw }
        if segments.contains(where: { $0.refinementState == .pending }) { return .pending }
        return .refined
    }

    /// Joined paragraph text with double-spaces collapsed and inter-segment spacing
    /// normalized. Whisper segments don't have consistent leading/trailing spaces.
    var combinedText: String {
        let joined = segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined
            .replacingOccurrences(of: "  ", with: " ")
    }

    var formattedTimeRange: String {
        "\(TranscriptSegment.formatTime(start)) – \(TranscriptSegment.formatTime(end))"
    }
}

extension Array where Element == TranscriptSegment {
    /// Collapse consecutive same-speaker segments into paragraph blocks, dropping
    /// segments whose text is just whitespace/punctuation (Whisper artifacts from
    /// trailing silence in the final flush).
    func groupedBySpeaker() -> [SpeakerGroup] {
        guard !isEmpty else { return [] }
        let punctuation = CharacterSet(charactersIn: ".,;:!?-—")
        let trimSet = CharacterSet.whitespacesAndNewlines.union(punctuation)

        var groups: [SpeakerGroup] = []
        for seg in self {
            // Drop dangling-period and similar trailing-silence artifacts.
            let stripped = seg.text.trimmingCharacters(in: trimSet)
            if stripped.isEmpty { continue }

            if let lastGroup = groups.last, lastGroup.speaker == seg.speaker {
                groups[groups.count - 1].segments.append(seg)
            } else {
                groups.append(SpeakerGroup(speaker: seg.speaker, segments: [seg]))
            }
        }
        return groups
    }
}

/// A pinned excerpt from the transcript. Captures the text + metadata at pin time so
/// the pin remains stable even if the underlying transcript is later rebuilt (e.g.
/// after speaker re-attribution at end of static-mode runs). Stores the source
/// segment ID so the UI can scroll back to it on click.
struct PinnedQuote: Identifiable, Equatable, Codable {
    let id: UUID
    /// The literal text the user pinned.
    var text: String
    /// Machine speaker label at pin time (e.g. "Speaker 1"). Display name is resolved
    /// from the engine's name map at render time, not snapshotted, so renaming a
    /// speaker updates pin labels too.
    var speaker: String?
    /// Timestamp of the source segment, kept for stable display labels.
    var start: TimeInterval
    var end: TimeInterval
    /// Optional reference to the segment this came from. When set, clicking the pin
    /// can scroll the transcript view to that segment. Pins from selections that
    /// span multiple segments may set this to the first segment.
    var sourceSegmentID: UUID?
    var pinnedAt: Date
    /// If this pin was created by the keyword watcher rather than a manual right-click,
    /// stores the matched keyword (in its original-case form as the user typed it).
    /// Used by PinPanel to render an "Auto: keyword" badge so the user can tell why
    /// something was pinned without their action. nil for manual pins.
    var matchedKeyword: String?

    init(
        id: UUID = UUID(),
        text: String,
        speaker: String?,
        start: TimeInterval,
        end: TimeInterval,
        sourceSegmentID: UUID? = nil,
        pinnedAt: Date = Date(),
        matchedKeyword: String? = nil
    ) {
        self.id = id
        self.text = text
        self.speaker = speaker
        self.start = start
        self.end = end
        self.sourceSegmentID = sourceSegmentID
        self.pinnedAt = pinnedAt
        self.matchedKeyword = matchedKeyword
    }
}

/// Source type detected for a given URL.
enum StreamSource: String, CaseIterable {
    case youtube = "YouTube"
    case twitter = "Twitter / X"
    case facebook = "Facebook"
    case instagram = "Instagram"
    case threads = "Threads"
    case applePodcast = "Apple Podcasts"
    case soundcloud = "SoundCloud"
    case senateGov = "U.S. Senate"
    case criticalMention = "Critical Mention"
    case granicus = "Granicus"
    case hls = "HLS Stream"
    case directAudio = "Direct Audio"
    case localFile = "Local File"
    case unknown = "Unknown"

    /// Audio file extensions ffmpeg can read directly.
    private static let audioExtensions = [
        "mp3", "m4a", "wav", "aac", "flac", "ogg", "opus", "wma", "aiff",
    ]

    /// Video file extensions ffmpeg can demux to extract audio.
    private static let videoExtensions = [
        "mp4", "mov", "m4v", "mkv", "avi", "webm", "flv", "wmv", "mpg", "mpeg", "ts",
    ]

    static var supportedFileExtensions: [String] {
        audioExtensions + videoExtensions
    }

    /// True for sources that need yt-dlp to resolve a media URL before ffmpeg can
    /// read it. Centralizes the "is this a yt-dlp site?" check so the extractor
    /// doesn't have to maintain a parallel list.
    ///
    /// `.unknown` is in the yt-dlp camp because yt-dlp's *generic* extractor
    /// scrapes arbitrary HTML pages for embedded media URLs (HLS in `<video>`
    /// tags, JW Player configs, `.m3u8` references in JS, etc.). Pages that
    /// embed a video — news sites, BBC iPlayer, etc. — paste
    /// as `.unknown` and yt-dlp's generic extractor finds the underlying
    /// stream. When yt-dlp can't extract, the user sees a yt-dlp error
    /// (better than ffmpeg's cryptic "Invalid data found").
    ///
    /// `.senateGov` is NOT in the yt-dlp camp. Senate.gov ISVP URLs have a
    /// fully deterministic structure — the m3u8 URL is derivable from the
    /// committee + filename + a hardcoded committee→ID mapping (see
    /// `SenateGovExtractor`). Resolving directly is ~500 ms (one HTTP page
    /// fetch for the iframe) vs. 6–9 s for the yt-dlp probe + URL-resolution
    /// fallback path. Routing senate.gov through our own extractor avoids
    /// every yt-dlp quirk (auth, format selection, fragment write paths)
    /// for the long-form government hearings this app sees most often.
    var requiresYTDlp: Bool {
        switch self {
        case .youtube, .twitter, .facebook, .instagram, .threads, .applePodcast, .soundcloud, .unknown:
            return true
        case .senateGov, .criticalMention, .granicus, .hls, .directAudio, .localFile:
            return false
        }
    }

    /// True for sites that benefit from yt-dlp's `--impersonate chrome`
    /// TLS-fingerprint mimicry. Currently Facebook and Instagram —
    /// both employ TLS fingerprinting that distinguishes yt-dlp's
    /// Python TLS signature from a real browser and serves an
    /// unparseable response to yt-dlp ("Cannot parse data" / Meta's
    /// API error 1357005).
    ///
    /// Excluded:
    ///   - **YouTube** — Google's bot detection is sophisticated
    ///     enough that the `chrome` TLS fingerprint *without* matching
    ///     browser-realistic behavior (JS engine, real session, timing)
    ///     triggers HARDER challenges than plain yt-dlp does. Empirically
    ///     `--impersonate chrome` on YouTube causes "Sign in to confirm
    ///     you're not a bot" errors that don't appear without it.
    ///   - **Unknown** — `--impersonate` is broadly safe but may cause
    ///     issues on any given site, so we don't enable it speculatively.
    ///     Users who hit a Facebook-like issue on an unrecognized site
    ///     would need an explicit workaround.
    var benefitsFromImpersonation: Bool {
        switch self {
        case .facebook, .instagram, .threads:
            return true
        default:
            return false
        }
    }

    static func detect(from url: URL) -> StreamSource {
        // Local files come in as file:// URLs (from drag-and-drop, NSOpenPanel, or
        // when the user pastes a path that we coerce to file://).
        if url.isFileURL {
            return .localFile
        }

        let host = url.host?.lowercased() ?? ""
        if host.contains("youtube.com") || host.contains("youtu.be") {
            return .youtube
        }
        // Twitter/X: hosts include twitter.com, x.com, and their mobile/i variants
        // (mobile.twitter.com, m.twitter.com). yt-dlp handles all of them via its
        // "Twitter" extractor, so we route them all through the same yt-dlp path.
        // Tweet URLs have the shape /<user>/status/<id> — we don't validate the
        // shape here because users sometimes paste shortened or query-laden URLs
        // (e.g. with ?s=20 tracking) and yt-dlp tolerates those. Letting yt-dlp
        // be the source of truth on what's actually fetchable is the right call.
        if host == "twitter.com" || host.hasSuffix(".twitter.com")
            || host == "x.com" || host.hasSuffix(".x.com")
        {
            return .twitter
        }
        // Facebook: facebook.com (web), m.facebook.com (mobile), and the
        // fb.watch shortener used by share links. yt-dlp's Facebook
        // extractor handles all of them — videos, reels, and watch URLs.
        // Reels in particular need `--impersonate chrome` because Facebook
        // does TLS-fingerprint detection on non-browser clients (handled
        // by AudioStreamExtractor's args, not here).
        if host == "facebook.com" || host.hasSuffix(".facebook.com")
            || host == "fb.watch" || host.hasSuffix(".fb.watch")
            || host == "fb.com" || host.hasSuffix(".fb.com")
        {
            return .facebook
        }
        // Instagram: instagram.com (web) plus its various share-link
        // shorteners (instagr.am). yt-dlp's Instagram extractor handles
        // posts, reels, IGTV, and stories. Like Facebook, Instagram does
        // TLS-fingerprint detection on some endpoints — covered by the
        // global `--impersonate chrome` flag.
        if host == "instagram.com" || host.hasSuffix(".instagram.com")
            || host == "instagr.am" || host.hasSuffix(".instagr.am")
        {
            return .instagram
        }
        // Threads: threads.com (primary) and threads.net (the original
        // launch domain, still resolves and gets shared). Runs on
        // Meta's Instagram CDN — direct media URLs end up at
        // `scontent-*.cdninstagram.com` with signed query strings. yt-dlp
        // has a dedicated Threads extractor (added mid-2024) that
        // handles both post URLs and direct video extraction. Same TLS-
        // fingerprinting + cookie behavior as Instagram — wired up via
        // `requiresYTDlp` + `benefitsFromImpersonation` above. Login is
        // required for some accounts/posts; the existing cookie-from-
        // browser flow covers it.
        if host == "threads.com" || host.hasSuffix(".threads.com")
            || host == "threads.net" || host.hasSuffix(".threads.net")
        {
            return .threads
        }
        // Critical Mention: media-monitoring service serving broadcast
        // clips via signed HLS streams. Two URL shapes matter:
        //   - `app.criticalmention.com/app/#/clip/public/<uuid>` — the
        //     canonical page URL users share; hash-routed SPA. Our
        //     browser extractor watches this page for the actual
        //     stream URL that its JS bundle fetches.
        //   - `<region>.assets.criticalmention.com/stream.php?...` —
        //     the direct signed HLS URL. Users could paste this too,
        //     though it expires within hours. Both are recognized
        //     here so pasted variants route to the same extractor
        //     (which for a direct-assets URL, would just capture it
        //     via the JS shim on first observation).
        if host == "criticalmention.com" || host.hasSuffix(".criticalmention.com") {
            return .criticalMention
        }
        // Granicus: government meeting/stream platform used by many
        // city and county governments (e.g. dc.granicus.com). Player
        // pages (`/player/camera/N?publish_id=…`, `/MediaPlayer.php…`)
        // load a JS player that fetches an HLS playlist from a Wowza
        // CDN (`cdn*.wowza.com/.../playlist.m3u8`). yt-dlp has no
        // Granicus extractor and its generic scraper misses the JS-
        // loaded playlist, so these route through the same WKWebView
        // network-sniffing extractor as Critical Mention — the
        // sniffer's generic `.m3u8` match catches the Wowza playlist
        // with no changes. (A pasted wowza .m3u8 URL directly still
        // detects as `.hls` below and skips the browser entirely.)
        if host == "granicus.com" || host.hasSuffix(".granicus.com") {
            return .granicus
        }
        // Apple Podcasts: host is always podcasts.apple.com. yt-dlp's extractor
        // requires URLs of the shape /<lang>/podcast/<name>/idNNN?i=NNN — i.e.
        // an episode-level URL with the i= query parameter. Podcast-level URLs
        // (no i=) will fail at extraction with a clear yt-dlp error, which our
        // stderr logging surfaces. We don't validate the shape here because the
        // engine surfaces yt-dlp's error verbatim and that's more honest than
        // pre-judging based on URL shape.
        if host == "podcasts.apple.com" {
            return .applePodcast
        }
        // SoundCloud: soundcloud.com (web), m.soundcloud.com (mobile),
        // on.soundcloud.com (share-link shortener). yt-dlp's extractor handles
        // all of them. Track URLs work; playlist URLs would resolve to the
        // first track (since `resolveViaYTDlp` takes the first stdout line).
        if host == "soundcloud.com" || host.hasSuffix(".soundcloud.com") {
            return .soundcloud
        }
        // U.S. Senate: any of the supported committee subdomains under
        // .senate.gov, plus the central www.senate.gov/isvp/ player URL.
        // Routed through `SenateGovExtractor` instead of yt-dlp because
        // the ISVP player has a fully deterministic URL structure — the
        // m3u8 URL is derivable from the committee + filename params
        // with a one-time HTML fetch for the iframe URL on hearing
        // pages. Our extractor is ~500 ms vs ~6-9 s for the yt-dlp +
        // URL-resolution-fallback chain, AND it bypasses every yt-dlp
        // quirk we've debugged for senate.gov (auth, format selection,
        // fragment write paths).
        //
        // Subdomain list mirrors the set of committee hearing pages we
        // can resolve via `SenateGovExtractor.committees`. Note that
        // some page subdomains differ from their ISVP `comm` codes
        // (the iframe URL parameter) — `hsgac.senate.gov` hosts the
        // Homeland Security pages but the ISVP `comm` is `govtaff`,
        // for example. The extractor handles that mapping internally;
        // here we just need the page subdomain to be recognized so
        // detection picks `.senateGov` and routes accordingly.
        let senateSubdomains: Set<String> = [
            "agriculture", "aging", "appropriations", "armed-services",
            "banking", "budget", "commerce", "energy", "epw", "ethics",
            "finance", "foreign", "help", "hsgac", "inaugural", "indian",
            "intelligence", "jec", "judiciary", "rules", "sbc", "veterans",
        ]
        if host.hasSuffix(".senate.gov") {
            // Strip optional "www." prefix to match against subdomain set.
            let withoutSuffix = host.dropLast(".senate.gov".count)
            let normalized = withoutSuffix.hasPrefix("www.")
                ? String(withoutSuffix.dropFirst("www.".count))
                : String(withoutSuffix)
            if senateSubdomains.contains(normalized) {
                return .senateGov
            }
            // www.senate.gov/isvp/... — the central ISVP player. Some pages
            // link directly to it (and yt-dlp's c-span integration emits
            // these URLs), so catch them here too.
            if (normalized == "www" || normalized.isEmpty) && url.path.hasPrefix("/isvp") {
                return .senateGov
            }
        }
        let path = url.path.lowercased()
        if path.hasSuffix(".m3u8") || path.contains("/hls/") {
            return .hls
        }
        if audioExtensions.contains(where: { path.hasSuffix(".\($0)") }) {
            return .directAudio
        }
        return .unknown
    }
}

/// Top-level engine state surfaced to the UI.
enum EngineState: Equatable {
    case idle
    case preparing(String)         // human-readable status
    case streaming                 // actively pulling + transcribing
    case finishing                 // user stopped, draining buffers
    /// User stopped while a refinement pass was in flight. Treated as
    /// active (Stop button stays visible but disabled — see SidebarView's
    /// control bar) while the in-flight pass completes. Associated string
    /// is the user-visible label (e.g. "Finalizing refinement…"). Bounded
    /// by `awaitRefinementGrace` upstream; after the grace window the
    /// state transitions to `.idle`.
    case finalizing(String)
    case error(String)

    var isActive: Bool {
        switch self {
        case .preparing, .streaming, .finishing, .finalizing: return true
        default: return false
        }
    }

    /// True when the engine is in a teardown state that the user can't
    /// interrupt — they already clicked Stop (or the source ended), and
    /// we're closing out the pipeline. Distinguishes "running, can stop"
    /// from "shutting down, click is no-op." Drives the Stop button's
    /// disabled state.
    var isFinalizing: Bool {
        switch self {
        case .finishing, .finalizing: return true
        default: return false
        }
    }

    var displayLabel: String {
        switch self {
        case .idle: return "Ready"
        case .preparing(let msg): return msg
        case .streaming: return "Transcribing"
        case .finishing: return "Finishing up"
        case .finalizing(let msg): return msg
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

/// Browser identifiers for yt-dlp's `--cookies-from-browser` flag. The string
/// values are exactly what yt-dlp expects.
///
/// Why this exists: YouTube live streams, age-gated VOD, and some membership-
/// only content reject yt-dlp's anonymous extraction with 403s. Passing browser
/// cookies makes the request look like it came from a real signed-in session,
/// which usually clears those errors. The trade-off is privacy (yt-dlp reads
/// from the user's Chrome/Safari/Firefox cookie database) and friction (macOS
/// shows a Keychain access prompt the first time, sometimes per-launch).
///
/// `none` is the default — we don't enable cookie-reading silently because that
/// would surprise users with permission prompts they didn't ask for.
enum CookieBrowser: String, CaseIterable, Identifiable {
    case none    = "None"
    case chrome  = "Chrome"
    case safari  = "Safari"
    case firefox = "Firefox"
    case brave   = "Brave"
    case edge    = "Edge"
    case arc     = "Arc"

    var id: String { rawValue }

    /// Argument to pass to yt-dlp's `--cookies-from-browser`. `nil` for `.none`,
    /// which means "don't include the flag at all."
    var ytDlpArgument: String? {
        switch self {
        case .none:    return nil
        case .chrome:  return "chrome"
        case .safari:  return "safari"
        case .firefox: return "firefox"
        case .brave:   return "brave"
        case .edge:    return "edge"
        case .arc:     return "arc"
        }
    }
}

/// User-facing choice for how the engine treats audio in a transcription session.
///
/// Historically this was auto-derived from the source's known duration: anything
/// ≥10s was treated as "static" (whole-file diarization), shorter clips and
/// unknown-duration streams were "live" (per-chunk diarization). That logic is
/// still the default behavior — `.auto` resolves to one of the others at
/// session start — but exposing the choice means future live-mode-only
/// features (real-time UI, streaming export, latency tuning) have a clean place
/// to hang off rather than re-deriving the same conditional everywhere.
///
/// Modes differ along three dimensions, all driven from this single setting:
///   • Diarization strategy: per-chunk (live) vs whole-file post-pass (static)
///   • PCM buffering: streaming-only (live) vs full-session accumulation (static)
///   • Duration assumptions: live works on infinite streams; static needs
///     bounded duration or it OOMs as the buffer grows
///
/// Chunk size and overlap don't currently differ between modes (both 30s/5s as
/// of the recent live-quality work), but a future split is plausible — e.g. if
/// real-time live mode wants smaller chunks for latency.
enum SessionMode: String, CaseIterable, Identifiable {
    /// Pick `.live` or `.static` based on whether the source has a known finite
    /// duration. Default behavior; equivalent to the pre-toggle logic.
    case auto

    /// Per-chunk transcribe + diarize. Speaker IDs cluster from chunk-local
    /// context. Works on infinite streams. Less stable speaker labels.
    case live

    /// Per-chunk transcribe, but defer all diarization until extraction
    /// finishes — then run one pass on the whole accumulated buffer. Produces
    /// the most stable speaker IDs (full global context), but requires bounded
    /// duration. Memory ~115 MB per hour of audio while the session runs.
    case `static`

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:    return "Auto"
        case .live:    return "Live"
        case .static:  return "Static"
        }
    }

    /// Short subtitle shown under the picker explaining the trade-off. Kept
    /// terse — the picker isn't a wall of text.
    var description: String {
        switch self {
        case .auto:    return "Decide based on the source"
        case .live:    return "Per-chunk diarization, infinite streams"
        case .static:  return "Whole-file diarization, bounded sources"
        }
    }
}
