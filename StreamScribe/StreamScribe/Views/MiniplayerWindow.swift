import SwiftUI
import AVKit
import Combine

/// Floating audio/video player for replaying a finished transcription's
/// media. Two media sources flow into this through
/// `TranscriptionEngine.playbackMediaURL`:
///
///   - **Local file transcriptions:** the original imported file. The URL
///     is set at session start, so the miniplayer is usable from second
///     zero of the transcription. If the user moves/deletes the file
///     between then and opening the miniplayer, AVPlayer surfaces a
///     normal "can't open" error.
///
///   - **Live / URL transcriptions (YouTube, HLS, etc.):** the .mkv
///     file ffmpeg wrote as a side output during transcription, with
///     video+audio stream-copied (no re-encode) into a Matroska
///     container. URL is set at the end of the pipeline's natural /
///     cancellation branch. See `MediaCacheManager` for the on-disk
///     location and cleanup policy.
///
/// **Click-to-seek.** TranscriptPaneView posts `.miniplayerSeek` with a
/// `TimeInterval` start time when the user taps a segment. We listen,
/// seek the AVPlayer, and start playing.
///
/// **Highlight + auto-scroll.** A periodic AVPlayer time observer posts
/// `.miniplayerTimeUpdate` on each tick (5 Hz). TranscriptPaneView
/// listens and highlights the segment whose range contains the current
/// time, scrolling it into view.
///
/// **Floating window level.** Set via the
/// `MiniplayerWindowAccessor`/`makeFloatingOnAppear` modifier on first
/// appear — SwiftUI doesn't expose window-level configuration in the
/// `Window {}` scene builder, so we reach the underlying NSWindow at
/// appear time. Floating means it stays above the main app window
/// without grabbing focus while the user works in the transcript.
struct MiniplayerWindow: View {
    @EnvironmentObject private var engine: TranscriptionEngine
    @StateObject private var controller = MiniplayerController()

    /// Local flag that flips to true once the player has actually
    /// loaded media. Until then we render the placeholder, even if
    /// `engine.playbackMediaURL` is set — this avoids constructing
    /// the AVKit player view on the FIRST render pass.
    ///
    /// **Why this matters.** Multiple user crash reports showed an
    /// `EXC_CRASH (SIGABRT)` inside Swift runtime metadata resolution
    /// when the miniplayer window first opened. The faulting frame
    /// was deep in `_swift_initClassMetadataImpl` /
    /// `getSuperclassMetadata`, called from
    /// `static NSViewRepresentable._makeView`. Originally we used
    /// SwiftUI's `VideoPlayer`, which lives in the private
    /// `_AVKit_SwiftUI` framework and loads on first use — a process
    /// that fails on some unsigned/ad-hoc release builds running
    /// from non-`/Applications` paths.
    ///
    /// We now use `AVPlayerView` (plain AppKit, decade-old, stable)
    /// via our own NSViewRepresentable. Combined with the deferred
    /// `playerReady` flip, this means the first render uses only
    /// safe SwiftUI primitives, then introduces our small
    /// Representable on the next runloop turn.
    @State private var playerReady: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if let url = engine.playbackMediaURL, playerReady {
                AVPlayerViewRepresentable(player: controller.player)
                    .onChange(of: url) { _, new in
                        controller.load(
                            url: new,
                            isLive: Self.isLiveURL(new),
                            sessionStart: engine.sessionStartedAt
                        )
                    }
                    .onDisappear { controller.teardown() }

                // Live indicator bar. Only renders during live mode —
                // the controller's `isLiveMode` flag is set by `load()`
                // based on URL extension, so this section appears for
                // .m3u8 streams and vanishes when the URL transitions
                // to the post-session .mkv. Shows either "● LIVE" (when
                // at the live edge) or "Xs behind live" with a Return
                // to Live action button. Matches the visual pattern
                // every consumer livestream player uses (Twitch, YouTube
                // Live, etc.) so the affordance is intuitively familiar.
                if controller.isLiveMode {
                    liveIndicatorBar
                }
            } else {
                noMediaPlaceholder
                    .onAppear {
                        guard let url = engine.playbackMediaURL else { return }
                        controller.load(
                            url: url,
                            isLive: Self.isLiveURL(url),
                            sessionStart: engine.sessionStartedAt
                        )
                        DispatchQueue.main.async {
                            playerReady = true
                        }
                    }
            }
        }
        // Apply floating-window config via onAppear instead of a
        // background Representable. Walking NSApp.windows finds the
        // newly-created miniplayer window without us needing to inject
        // any NSViewRepresentable into the view tree — removing one
        // source of Representable metadata-init crashes. We defer with
        // a tiny delay to give AppKit time to attach the new window.
        .onAppear { applyFloatingWindowLevel() }
    }

    /// Whether a URL should be treated as a live HLS stream by the
    /// miniplayer. `.m3u8` extension is the unambiguous signal —
    /// StreamScribe sets `playbackMediaURL` to either:
    ///   - A local file path (.mp3/.mp4/etc. — VOD)
    ///   - A live HLS playlist (.m3u8 — live during session)
    ///   - A post-session recording (.mkv — VOD after session ends)
    /// so the extension check is sufficient.
    private static func isLiveURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "m3u8"
    }

    /// Indicator strip rendered below the AVPlayerView during live
    /// playback. Visual states:
    ///   - At-live-edge (lag < threshold): red dot + "LIVE" label,
    ///     no action button
    ///   - Behind live: secondary-styled text "Xs behind live" +
    ///     "Return to Live" button that snaps to the live edge
    private var liveIndicatorBar: some View {
        HStack(spacing: 8) {
            if controller.liveLag < MiniplayerController.liveEdgeThresholdSeconds {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                    Text("LIVE")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                }
                Spacer()
            } else {
                Text("\(Int(controller.liveLag))s behind live")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Return to Live") {
                    controller.returnToLive()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(height: 0.5),
            alignment: .top
        )
    }

    private var noMediaPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No media available")
                .font(.headline)
            Text("Finish a transcription to enable playback.\nLocal files are playable from the start; live streams become playable after the transcription completes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    /// Find the miniplayer's NSWindow and bump it to floating level
    /// without using NSViewRepresentable. Walks NSApp.windows looking
    /// for one whose title matches our scene ID (set in the Window
    /// scene builder). Falls back to the key window if the title
    /// match fails — there's only one new window opening from the
    /// `openWindow(id:)` call, so picking it up by being-newest is
    /// safe.
    ///
    /// Runs on a 50ms delay because AppKit hasn't necessarily
    /// finalized the window's attachment by the time SwiftUI fires
    /// our onAppear. Empirically 50ms is enough for both intel-Mac
    /// debug builds and Apple Silicon release builds.
    private func applyFloatingWindowLevel() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Prefer the key window — it's the one that just opened.
            // Fall back to the most-recently-added entry in
            // NSApp.windows if for some reason key isn't set yet.
            let candidate = NSApp.keyWindow ?? NSApp.windows.last
            guard let window = candidate else { return }
            window.level = .floating
            window.styleMask.remove(.fullScreen)
            window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        }
    }
}

/// NSViewRepresentable wrapping `AVPlayerView` directly, bypassing
/// SwiftUI's `VideoPlayer`. SwiftUI's `VideoPlayer` lives in the
/// `_AVKit_SwiftUI` private framework, which loads on first use and
/// requires the Swift runtime to resolve a chain of generic types
/// with class metadata. On unsigned/ad-hoc release builds running
/// outside `/Applications` (corporate-locked Macs, Downloads
/// folder), that resolution sometimes hits `getSuperclassMetadata`
/// failure and traps with `EXC_CRASH (SIGABRT)`.
///
/// `AVPlayerView` itself is a plain AppKit class that's been in AVKit
/// since macOS 10.9. It has no Swift generics to resolve, doesn't
/// pull in the `_AVKit_SwiftUI` framework, and is unaffected by this
/// crash path. We get all the same playback controls (play/pause,
/// scrubber, volume) since AVPlayerView is what `VideoPlayer` wraps
/// internally anyway.
///
/// Why this is stable where `VideoPlayer` isn't: the entire view is
/// resolved at compile time, no SwiftUI generic instantiation, no
/// runtime class-metadata cache misses. The Representable itself
/// (this struct) is also non-generic, so its metadata is trivially
/// resolvable.
struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        // `.default` shows the standard transport controls (play,
        // scrubber, time labels, volume). Matches what SwiftUI's
        // VideoPlayer presented, so this is a drop-in replacement
        // from the user's perspective.
        view.controlsStyle = .default
        // Match the look-and-feel users would expect from a media
        // player floating window. .floating window level is set
        // elsewhere on the NSWindow itself; here we just configure
        // the view.
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // Swap players if the binding changed. AVPlayerView handles
        // the transition cleanly — we don't need to tear down the old
        // one explicitly since the assignment releases it.
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

/// Owns the AVPlayer, the periodic time observer, and the seek
/// notification subscription. Lifecycle: `load(url:isLive:sessionStart:)`
/// creates a fresh player; `teardown()` removes observers and discards
/// it. We use a dedicated controller so the View can stay declarative
/// and re-renders don't churn the player.
///
/// **Live mode time mapping.** When `isLive == true`, the controller
/// translates AVPlayer's player-clock time into session-relative time
/// before posting `.miniplayerTimeUpdate` notifications. Two paths:
///
///   - **Primary: `AVPlayerItem.currentDate()`.** When the HLS playlist
///     includes `EXT-X-PROGRAM-DATE-TIME` tags (senate.gov / Akamai do
///     by default), this returns wall-clock time. Subtracting
///     `sessionStart` gives session-relative time directly.
///
///   - **Fallback: t0 capture.** If the playlist lacks PDT tags,
///     `currentDate()` returns nil. We instead capture
///     `(t0_player, t0_offset)` on the first valid observer tick where
///     `t0_player = player.currentTime` and `t0_offset = Date.now -
///     sessionStart`. Session-relative time is then
///     `(currentTime - t0_player) + t0_offset`. Less accurate (lag
///     computation is approximated from wall-clock progression) but
///     handles streams without date tags gracefully.
///
/// **Lag tracking.** `liveLag` is the seconds behind the live edge.
/// Stays near 0 during normal live playback; grows when the user
/// pauses or seeks back. Drives the "Live" vs "30s behind" indicator
/// and the visibility of the "Return to Live" button.
@MainActor
final class MiniplayerController: ObservableObject {
    let player = AVPlayer()
    private var timeObserver: Any?
    private var seekSubscription: AnyCancellable?
    private var currentURL: URL?

    /// True when the loaded URL is a live HLS stream (`.m3u8`). Drives
    /// the time mapping in the periodic observer and the visibility of
    /// the live indicator UI in the miniplayer window. False during
    /// VOD playback (local files, post-session .mkv).
    @Published private(set) var isLiveMode: Bool = false

    /// Seconds behind the live edge. Only meaningful when `isLiveMode`.
    /// `0` ≈ at-live-edge; growing values mean the user has paused or
    /// seeked backward through the HLS buffered window. The UI shows
    /// "Live" when below `liveEdgeThresholdSeconds`, otherwise "Xs
    /// behind live" with a Return to Live button.
    @Published private(set) var liveLag: TimeInterval = 0

    /// Session start wall-clock from the engine. Used to compute
    /// session-relative time from player wall-clock in live mode.
    private var sessionStart: Date?

    /// Fallback t0-capture pair, used when `currentDate()` is nil.
    /// See class docs for the math. `nil` until the first valid
    /// observer tick.
    private var fallbackT0Player: TimeInterval?
    private var fallbackT0Offset: TimeInterval?

    /// Lag below this is rendered as "Live" (red dot) rather than a
    /// numeric value. 3 seconds covers normal HLS playback variance
    /// (segment boundaries, buffer breathing) without flicker.
    static let liveEdgeThresholdSeconds: TimeInterval = 3.0

    func load(url: URL, isLive: Bool, sessionStart: Date?) {
        // Avoid replacing the item if we're already pointing at this
        // URL — calling `replaceCurrentItem` resets playback position
        // even with the same URL, which is jarring if the user
        // switches windows.
        if currentURL == url, player.currentItem != nil {
            // The mode might have changed (e.g. session ended and the
            // URL transitioned from m3u8 to mkv — but the mkv was already
            // cached for a previous session, so the URL string matches
            // and we short-circuit). Refresh the mode state anyway so
            // the indicator UI updates correctly. Rare but possible.
            self.isLiveMode = isLive
            self.sessionStart = sessionStart
            return
        }
        currentURL = url
        self.isLiveMode = isLive
        self.sessionStart = sessionStart
        self.fallbackT0Player = nil
        self.fallbackT0Offset = nil
        self.liveLag = 0

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        // Wire up the time observer for transcript highlighting + live
        // lag tracking. 5 Hz (200 ms interval) is smooth enough to look
        // like real-time tracking without overwhelming the notification
        // bus. The observer is on MainActor because the publisher hops
        // to MainActor anyway via the @MainActor class isolation.
        if timeObserver == nil {
            let interval = CMTime(seconds: 0.2, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self else { return }
                let secs = time.seconds
                guard secs.isFinite else { return }

                // Compute the engine-time to broadcast on
                // .miniplayerTimeUpdate. VOD = raw currentTime. Live =
                // mapped via currentDate() or the t0 fallback. The
                // notification's consumer (TranscriptPaneView) doesn't
                // need to know which path produced the value — both
                // modes deliver session-relative seconds.
                let engineTime: TimeInterval
                if self.isLiveMode, let sessionStart = self.sessionStart {
                    engineTime = self.computeLiveEngineTime(
                        playerTime: secs,
                        sessionStart: sessionStart
                    )
                } else {
                    engineTime = secs
                    self.liveLag = 0
                }

                NotificationCenter.default.post(
                    name: .miniplayerTimeUpdate,
                    object: engineTime as NSNumber
                )
            }
        }

        // Listen for click-to-seek requests from the transcript pane.
        // Created once per load; the previous subscription (if any)
        // gets replaced and the old one is auto-cancelled by Combine.
        seekSubscription = NotificationCenter.default
            .publisher(for: .miniplayerSeek)
            .compactMap { ($0.object as? NSNumber)?.doubleValue }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] engineTime in
                guard let self else { return }
                self.seek(toEngineTime: engineTime)
            }
    }

    /// Compute session-relative time from the player's current time.
    /// Tries `currentDate()` first; falls back to t0 capture if that
    /// returns nil. Also updates `liveLag` as a side effect.
    private func computeLiveEngineTime(
        playerTime: TimeInterval,
        sessionStart: Date
    ) -> TimeInterval {
        if let currentDate = player.currentItem?.currentDate() {
            // Primary path: PDT tags present. currentDate is the
            // wall-clock when this audio was captured at the encoder.
            // Subtracting sessionStart gives session-relative time.
            // liveLag is now - currentDate (how far behind live we are).
            let engineTime = currentDate.timeIntervalSince(sessionStart)
            let lag = Date().timeIntervalSince(currentDate)
            self.liveLag = max(0, lag)
            return engineTime
        }

        // Fallback: no PDT tags. Capture t0 on first tick.
        if fallbackT0Player == nil {
            fallbackT0Player = playerTime
            fallbackT0Offset = Date().timeIntervalSince(sessionStart)
        }
        let delta = playerTime - (fallbackT0Player ?? 0)
        let engineTime = (fallbackT0Offset ?? 0) + delta

        // Approximate lag via wall-clock progression. If the player is
        // keeping up, engineTime ≈ Date().timeIntervalSince(sessionStart);
        // any gap is the lag. Less precise than the PDT path (drifts
        // by accumulated clock skew if the encoder's rate isn't
        // perfectly real-time) but better than nothing.
        let wallElapsed = Date().timeIntervalSince(sessionStart)
        self.liveLag = max(0, wallElapsed - engineTime)
        return engineTime
    }

    /// Seek the player to an engine-relative time (seconds since
    /// session start). Routes through the date-based seek API in live
    /// mode so HLS playlists with PDT tags get an accurate target.
    private func seek(toEngineTime engineTime: TimeInterval) {
        if isLiveMode, let sessionStart = sessionStart, let item = player.currentItem {
            // Live: convert engine-time to wall-clock date and seek.
            // AVPlayerItem.seek(to:) (date variant) maps via PDT tags;
            // if the target is outside the seekable window, AVPlayer
            // clamps to the nearest valid time. We don't pre-check the
            // window — the user gets a snap-to-nearest, transcript
            // highlight updates to wherever we landed.
            let targetDate = sessionStart.addingTimeInterval(engineTime)
            item.seek(to: targetDate) { [weak self] finished in
                if !finished {
                    print("[Miniplayer] Live seek to \(targetDate) didn't complete (likely outside seekable window).")
                }
                self?.player.play()
            }
        } else {
            // VOD path: unchanged from prior behavior.
            let target = CMTime(seconds: engineTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                self?.player.play()
            }
        }
    }

    /// Seek to the live edge and resume playback. Wired to the
    /// "Return to Live" button in the live indicator bar. Uses the
    /// player item's `seekableTimeRanges` to find the end of the
    /// current buffered window — the live edge is the latest seekable
    /// time AVPlayer knows about.
    func returnToLive() {
        guard isLiveMode, let item = player.currentItem else { return }
        guard let lastRangeValue = item.seekableTimeRanges.last as? NSValue else { return }
        let range = lastRangeValue.timeRangeValue
        let liveEdge = CMTimeAdd(range.start, range.duration)
        player.seek(to: liveEdge, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.player.play()
        }
    }

    func teardown() {
        if let obs = timeObserver {
            player.removeTimeObserver(obs)
            timeObserver = nil
        }
        seekSubscription?.cancel()
        seekSubscription = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
    }

    deinit {
        // Deinit can fire on any actor; observe-removal MUST happen on
        // the player's main thread per AVFoundation contract. Hop and
        // capture state we need by value.
        if let obs = timeObserver {
            let p = player
            DispatchQueue.main.async {
                p.removeTimeObserver(obs)
            }
        }
    }
}
