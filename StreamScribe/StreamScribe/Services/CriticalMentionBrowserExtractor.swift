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

    private override init() { super.init() }

    private func start(pageURL: URL, timeout: TimeInterval, completion: @escaping (ExtractionResult?) -> Void) {
        self.completion = completion

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

    /// JS shim overriding `fetch` and `XMLHttpRequest.open` to report
    /// stream URLs back to native code via the `stream` message
    /// handler. Matches TWO patterns:
    ///
    ///   1. URL contains `.m3u8` (standard HLS convention)
    ///   2. URL contains `fmt=m3u8` (Critical Mention's convention —
    ///      stream.php serves HLS content but the URL path doesn't
    ///      end in .m3u8, only the query param signals it)
    ///
    /// Native side filters further by host (must be criticalmention.com)
    /// so third-party network calls (analytics, embedded video from
    /// other domains) don't trigger false positives.
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
    })();
    """
}

// MARK: - WKScriptMessageHandler

extension CriticalMentionBrowserExtractor: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "stream",
              let urlString = message.body as? String,
              let url = URL(string: urlString) else { return }

        // Filter for Critical Mention CDN hosts. Reported URLs also
        // include the app.criticalmention.com API calls (which contain
        // "m3u8" in their JSON responses' URL fields — the JS shim
        // sees the outbound request URLs, not response bodies, so this
        // is unlikely, but defensive).
        //
        // The CDN pattern observed is `<subdomain>.assets.criticalmention.com`
        // (e.g. `atl102.assets.criticalmention.com`). Match on the
        // `criticalmention.com` suffix to catch any subdomain variation.
        guard let host = url.host?.lowercased() else { return }
        guard host.hasSuffix("criticalmention.com") else { return }

        // Additional safety: the actual stream URL will be on an
        // `assets.` subdomain, not `app.`. The page itself lives at
        // `app.criticalmention.com` and its own JS bundle URLs would
        // NOT contain .m3u8 / fmt=m3u8 — but be defensive.
        guard !host.hasPrefix("app.") else { return }

        Task { @MainActor [weak self] in
            guard let self, !self.finished else { return }
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
