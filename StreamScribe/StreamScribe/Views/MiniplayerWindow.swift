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
                    .onChange(of: url) { _, new in controller.load(url: new) }
                    .onDisappear { controller.teardown() }
            } else {
                noMediaPlaceholder
                    .onAppear {
                        guard let url = engine.playbackMediaURL else { return }
                        controller.load(url: url)
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
/// notification subscription. Lifecycle: `load(url:)` creates a fresh
/// player; `teardown()` removes observers and discards it. We use a
/// dedicated controller so the View can stay declarative and re-renders
/// don't churn the player.
@MainActor
final class MiniplayerController: ObservableObject {
    let player = AVPlayer()
    private var timeObserver: Any?
    private var seekSubscription: AnyCancellable?
    private var currentURL: URL?

    func load(url: URL) {
        // Avoid replacing the item if we're already pointing at this
        // URL — calling `replaceCurrentItem` resets playback position
        // even with the same URL, which is jarring if the user
        // switches windows.
        if currentURL == url, player.currentItem != nil { return }
        currentURL = url

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        // Wire up the time observer for transcript highlighting. 5 Hz
        // is smooth enough to look like real-time tracking without
        // overwhelming the notification bus. The observer is on
        // MainActor because the publisher hops to MainActor anyway via
        // the @MainActor class isolation.
        if timeObserver == nil {
            let interval = CMTime(seconds: 0.2, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
                let secs = time.seconds
                guard secs.isFinite else { return }
                NotificationCenter.default.post(
                    name: .miniplayerTimeUpdate,
                    object: secs as NSNumber
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
            .sink { [weak self] seconds in
                guard let self else { return }
                let target = CMTime(seconds: seconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    self.player.play()
                }
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
