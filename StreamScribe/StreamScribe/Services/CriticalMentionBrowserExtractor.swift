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
                print("[CriticalMentionBrowser] Timeout after \(Int(timeout))s waiting for stream URL — page may have failed to load or clip is private.")
                self.finish(result: nil)
            }
        }

        // Modern browser UA. Critical Mention's page occasionally
        // serves different bundles based on UA sniffing.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        print("[CriticalMentionBrowser] Loading \(pageURL.absoluteString) in headless WKWebView…")
        webView.load(URLRequest(url: pageURL))
    }

    private func finish(result: ExtractionResult?) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil

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
    ///      scan also nudges paused players with a muted `play()`,
    ///      since some players only resolve their stream URL after a
    ///      play attempt.
    ///
    /// URL match: contains `.m3u8` (standard) or `fmt=m3u8`
    /// (Critical Mention's stream.php convention).
    private static let observerJavaScript = """
    (function() {
        function report(url) {
            try {
                if (typeof url === 'string' &&
                    (url.indexOf('.m3u8') !== -1 || url.indexOf('fmt=m3u8') !== -1)) {
                    window.webkit.messageHandlers.stream.postMessage(url);
                }
            } catch (e) {
                // Message handler not attached — ignore.
            }
        }

        // Hook fetch
        if (window.fetch) {
            var originalFetch = window.fetch;
            window.fetch = function(input, init) {
                try {
                    var url = typeof input === 'string' ? input : (input && input.url);
                    if (url) report(url);
                } catch (e) {}
                return originalFetch.apply(this, arguments);
            };
        }

        // Hook XMLHttpRequest.open
        if (window.XMLHttpRequest && XMLHttpRequest.prototype.open) {
            var originalOpen = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function(method, url) {
                try { report(url); } catch (e) {}
                return originalOpen.apply(this, arguments);
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
        }, 500);
    })();
    """
}

// MARK: - WKScriptMessageHandler

extension CriticalMentionBrowserExtractor: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "stream",
              let urlString = message.body as? String,
              let url = URL(string: urlString) else { return }

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

            let rawTitle = self.webView?.title
            let pageTitle = (rawTitle?.isEmpty == false) ? rawTitle : nil

            print("[CriticalMentionBrowser] Captured stream URL: \(url.absoluteString)\(pageTitle.map { " — title: \"\($0)\"" } ?? "")")
            self.finish(result: ExtractionResult(streamURL: url, pageTitle: pageTitle))
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
