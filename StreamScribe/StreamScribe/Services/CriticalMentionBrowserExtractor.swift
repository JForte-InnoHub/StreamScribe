import Foundation
import WebKit

/// Browser-based m3u8 extractor for Critical Mention clip pages.
/// Mirrors `SenateGovBrowserExtractor`'s architecture: a headless
/// WKWebView loads the clip URL, a JavaScript shim intercepts
/// network requests, and the first stream URL landing on Critical
/// Mention's CDN gets captured and returned.
///
/// **Why Critical Mention needs this treatment.** The clip page is a
/// hash-routed single-page app (URLs look like
/// `app.criticalmention.com/app/#/clip/public/<uuid>`). The initial
/// HTML is a shell; the actual clip data — including the signed HLS
/// stream URL — arrives via subsequent JavaScript-driven API calls.
/// Static HTML scraping sees nothing. yt-dlp has no CriticalMention
/// extractor. The stream URL includes an HMAC signature and expiry,
/// so we can't cache it — every session needs a fresh URL from the
/// live page.
///
/// **How Critical Mention URLs differ from senate.gov.** senate.gov's
/// stream URLs contain `.m3u8` in the path. Critical Mention's use
/// `stream.php` as the path and `fmt=m3u8` as a query parameter —
/// the JS observer shim below matches either pattern.
///
/// **Public clips only for v1.** URLs containing `/clip/public/`
/// don't require login. Private clips (behind `/clip/private/` or
/// similar) would require a Critical Mention session — WKWebView
/// doesn't share cookies with Safari, so we'd need a login step
/// inside the app to make private clips work. Not addressed here;
/// public clips cover the common use case.
///
/// **Same lifecycle guarantees as senate.gov version:** single-shot,
/// tears down its own WKWebView on completion or timeout, safe to
/// call from any context (hops to MainActor internally).
@MainActor
final class CriticalMentionBrowserExtractor: NSObject {

    /// Result of a successful extraction. The captured stream URL is
    /// signed and time-limited; downstream code should use it
    /// immediately rather than caching.
    struct ExtractionResult {
        let streamURL: URL
        let pageTitle: String?
    }

    /// Resolve a Critical Mention clip page URL to its stream URL.
    /// Returns nil on page-load failure or timeout.
    static func resolve(pageURL: URL, timeout: TimeInterval = 15) async -> ExtractionResult? {
        await withCheckedContinuation { (continuation: CheckedContinuation<ExtractionResult?, Never>) in
            Task { @MainActor in
                let extractor = CriticalMentionBrowserExtractor()
                extractor.start(pageURL: pageURL, timeout: timeout) { result in
                    continuation.resume(returning: result)
                }
            }
        }
    }

    // MARK: - Instance state

    private var webView: WKWebView?
    private var completion: ((ExtractionResult?) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    /// CANDIDATE COLLECTION (2026-07-29). Previously the first URL the
    /// shim reported won outright, which is wrong whenever a page
    /// exposes more than one manifest: players commonly fetch the
    /// master and then a rendition, so first-past-the-post can hand
    /// ffmpeg a single-bitrate VARIANT playlist (the `index_3.m3u8`
    /// shape) instead of the master, or an ad/bumper manifest that
    /// loaded before the real one. We now gather everything the shim
    /// sees for a short settle window, rank the candidates, and verify
    /// the front-runners over the network before committing.
    private struct Candidate {
        let url: URL
        let tier: ManifestTier
        let order: Int
    }

    /// HLS outranks other adaptive formats: the whole pipeline
    /// (probe, ffmpeg copy, miniplayer) is best-tested against it.
    private enum ManifestTier: Int {
        case alternative = 0   // DASH `.mpd`, Smooth `.ism/manifest`
        case hls = 1
    }

    private enum ManifestKind {
        case master          // has #EXT-X-STREAM-INF (or is a DASH MPD)
        case mediaPlaylist   // segments only — a single rendition
        case unreachable     // network/HTTP failure, or not a manifest
    }

    private var candidates: [Candidate] = []
    private var seenCandidateURLs: Set<String> = []
    private var settleTask: Task<Void, Never>?
    /// Page URL, kept for Referer/Origin on verification requests —
    /// several CDNs reject manifest fetches that omit them.
    private var pageURL: URL?

    /// Whether the page being resolved is a Critical Mention page —
    /// selects the strict CM-CDN host filter vs. the permissive
    /// filter used for other sources (Granicus). Set in `start`.
    /// Read from the (nonisolated) message handler; benign because
    /// it's written once before navigation begins and never changes
    /// during a resolve.
    private var pageIsCriticalMention = false

    private override init() { super.init() }

    private func start(pageURL: URL, timeout: TimeInterval, completion: @escaping (ExtractionResult?) -> Void) {
        self.completion = completion
        self.pageURL = pageURL
        // Drives the message handler's host filter — strict CDN
        // matching for CM pages, scheme-only for everything else
        // (Granicus streams live on third-party CDNs like Wowza).
        self.pageIsCriticalMention =
            (pageURL.host?.lowercased().hasSuffix("criticalmention.com")) ?? false

        let config = WKWebViewConfiguration()

        // Inject the URL-observation shim before any page script runs.
        let interceptScript = WKUserScript(
            source: Self.observerJavaScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(interceptScript)
        config.userContentController.add(self, name: "stream")

        // Let media start without a user gesture (2026-07-29). Many
        // players don't request their manifest until playback actually
        // begins; with the default policy WebKit blocks the shim's
        // `play()` nudge outright, so the request we're waiting for is
        // never made. Harmless headless — nothing is audible, and the
        // view is torn down as soon as we have a URL.
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        self.webView = webView

        // 15-second timeout — longer than senate.gov's 10s because
        // Critical Mention's initial JS bundle is larger and its
        // clip-fetch API is served from a Rails backend that
        // occasionally takes a moment to respond. Empirically clips
        // resolve within 3-8 seconds when they resolve at all.
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await MainActor.run {
                guard let self, !self.finished else { return }
                // Candidates in hand at timeout are still usable — the
                // settle window simply hadn't elapsed yet.
                if !self.candidates.isEmpty {
                    print("[CriticalMentionBrowser] Timeout after \(Int(timeout))s with \(self.candidates.count) candidate(s) — selecting now.")
                    Task { @MainActor [weak self] in await self?.selectAndFinish() }
                    return
                }
                // Say WHAT the page looked like. A bare timeout can't
                // distinguish "the page never loaded" from "it loaded but
                // the player never started" from "it played and we missed
                // the request" — three problems with three different
                // fixes (2026-09-16, Frame.io timing out on both its
                // short and long URL forms). Ask the page directly.
                self.dumpPageDiagnostics { summary in
                    print("[CriticalMentionBrowser] Timeout after \(Int(timeout))s with no stream URL. Page state: \(summary)")
                    Task { @MainActor [weak self] in self?.finish(result: nil) }
                }
                return
            }
        }

        // Modern browser UA. Critical Mention's page occasionally
        // serves different bundles based on UA sniffing.
        //
        // NOT applied to every host (2026-09-22). This string pins
        // Safari 17 / macOS 14, which is years stale, and a modern SPA
        // that gates on browser version will serve an unsupported-browser
        // bail instead of its app. That is exactly the shape of the
        // Frame.io diagnostic: 165 resources fetched (bundles loaded),
        // then a 33-character body, no player, no media element. Leaving
        // customUserAgent nil makes WKWebView report the REAL Safari for
        // this OS, which is both truthful and current.
        //
        // Critical Mention keeps the pinned string because its UA
        // sniffing is the reason the override exists at all; changing it
        // there would be an unrelated risk.
        let host = (pageURL.host ?? "").lowercased()
        let wantsPinnedUA = !(host == "f.io" || host.hasSuffix(".f.io")
                              || host == "frame.io" || host.hasSuffix(".frame.io"))
        if wantsPinnedUA {
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        } else {
            print("[CriticalMentionBrowser] Using the system Safari user agent for \(host) — a pinned stale UA can trigger unsupported-browser gates on modern SPAs.")
        }

        print("[CriticalMentionBrowser] Loading \(pageURL.absoluteString) in headless WKWebView…")
        webView.load(URLRequest(url: pageURL))
    }

    /// Record a manifest the shim spotted and arm the settle window.
    private func addCandidate(url: URL, tier: ManifestTier) {
        guard !finished else { return }
        guard seenCandidateURLs.insert(url.absoluteString).inserted else { return }
        candidates.append(Candidate(url: url, tier: tier, order: candidates.count))
        print("[CriticalMentionBrowser] Candidate \(candidates.count) (\(tier == .hls ? "HLS" : "alt")): \(url.absoluteString)")

        // First sighting starts a short window so sibling manifests
        // (master + renditions) can arrive and be compared. Kept brief:
        // players request them back-to-back, and this delay is added to
        // every extraction.
        guard settleTask == nil else { return }
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !self.finished else { return }
            await self.selectAndFinish()
        }
    }

    /// Rank the collected candidates, verify the leaders over the
    /// network, and finish with the best manifest available.
    private func selectAndFinish() async {
        guard !finished else { return }
        guard !candidates.isEmpty else { finish(result: nil); return }

        let all = candidates
        let ranked = all.sorted { Self.score($0, among: all) > Self.score($1, among: all) }
        if ranked.count > 1 {
            print("[CriticalMentionBrowser] \(ranked.count) candidates; ranked: " +
                  ranked.map { "\($0.url.lastPathComponent)(\(Self.score($0, among: all)))" }.joined(separator: ", "))
        }

        // Heuristics order the queue; fetching decides. A master
        // manifest is definitive, and a fetch failure demotes a
        // candidate that would otherwise have been chosen blind —
        // which is the other half of the consistency win, since a
        // signed URL that 403s is worse than the next candidate.
        var mediaFallback: Candidate?
        for candidate in ranked.prefix(3) {
            if finished { return }
            switch await Self.classifyManifest(url: candidate.url, referer: pageURL) {
            case .master:
                finishWith(candidate, note: "master manifest, verified")
                return
            case .mediaPlaylist:
                if mediaFallback == nil { mediaFallback = candidate }
            case .unreachable:
                print("[CriticalMentionBrowser] Candidate unreachable, trying next: \(candidate.url.lastPathComponent)")
            }
        }
        if finished { return }
        if let mediaFallback {
            finishWith(mediaFallback, note: "single-rendition playlist (no master found)")
        } else {
            // Nothing verified — every fetch failed, most likely
            // because the CDN wants headers or cookies we don't carry.
            // Fall back to the ranking, which is never worse than the
            // pre-2026-07-29 first-match behavior.
            finishWith(ranked[0], note: "unverified, highest-ranked")
        }
    }

    private func finishWith(_ candidate: Candidate, note: String) {
        let rawTitle = webView?.title
        let pageTitle = (rawTitle?.isEmpty == false) ? rawTitle : nil
        print("[CriticalMentionBrowser] Captured stream URL: \(candidate.url.absoluteString) [\(note)]\(pageTitle.map { " — title: \"\($0)\"" } ?? "")")
        finish(result: ExtractionResult(streamURL: candidate.url, pageTitle: pageTitle))
    }

    /// Rank a candidate. Higher is better. Tier dominates; the rest are
    /// naming conventions that distinguish a master playlist from one
    /// rendition of it.
    private static func score(_ candidate: Candidate, among all: [Candidate]) -> Int {
        var score = candidate.tier == .hls ? 1000 : 0
        let file = candidate.url.lastPathComponent.lowercased()
        let stem = (file as NSString).deletingPathExtension
        let directory = candidate.url.deletingLastPathComponent().absoluteString

        if file.contains("master") { score += 300 }
        if ["index", "playlist", "main", "manifest", "stream"].contains(stem) { score += 200 }
        // Rendition markers: `index_3`, `chunklist_w12`, `media_1`,
        // `…_720p`, `…_800k` — all name ONE bitrate/resolution.
        if stem.range(of: #"_\d+$"#, options: .regularExpression) != nil { score -= 300 }
        if stem.hasPrefix("chunklist") || stem.hasPrefix("media_") { score -= 300 }
        if stem.range(of: #"\d{3,4}[kp]"#, options: .regularExpression) != nil { score -= 200 }
        // Strongest structural signal: another candidate sits in the
        // same directory and is named after this one with a suffix
        // (`index.m3u8` alongside `index_3.m3u8`) — this one is the
        // master and that one is its rendition.
        for other in all where other.url.absoluteString != candidate.url.absoluteString {
            guard other.url.deletingLastPathComponent().absoluteString == directory else { continue }
            let otherStem = (other.url.lastPathComponent.lowercased() as NSString).deletingPathExtension
            if otherStem.hasPrefix(stem + "_") || otherStem.hasPrefix(stem + "-") {
                score += 250
                break
            }
        }
        // Tiebreak toward what arrived first: players fetch the master
        // before the rendition it points at.
        score -= candidate.order
        return score
    }

    /// Fetch a manifest and decide what it is. Sends Referer/Origin
    /// because signed CDN manifests frequently require them.
    private nonisolated static func classifyManifest(url: URL, referer: URL?) async -> ManifestKind {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            if let scheme = referer.scheme, let host = referer.host {
                request.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin")
            }
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              // Manifests are text and small; a prefix is plenty and
              // caps the cost if we hit something unexpected.
              let text = String(data: data.prefix(65_536), encoding: .utf8) else {
            return .unreachable
        }
        if text.contains("#EXT-X-STREAM-INF") { return .master }
        if text.contains("<MPD") || text.contains("<SmoothStreamingMedia") { return .master }
        if text.contains("#EXTINF") || text.contains("#EXTM3U") { return .mediaPlaylist }
        return .unreachable
    }

    /// Interrogate the loaded page about why nothing was captured.
    ///
    /// Reports where it ended up (redirects followed?), what it is
    /// (title), how much it fetched (resource count), whether ANY media
    /// URL appears in its network history, whether a media element was
    /// ever created, and how many play controls our selectors can see.
    /// Each answer points somewhere specific: zero resources means the
    /// page never loaded; resources but no media and no `<video>` means
    /// the player never started; a media URL present in the timeline but
    /// not captured means our matcher missed its shape.
    private func dumpPageDiagnostics(_ completion: @escaping (String) -> Void) {
        let js = """
        (function() {
            var r = [];
            try { r = performance.getEntriesByType('resource').map(function(e){ return e.name; }); } catch (e) {}
            var media = r.filter(function(n){ return /\\.m3u8|\\.mpd|\\.mp4|\\.m4a/i.test(n); });
            var vids = 0, playable = 0;
            try { vids = document.querySelectorAll('video, audio').length; } catch (e) {}
            try {
                playable = document.querySelectorAll(
                    '[class*="play"], [aria-label*="play" i], button[title*="play" i]'
                ).length;
            } catch (e) {}
            return JSON.stringify({
                url: location.href,
                title: (document.title || '').slice(0, 80),
                resources: r.length,
                mediaUrls: media.length,
                firstMedia: media.length ? media[0].slice(0, 120) : null,
                mediaElements: vids,
                playControls: playable,
                bodyChars: (document.body ? document.body.innerText.length : 0)
            });
        })();
        """
        guard let webView else { completion("no web view"); return }
        webView.evaluateJavaScript(js) { value, error in
            if let json = value as? String {
                completion(json)
            } else {
                completion("diagnostics unavailable (\(error?.localizedDescription ?? "no result"))")
            }
        }
    }

    private func finish(result: ExtractionResult?) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        settleTask?.cancel()
        settleTask = nil

        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeAllUserScripts()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "stream")
        webView = nil

        let cb = completion
        completion = nil
        cb?(result)
    }

    // MARK: - The injected JavaScript

    /// JS shim reporting stream URLs back to native code via the
    /// `stream` message handler. Three observation layers, because
    /// different players load HLS differently:
    ///
    ///   1. **fetch/XHR hooks** — catches JS-driven players that
    ///      request the playlist themselves (Critical Mention's SPA,
    ///      hls.js-based players on browsers without native HLS).
    ///   2. **Media-element hooks** (`HTMLMediaElement.src` setter +
    ///      `setAttribute` on video/source) — WebKit plays HLS
    ///      NATIVELY, so players like Granicus/Wowza assign the m3u8
    ///      straight to a `<video>` and the load happens inside
    ///      AVFoundation, invisible to fetch/XHR. The setter hook
    ///      catches the assignment itself.
    ///   3. **Periodic DOM scan** (500ms) of video/source `src` and
    ///      `currentSrc` — belt-and-suspenders for anything assigned
    ///      before our hooks installed in a late-created subframe, or
    ///      through framework internals that bypass both hooks. The
    ///      scan also nudges paused players with a muted `play()` and
    ///      CLICKS the player's own play control (2026-07-29) — many
    ///      players don't create a media element or request a manifest
    ///      until their handler runs, so `play()` alone has nothing to
    ///      act on. Bounded (8 clicks, once per element, stops as soon
    ///      as anything is reported) and never clicks a link that
    ///      would navigate away.
    ///   4. **Resource Timing** (`PerformanceObserver` on `resource`
    ///      entries) — the closest in-page equivalent to the
    ///      `webRequest` API that browser extensions use, and the
    ///      reason those extensions detect streams more consistently
    ///      than in-page hooks can (2026-07-29). Layers 1-2 only see
    ///      requests that pass through the specific JS surfaces we
    ///      patched; the Resource Timing buffer records EVERY network
    ///      request the frame made, whoever issued it — WebKit's
    ///      native HLS stack loading a manifest without touching JS,
    ///      a framework that captured `fetch`/`XHR` references before
    ///      our hooks installed, or a player that builds its request
    ///      through internals we don't know about. Cross-origin
    ///      entries still expose `name` (the URL), which is all we
    ///      need — only detailed timings are restricted.
    ///
    /// **Match tiers** (2026-07-29, broadened from `.m3u8`/`fmt=m3u8`):
    ///   - *HLS, posted immediately* — `.m3u8`, bare `.m3u`, and the
    ///     query-param forms (`fmt=`/`format=`/`type=m3u8`) that some
    ///     services use instead of an extension, e.g. Critical
    ///     Mention's `stream.php?…&fmt=m3u8`.
    ///   - *Other adaptive manifests* — `.mpd` (DASH),
    ///     `.ism/manifest` (Smooth), tagged `alt`. The native side
    ///     ranks HLS above these, so a page offering both still yields
    ///     the HLS manifest, while DASH-only players remain usable.
    ///   - *Content-type confirmation* — a response declaring an
    ///     HLS/DASH MIME type is reported even when its URL carries no
    ///     recognizable extension (common: `/playlist/<token>/1234`).
    ///     Weak URL shapes like a bare `/playlist/` segment are
    ///     deliberately NOT matched on their own: an ordinary JSON
    ///     endpoint can look identical, and handing ffmpeg one would
    ///     fail the session, so the server's declared type decides.
    private static let observerJavaScript = """
    (function() {
        // HLS patterns, all unambiguous: a URL containing any of these
        // is a playlist, not a coincidence. `.m3u` (no 8) and the
        // query-param forms cover services that omit the conventional
        // extension.
        var HLS_PATTERN = /\\.m3u8|\\.m3u(?![a-z0-9])|fmt=m3u8|format=m3u8|type=m3u8/i;
        // Non-HLS adaptive manifests. Matched but DEFERRED (see below).
        var ALT_PATTERN = /\\.mpd(?![a-z0-9])|\\.ism\\/manifest/i;
        // Manifest MIME types, for responses whose URL carries no
        // recognizable extension at all.
        var HLS_CONTENT_TYPE = /(application|audio)\\/(vnd\\.apple\\.mpegurl|x-mpegurl|mpegurl)/i;
        var ALT_CONTENT_TYPE = /application\\/(dash\\+xml|vnd\\.ms-sstr\\+xml)/i;

        // Every match is posted immediately with its tier. Ranking and
        // the HLS-over-DASH preference are the NATIVE side's job now
        // (it collects candidates over a settle window and verifies
        // them), which is why the earlier client-side hold-and-defer
        // dance is gone.
        var postedAny = false;

        function post(url, tier) {
            try {
                postedAny = true;
                window.webkit.messageHandlers.stream.postMessage({ url: url, tier: tier });
            } catch (e) {
                // Message handler not attached — ignore.
            }
        }

        function report(url) {
            if (typeof url !== 'string' || !url) return;
            if (HLS_PATTERN.test(url)) {
                post(url, 'hls');
            } else if (ALT_PATTERN.test(url)) {
                post(url, 'alt');
            }
        }

        // Content-type confirmation: the only reliable way to recognize
        // an EXTENSIONLESS manifest (plenty of services serve playlists
        // from paths like `/playlist/<token>/1234` with no hint in the
        // URL). Guessing from weak URL shapes such as `/playlist/` would
        // risk handing ffmpeg an ordinary JSON endpoint, so we let the
        // server's own declared type decide instead.
        function reportWithContentType(url, contentType) {
            if (typeof url !== 'string' || !url || !contentType) return;
            if (HLS_PATTERN.test(url) || ALT_PATTERN.test(url)) return;  // already handled
            if (HLS_CONTENT_TYPE.test(contentType)) {
                post(url, 'hls');
            } else if (ALT_CONTENT_TYPE.test(contentType)) {
                post(url, 'alt');
            }
        }

        // Hook fetch
        if (window.fetch) {
            var originalFetch = window.fetch;
            window.fetch = function(input, init) {
                var url;
                try {
                    url = typeof input === 'string' ? input : (input && input.url);
                    if (url) report(url);
                } catch (e) {}
                var promise = originalFetch.apply(this, arguments);
                try {
                    if (url && promise && promise.then) {
                        // Observe only — we attach to a DERIVED promise
                        // and return the original, so the page's own
                        // chain and error handling are untouched. Reading
                        // headers does not consume the body.
                        promise.then(function(response) {
                            try {
                                var ct = response && response.headers &&
                                    response.headers.get('content-type');
                                reportWithContentType(url, ct);
                                // clone() so the page's own reader still
                                // gets an unconsumed body.
                                if (bodyLooksScannable(ct) && response.clone) {
                                    response.clone().text().then(scanBodyForMedia, function() {});
                                }
                            } catch (e) {}
                        }, function() {});
                    }
                } catch (e) {}
                return promise;
            };
        }

        // RESPONSE-BODY SCAN (2026-09-16). Everything above watches
        // REQUEST urls, which only finds a manifest once the player has
        // asked for it. On a Frame.io share page the player never
        // rendered at all — 166 resources fetched, a correct asset title,
        // but no <video>, no play control and an all-but-empty body — so
        // there was no request to observe. The token was nonetheless
        // already on the wire, sitting inside an API response.
        //
        // So: scan text response BODIES for a manifest URL. This finds
        // the stream the moment the app learns about it, without waiting
        // for playback, and it generalizes to any SPA whose API hands out
        // media URLs in JSON.
        //
        // Guarded on size and type — bodies are cloned, never consumed,
        // and anything large or binary is skipped so we don't stall the
        // page we are observing.
        var MAX_BODY_SCAN = 512 * 1024;

        function scanBodyForMedia(text) {
            if (typeof text !== 'string' || !text || text.length > MAX_BODY_SCAN) return;
            // Unescape BEFORE matching, not after. JSON routinely writes
            // slash characters in escaped form, and the URL pattern excludes
            // backslashes from its character class, so an escaped body
            // matched NOTHING and a post-match cleanup never ran. Caught
            // by testing the scanner against a realistic Frame.io-shaped
            // payload. Both escaping styles seen in the wild are handled
            var body = text
                .replace(/\\\\\\//g, '/')
                .replace(/\\\\u002F/gi, '/');
            var pattern = /https?:\\/\\/[^"'\\s\\\\]+?\\.(?:m3u8|mpd)(?:\\?[^"'\\s\\\\]*)?/gi;
            var match;
            var found = 0;
            while ((match = pattern.exec(body)) !== null && found < 8) {
                found++;
                report(match[0]);
            }
        }

        function bodyLooksScannable(contentType) {
            if (!contentType) return false;
            return /json|text|javascript|xml/i.test(contentType);
        }

        // Hook XMLHttpRequest.open
        if (window.XMLHttpRequest && XMLHttpRequest.prototype.open) {
            var originalOpen = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function(method, url) {
                try {
                    this.__ssRequestURL = url;
                    report(url);
                } catch (e) {}
                return originalOpen.apply(this, arguments);
            };
        }

        // Hook XMLHttpRequest.send to read the response's content type
        // (the extensionless-manifest path, same rationale as fetch).
        if (window.XMLHttpRequest && XMLHttpRequest.prototype.send) {
            var originalSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.send = function() {
                try {
                    var xhr = this;
                    xhr.addEventListener('load', function() {
                        try {
                            var ct = xhr.getResponseHeader('content-type');
                            reportWithContentType(xhr.__ssRequestURL, ct);
                            // responseText throws on binary responseTypes;
                            // the guard keeps that from becoming noise.
                            if (bodyLooksScannable(ct) &&
                                (xhr.responseType === '' || xhr.responseType === 'text')) {
                                scanBodyForMedia(xhr.responseText);
                            }
                        } catch (e) {}
                    });
                } catch (e) {}
                return originalSend.apply(this, arguments);
            };
        }

        // Hook media element src assignment (native HLS path).
        function hookSrcSetter(proto) {
            try {
                var desc = Object.getOwnPropertyDescriptor(proto, 'src');
                if (!desc || !desc.set) return;
                Object.defineProperty(proto, 'src', {
                    get: desc.get,
                    set: function(value) {
                        try { report(String(value)); } catch (e) {}
                        return desc.set.call(this, value);
                    },
                    configurable: true
                });
            } catch (e) {}
        }
        if (window.HTMLMediaElement) hookSrcSetter(HTMLMediaElement.prototype);
        if (window.HTMLSourceElement) hookSrcSetter(HTMLSourceElement.prototype);

        // Hook setAttribute for src on media/source elements.
        if (window.Element && Element.prototype.setAttribute) {
            var originalSetAttribute = Element.prototype.setAttribute;
            Element.prototype.setAttribute = function(name, value) {
                try {
                    if (String(name).toLowerCase() === 'src' &&
                        (this.tagName === 'VIDEO' || this.tagName === 'AUDIO' || this.tagName === 'SOURCE')) {
                        report(String(value));
                    }
                } catch (e) {}
                return originalSetAttribute.apply(this, arguments);
            };
        }

        // Resource Timing: report every network request the frame
        // makes, regardless of which API issued it (see layer 4 in the
        // docstring). `report` already gates on the URL pattern, so the
        // noise from images/scripts/segments costs one string scan each.
        function reportEntries(entries) {
            try {
                for (var i = 0; i < entries.length; i++) {
                    var e = entries[i];
                    if (e && e.name) report(e.name);
                }
            } catch (e) {}
        }
        try {
            // Grow the buffer before any request lands (we run at
            // document-start): the default cap is small enough that a
            // segment-heavy player could evict the manifest entry
            // before the buffered replay below reads it.
            if (window.performance && performance.setResourceTimingBufferSize) {
                performance.setResourceTimingBufferSize(1000);
            }
            if (window.PerformanceObserver) {
                var po = new PerformanceObserver(function(list) {
                    reportEntries(list.getEntries());
                });
                // `buffered: true` replays entries recorded before this
                // observer attached — important in subframes, whose
                // document may already be loading when we install.
                try {
                    po.observe({ type: 'resource', buffered: true });
                } catch (e) {
                    // Older syntax; no buffered replay, so the explicit
                    // drain below covers it.
                    po.observe({ entryTypes: ['resource'] });
                }
            }
            // Explicit drain, for engines without `buffered` support and
            // as a no-cost backstop when PerformanceObserver is absent.
            if (window.performance && performance.getEntriesByType) {
                reportEntries(performance.getEntriesByType('resource'));
            }
        } catch (e) {}

        // Play controls, by framework convention. Clicking the player's
        // OWN control matters because many players don't create a media
        // element or request a manifest until their handler runs —
        // calling play() on a <video> that doesn't exist yet does
        // nothing. A synthetic click isn't a user gesture for autoplay
        // policy, but it does invoke the player's JS, which is the part
        // we need. (`mediaTypesRequiringUserActionForPlayback` on the
        // native config covers the policy half.)
        var PLAY_SELECTORS = [
            '.vjs-big-play-button',              // video.js
            '.jw-icon-display', '.jw-icon-playback',  // JW Player
            '.plyr__control--overlaid',          // Plyr
            '.bmpui-ui-hugeplaybacktogglebutton',// Bitmovin
            '.shaka-play-button',                // Shaka
            '.flowplayer .fp-play',              // Flowplayer
            '.mejs__overlay-button',             // MediaElement.js
            '[class*="big-play"]', '[class*="play-button"]', '[class*="playButton"]',
            '[class*="poster"][class*="play"]',
            'button[aria-label*="play" i]', '[role="button"][aria-label*="play" i]',
            'button[title*="play" i]', '[data-testid*="play" i]'
        ].join(', ');

        var clicksSpent = 0;
        var MAX_CLICKS = 8;

        function nudgePlayControls() {
            // Once something has been reported the player is fetching;
            // further clicking is needless risk.
            if (postedAny || clicksSpent >= MAX_CLICKS) return;
            var controls;
            try { controls = document.querySelectorAll(PLAY_SELECTORS); } catch (e) { return; }
            for (var i = 0; i < controls.length && clicksSpent < MAX_CLICKS; i++) {
                var el = controls[i];
                if (!el || el.__ssPlayClicked) continue;
                // Never click a link that would navigate away from the
                // page we're extracting from.
                if (el.tagName === 'A') {
                    var href = el.getAttribute('href') || '';
                    if (href && href.charAt(0) !== '#' && href.indexOf('javascript:') !== 0) continue;
                }
                el.__ssPlayClicked = true;
                clicksSpent++;
                // Full pointer/mouse sequence: some players bind
                // pointerdown or mousedown rather than click.
                try {
                    ['pointerdown', 'mousedown', 'mouseup', 'click'].forEach(function(type) {
                        var evt;
                        try {
                            evt = new MouseEvent(type, { bubbles: true, cancelable: true, view: window });
                        } catch (e) {
                            evt = document.createEvent('MouseEvents');
                            evt.initEvent(type, true, true);
                        }
                        el.dispatchEvent(evt);
                    });
                } catch (e) {
                    try { if (el.click) el.click(); } catch (e2) {}
                }
            }
        }

        // Periodic DOM scan + autoplay nudge.
        setInterval(function() {
            try {
                var elements = document.querySelectorAll('video, audio, source');
                for (var i = 0; i < elements.length; i++) {
                    var el = elements[i];
                    if (el.src) report(el.src);
                    if (el.currentSrc) report(el.currentSrc);
                    // Nudge: some players only resolve/load their
                    // stream after a play attempt. Muted play is
                    // permitted without a user gesture.
                    if ((el.tagName === 'VIDEO' || el.tagName === 'AUDIO') && el.paused) {
                        el.muted = true;
                        var p = el.play();
                        if (p && p.catch) p.catch(function() {});
                    }
                }
            } catch (e) {}
            nudgePlayControls();
        }, 500);
    })();
    """
}

// MARK: - WKScriptMessageHandler

extension CriticalMentionBrowserExtractor: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "stream" else { return }
        // The shim posts `{url, tier}`; plain strings are still accepted
        // so the handler stays compatible with any other caller.
        let urlString: String
        var tierRaw = "hls"
        if let dict = message.body as? [String: Any], let u = dict["url"] as? String {
            urlString = u
            if let t = dict["tier"] as? String { tierRaw = t }
        } else if let u = message.body as? String {
            urlString = u
        } else {
            return
        }
        guard let url = URL(string: urlString) else { return }
        let tier: ManifestTier = (tierRaw == "alt") ? .alternative : .hls

        guard let host = url.host?.lowercased() else { return }
        guard url.scheme == "https" || url.scheme == "http" else { return }

        Task { @MainActor [weak self] in
            guard let self, !self.finished else { return }

            // Host filtering is PAGE-AWARE (checked here, on the main
            // actor, where the flag lives). For Critical Mention pages
            // keep the strict CDN filter: stream must be on a
            // `*.criticalmention.com` host (their `assets.` CDN) and
            // not the `app.` host serving the page itself. For other
            // pages routed through this extractor (Granicus), the
            // stream lives on third-party CDNs — Wowza
            // (`cdn*.wowza.com`) most commonly, but deployments vary —
            // so restricting by host would reject the very URL we're
            // after (field bug: the first Granicus attempt captured
            // nothing because a blanket CM-host filter dropped the
            // Wowza playlist). For those pages, the JS-side `.m3u8`
            // match plus the scheme check above is the filter.
            if self.pageIsCriticalMention {
                guard host.hasSuffix("criticalmention.com"),
                      !host.hasPrefix("app.") else { return }
            }

            self.addCandidate(url: url, tier: tier)
        }
    }
}

// MARK: - WKNavigationDelegate

extension CriticalMentionBrowserExtractor: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, !self.finished else { return }
            print("[CriticalMentionBrowser] Page load failed: \(error.localizedDescription)")
            self.finish(result: nil)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, !self.finished else { return }
            print("[CriticalMentionBrowser] Page provisional load failed: \(error.localizedDescription)")
            self.finish(result: nil)
        }
    }
}
