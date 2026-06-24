import Foundation
import WebKit

/// Browser-based m3u8 extractor for senate.gov hearing pages. Replaces
/// the HTML-scraping approach that we kept patching with more
/// strategies and still ended up brittle.
///
/// **Why a real browser engine.** Modern committee sites (HSGAC, others)
/// don't embed the stream URL in static HTML. They render a player
/// container at page load, then run JavaScript that fetches the URL
/// from an API and initializes a video player with it. HTML scraping
/// never sees that URL because it doesn't exist until JS runs. The
/// fundamental fix is to let JS run, then capture the URL the way a
/// browser DevTools network tab does.
///
/// **How it works.**
///   1. Create an off-screen WKWebView
///   2. Inject a tiny JS shim before any page script runs that overrides
///      `window.fetch` and `XMLHttpRequest.open` to report URLs back to
///      native code via `window.webkit.messageHandlers.m3u8.postMessage`
///   3. Load the senate.gov page URL
///   4. When the shim reports an m3u8 URL on a senate.gov CDN host,
///      capture it and tear down the WKWebView
///   5. If no m3u8 URL appears within the timeout (10 s), give up and
///      return nil
///
/// **Performance.** Page load + JS execution is ~2-3 s on a healthy
/// network. Slower than the old HTML-scraping path (<1 s) but reliable
/// in the cases the HTML path keeps failing on. Worth it for the
/// "works every time" property — see the rejected alternatives in
/// the file header comment.
///
/// **Lifecycle.** Single-shot: each `resolve()` call creates its own
/// WKWebView, loads the page, captures or times out, then tears down.
/// No retained state between calls. Safe to call from any context;
/// internally hops to MainActor for the WKWebView (which is
/// main-actor-bound by AppKit/WebKit convention).
///
/// **Rejected alternatives:**
///   - **HTML scraping (the old path):** Doesn't see URLs injected
///     by JavaScript at runtime. Each new committee site that
///     migrates to a JS-based player breaks it again.
///   - **yt-dlp:** Has its own senate.gov extractor but also uses
///     HTML scraping; runs into the same problem on newer sites.
///   - **WKContentRuleList:** Apple's content blocker API. Can
///     redirect or block requests, but can't OBSERVE them, which is
///     what we need.
///   - **Custom URLProtocol:** Deprecated for WKWebView since iOS 8;
///     doesn't work for sub-resources anyway.
///   - **Headless Chrome / Puppeteer-style:** Requires shipping a
///     separate Chromium binary. WKWebView is built into macOS and
///     uses no extra disk space, RAM, or maintenance burden.
@MainActor
final class SenateGovBrowserExtractor: NSObject {

    /// Resolve a senate.gov hearing page URL to its m3u8 stream URL.
    /// Returns nil if no stream URL is observed within `timeout` seconds.
    ///
    /// The returned URL is suitable for direct ffmpeg probing and
    /// playback — it's the actual master playlist URL the page's
    /// player would load, not a synthesized URL from a committee
    /// mapping table.
    static func resolve(pageURL: URL, timeout: TimeInterval = 10) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            Task { @MainActor in
                let extractor = SenateGovBrowserExtractor()
                extractor.start(pageURL: pageURL, timeout: timeout) { result in
                    continuation.resume(returning: result)
                }
            }
        }
    }

    // MARK: - Instance state

    private var webView: WKWebView?
    private var completion: ((URL?) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    private override init() { super.init() }

    private func start(pageURL: URL, timeout: TimeInterval, completion: @escaping (URL?) -> Void) {
        self.completion = completion

        let config = WKWebViewConfiguration()

        // Inject the URL-observation shim before any page script runs.
        // The shim overrides fetch + XMLHttpRequest.open to report any
        // URL containing ".m3u8" back to native code. This is the
        // standard pattern for observing in-page network activity from
        // WKWebView — there's no Apple API to do this directly.
        //
        // The shim is defensive about preserving original behavior:
        // it calls through to the originals so the page continues to
        // function normally. We don't actually want to interrupt the
        // page's load flow, just listen.
        let interceptScript = WKUserScript(
            source: Self.observerJavaScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(interceptScript)
        config.userContentController.add(self, name: "m3u8")

        // WKWebView with zero frame: never gets attached to a window,
        // never shows on screen. WebKit still loads + executes the
        // page contents because that's tied to the data store, not
        // the visual hierarchy.
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        self.webView = webView

        // Timeout. If the JS shim never reports an m3u8 URL within
        // this window, give up and let the caller fall back to
        // whatever they're going to do (yt-dlp probe, surface error
        // to user, etc.).
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await MainActor.run {
                guard let self, !self.finished else { return }
                print("[SenateGovBrowser] Timeout after \(Int(timeout))s waiting for m3u8 URL — page may have failed to load or doesn't fetch an m3u8.")
                self.finish(url: nil)
            }
        }

        // Add a realistic user agent. senate.gov pages occasionally
        // serve different content to identified bots vs browsers.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        print("[SenateGovBrowser] Loading \(pageURL.absoluteString) in headless WKWebView…")
        webView.load(URLRequest(url: pageURL))
    }

    /// Finish the extraction, deliver the result, and tear down. Idempotent
    /// (only the first call delivers the result; subsequent calls no-op).
    private func finish(url: URL?) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil

        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeAllUserScripts()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "m3u8")
        webView = nil

        let cb = completion
        completion = nil
        cb?(url)
    }

    // MARK: - The injected JavaScript

    /// JS shim that overrides `fetch` and `XMLHttpRequest.open` to
    /// report URLs containing ".m3u8" back to native code via the
    /// `m3u8` script message handler. Defensive about preserving
    /// original function behavior — wraps calls rather than replacing
    /// them outright.
    ///
    /// Why both fetch and XHR: depends on the player library. Modern
    /// players (Bitmovin, hls.js, video.js) typically use fetch();
    /// older ones use XHR. We hook both to cover all cases.
    ///
    /// The "report only if URL contains .m3u8" filter keeps signal
    /// high — we don't care about font/image/JSON-config requests,
    /// only the actual stream URLs. The native side does additional
    /// filtering for the senate.gov-specific CDN hosts.
    private static let observerJavaScript = """
    (function() {
        function report(url) {
            try {
                if (typeof url === 'string' && url.indexOf('.m3u8') !== -1) {
                    window.webkit.messageHandlers.m3u8.postMessage(url);
                }
            } catch (e) {
                // Message handler not attached or page tore down — ignore.
            }
        }

        // Hook fetch
        if (window.fetch) {
            var originalFetch = window.fetch;
            window.fetch = function() {
                try {
                    var arg = arguments[0];
                    var url = (typeof arg === 'string') ? arg : (arg && arg.url);
                    report(url);
                } catch (e) {}
                return originalFetch.apply(this, arguments);
            };
        }

        // Hook XMLHttpRequest.open
        if (window.XMLHttpRequest) {
            var originalOpen = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function(method, url) {
                try { report(url); } catch (e) {}
                return originalOpen.apply(this, arguments);
            };
        }

        // Hook HTMLMediaElement src setter — covers <video src="..."> too,
        // which some sites use without a wrapping player library.
        try {
            var srcDescriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
            if (srcDescriptor && srcDescriptor.set) {
                var originalSrcSetter = srcDescriptor.set;
                Object.defineProperty(HTMLMediaElement.prototype, 'src', {
                    set: function(value) {
                        try { report(value); } catch (e) {}
                        return originalSrcSetter.call(this, value);
                    },
                    get: srcDescriptor.get
                });
            }
        } catch (e) {}
    })();
    """
}

// MARK: - WKScriptMessageHandler — receive URL reports from injected JS

extension SenateGovBrowserExtractor: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "m3u8",
              let urlString = message.body as? String,
              let url = URL(string: urlString) else { return }

        // Filter for senate.gov CDN hosts. The injected JS reports
        // ANY URL containing ".m3u8" — could include third-party
        // analytics, ad players, embedded social media videos, etc.
        // We only want senate.gov's actual stream URLs.
        guard let host = url.host?.lowercased() else { return }
        let isSenateStream = host.contains("akamaized.net")
            || host.contains("akamaihd.net")
            || host.contains("senate.gov")
        guard isSenateStream else { return }

        Task { @MainActor [weak self] in
            guard let self, !self.finished else { return }
            print("[SenateGovBrowser] Captured m3u8 URL: \(url.absoluteString)")
            self.finish(url: url)
        }
    }
}

// MARK: - WKNavigationDelegate — handle page load failures

extension SenateGovBrowserExtractor: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, !self.finished else { return }
            print("[SenateGovBrowser] Page load failed: \(error.localizedDescription)")
            self.finish(url: nil)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, !self.finished else { return }
            print("[SenateGovBrowser] Page provisional load failed: \(error.localizedDescription)")
            self.finish(url: nil)
        }
    }
}
