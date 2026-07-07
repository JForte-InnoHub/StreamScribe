import SwiftUI
import AppKit

struct TranscriptPaneView: View {
    @EnvironmentObject var engine: TranscriptionEngine
    @Environment(\.openWindow) private var openWindow
    @Binding var openRightPanel: ContentView.RightPanel?
    @Binding var scrollToSegmentID: UUID?
    @State private var autoScroll: Bool = true

    /// Most recently scrolled-to group ID. Used to dedupe redundant
    /// scroll animations driven by `playingSegmentID` changes —
    /// without this, AVPlayer's post-seek time oscillation flips the
    /// playing segment between adjacent segments of the same group,
    /// each flip triggering a fresh scroll animation that interrupts
    /// the previous one, producing visible jitter in the transcript.
    ///
    /// Group IDs are stable (assigned from the group's first segment's
    /// UUID), so comparing the new target against this cached value
    /// catches within-group oscillation cleanly. Cross-group oscillation
    /// is rare in practice — groups are typically 30+ seconds long,
    /// while AVPlayer post-seek oscillation is under a second.
    @State private var lastScrolledPlayheadSegmentID: UUID? = nil

    /// Debounce task for playing-segment scroll updates. Cancelled and
    /// re-scheduled on every new `playingSegmentID` change. Fires the
    /// actual scroll only after ~120ms of quiet, so rapid updates
    /// during miniplayer scrubbing collapse into a single scroll
    /// rather than triggering dozens of overlapping animations. See
    /// `handlePlayingSegmentChange` docstring for the full rationale.
    @State private var pendingScrollTask: Task<Void, Never>? = nil

    /// The transcript ScrollView's backing NSScrollView, captured via
    /// `ScrollViewGrabber` in the content. Used to scope the
    /// `willStartLiveScrollNotification` observer to OUR scroll view —
    /// without this comparison, scrolling the sidebar (or any other
    /// scrollable in the window) would also suspend Follow.
    @State private var transcriptNSScrollView: NSScrollView? = nil

    /// Live-scroll notifications are ignored until this instant.
    /// Every programmatic scroll (playhead follow, tail follow,
    /// pin-jump, Follow snap-back) opens a suppression window slightly
    /// longer than its animation, because SwiftUI's animated
    /// `scrollTo` on macOS can drive the backing NSScrollView through
    /// machinery that posts `willStartLiveScrollNotification` — i.e.
    /// our own scrolls can masquerade as user scrolls. Without the
    /// window, the first playhead scroll suspends Follow itself and
    /// every subsequent jump silently does nothing.
    @State private var suppressLiveScrollUntil: Date = .distantPast
    @State private var searchText: String = ""

    /// Current miniplayer playback time in seconds. Driven by
    /// `.miniplayerTimeUpdate` notifications posted from
    /// MiniplayerWindow's periodic time observer. nil when no
    /// miniplayer is active (or it's paused at 0 — same visual
    /// effect either way: no highlight).
    @State private var playbackTime: TimeInterval?

    /// The segment ID currently containing `playbackTime`, computed on
    /// each tick. Used by SpeakerGroupView to highlight the playing
    /// segment and by the auto-scroll logic to keep it in view.
    @State private var playingSegmentID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header

            // Thin progress bar visible only when transcribing a static source.
            // For live streams progressFraction is nil and the bar is hidden.
            if let progress = engine.progressFraction, engine.state.isActive {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(height: 2)
                    .tint(.accentColor)
            } else {
                Divider()
            }

            if engine.segments.isEmpty {
                emptyState
            } else {
                transcriptScrollView
            }
        }
        .background(transcriptBackground)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft")
                    .foregroundStyle(.secondary)
                Text("Transcript")
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize()  // never truncate the section label itself

                // Show the detected title (YouTube name, podcast episode,
                // filename, etc.) next to the header label. Renders as a
                // subdued secondary line so it doesn't compete with the
                // "Transcript" label visually but is still immediately
                // legible. Hidden when no title was detected (HLS / direct
                // audio sources).
                //
                // The title can be very long — full sentence-length panel
                // discussion names, Senate hearing descriptions, etc.
                // `lineLimit(1)` + tail truncation lets it shrink before
                // the search box / toggles on the right do. Hovering shows
                // the full title via the help tooltip — `.help()` works
                // on any view on macOS with no extra UI machinery.
                if let title = engine.detectedTitle, !title.isEmpty {
                    Text("·")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 13))
                        .fixedSize()
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(title)
                }
            }

            Spacer()

            if !engine.segments.isEmpty {
                TextField("Search transcript…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .font(.system(size: 11))

                Toggle(isOn: $autoScroll) {
                    Label("Follow", systemImage: "arrow.down.to.line")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11))
                }
                .toggleStyle(.button)
                .controlSize(.small)
            }

            // Right-panel toggles. Two buttons, mutually exclusive.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    openRightPanel = (openRightPanel == .speakers) ? nil : .speakers
                }
            } label: {
                Image(systemName: openRightPanel == .speakers ? "person.2.fill" : "person.2")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help(openRightPanel == .speakers ? "Hide speaker panel" : "Show speaker panel")
            .disabled(engine.distinctMachineSpeakers.isEmpty)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    openRightPanel = (openRightPanel == .pins) ? nil : .pins
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: openRightPanel == .pins ? "pin.fill" : "pin")
                        .font(.system(size: 12))
                    // Small badge with the pin count, only when there are pins.
                    if !engine.pinnedQuotes.isEmpty {
                        Text("\(engine.pinnedQuotes.count)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange))
                            .offset(x: 8, y: -6)
                    }
                }
            }
            .buttonStyle(.borderless)
            .help(openRightPanel == .pins ? "Hide pinned quotes" : "Show pinned quotes")

            // Miniplayer toggle. Disabled when there's no playable
            // media (i.e. before a transcription finishes or when the
            // user hasn't started one). Opens the floating miniplayer
            // window which can also be opened from the Window menu /
            // ⌘⇧P.
            Button {
                openWindow(id: WindowID.miniplayer)
            } label: {
                Image(systemName: "play.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help(engine.playbackMediaURL == nil
                  ? "Miniplayer (available after transcription finishes)"
                  : "Open miniplayer")
            .disabled(engine.playbackMediaURL == nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.path")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.tertiary)

            VStack(spacing: 6) {
                Text("Ready to transcribe")
                    .font(.system(size: 18, weight: .medium, design: .serif))
                Text(LocalizedStringKey("Paste a URL, drop a file anywhere on the window,\nor pick one with the **Choose File…** button."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 6) {
                acceptedSourceRow(icon: "doc.fill", text: "Local audio/video — mp3, wav, mp4, mov, mkv, …")
                acceptedSourceRow(icon: "play.rectangle", text: "YouTube video or livestream URL")
                acceptedSourceRow(icon: "antenna.radiowaves.left.and.right", text: "HLS playlist (.m3u8)")
                acceptedSourceRow(icon: "waveform", text: "Direct audio URL")
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func acceptedSourceRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Transcript

    private var transcriptScrollView: some View {
        ScrollViewReader { proxy in
            scrollContent
                .onChange(of: engine.segments.count) { _, _ in
                    guard autoScroll else { return }
                    performProgrammaticScroll(proxy, to: "BOTTOM", anchor: .bottom, duration: 0.25)
                }
                .onChange(of: scrollToSegmentID) { _, newValue in
                    handleScrollToSegmentRequest(newValue, proxy: proxy)
                }
                .onChange(of: playingSegmentID) { _, newID in
                    handlePlayingSegmentChange(newID, proxy: proxy)
                }
                .onChange(of: autoScroll, initial: true) { _, newValue in
                    engine.userIsFollowingTranscript = newValue
                    // Re-enabling Follow snaps back to wherever the
                    // playhead currently is. Clearing the dedupe
                    // anchor first is essential: the last playback
                    // scroll may have targeted the same group we're
                    // in now, and without the reset the snap-back
                    // would be deduped away.
                    if newValue {
                        lastScrolledPlayheadSegmentID = nil
                        if let segID = playingSegmentID {
                            handlePlayingSegmentChange(segID, proxy: proxy)
                        }
                    }
                }
                // Manual-scroll detection: a user-initiated scroll
                // gesture suspends Follow so playback updates don't
                // yank the transcript away from wherever they scrolled
                // to read. The Follow button visibly flips off, making
                // the suspension discoverable and the remedy obvious
                // (click Follow to resume).
                //
                // Implemented via AppKit's live-scroll notifications
                // rather than SwiftUI's `onScrollPhaseChange`: the
                // SwiftUI modifier changes how the backing NSScrollView
                // routes events, which broke the tap-to-seek gestures
                // on the transcript rows (taps stopped reaching the
                // miniplayer-seek handler). `willStartLiveScroll` is
                // purely observational — posted only for USER scroll
                // gestures, never for programmatic `scrollTo` — so it
                // can't interfere with anything. The object comparison
                // scopes it to the transcript's own scroll view; other
                // scrollables (sidebar, settings) don't suspend Follow.
                .onReceive(NotificationCenter.default.publisher(
                    for: NSScrollView.willStartLiveScrollNotification
                )) { note in
                    guard let sv = note.object as? NSScrollView,
                          sv === transcriptNSScrollView else { return }
                    // Ignore notifications generated by our own
                    // programmatic scrolls — see the docstring on
                    // `suppressLiveScrollUntil`.
                    guard Date() >= suppressLiveScrollUntil else { return }
                    guard autoScroll else { return }
                    print("[Follow] Suspended — user scrolled the transcript.")
                    autoScroll = false
                    pendingScrollTask?.cancel()
                    pendingScrollTask = nil
                }
                .onReceive(NotificationCenter.default.publisher(for: .miniplayerTimeUpdate)) { note in
                    handlePlaybackTimeUpdate(note)
                }
        }
    }

    /// The scrollable transcript body — extracted from
    /// `transcriptScrollView` so the type checker can resolve the
    /// modifier chain in reasonable time. Returning a typed `some View`
    /// here also makes the chunk easier to read in isolation.
    private var scrollContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(visibleGroups) { group in
                    transcriptGroupRow(group)
                }
                Color.clear.frame(height: 60).id("BOTTOM")
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            // Invisible shim that walks the AppKit view hierarchy to
            // find the NSScrollView backing this SwiftUI ScrollView.
            // Powers the scoped live-scroll observer in
            // `transcriptScrollView` — see the comment there.
            .background(ScrollViewGrabber { scrollView in
                transcriptNSScrollView = scrollView
            })
        }
    }

    /// One paragraph in the transcript. Extracted as a function rather
    /// than letting `ForEach`'s trailing closure inline the modifiers,
    /// because the `.simultaneousGesture` + closure capture was part
    /// of what bogged down the type checker.
    @ViewBuilder
    private func transcriptGroupRow(_ group: SpeakerGroup) -> some View {
        SpeakerGroupView(
            group: group,
            highlight: searchText,
            playingSegmentID: playingSegmentID
        )
        .id(group.id)
        .transition(.opacity)
        // Click-to-seek wiring. Tap the group → notify miniplayer to
        // seek to this group's first segment's start time. The
        // miniplayer might not be open; the notification is
        // fire-and-forget either way. We use simultaneousGesture so
        // SpeakerGroupView's own context menu / text-selection
        // handling isn't shadowed.
        .simultaneousGesture(TapGesture().onEnded {
            postMiniplayerSeek(for: group)
        })
    }

    /// The single funnel for every programmatic transcript scroll.
    /// Opens the live-scroll suppression window (animation duration +
    /// a safety margin covering momentum/settling) BEFORE the scroll,
    /// so the animation can't be misread as a user gesture and
    /// self-suspend Follow. All four scroll paths route through here:
    /// tail-follow (BOTTOM), playhead follow, pin-jump, and the
    /// Follow-toggle snap-back.
    private func performProgrammaticScroll<Target: Hashable>(
        _ proxy: ScrollViewProxy,
        to target: Target,
        anchor: UnitPoint,
        duration: Double = 0.3
    ) {
        suppressLiveScrollUntil = Date().addingTimeInterval(duration + 0.4)
        withAnimation(.easeOut(duration: duration)) {
            proxy.scrollTo(target, anchor: anchor)
        }
    }

    /// Post a seek notification for the given group's first segment.
    /// No-op when no playable media is loaded so taps on the transcript
    /// during live transcription don't queue stale notifications.
    private func postMiniplayerSeek(for group: SpeakerGroup) {
        guard engine.playbackMediaURL != nil else { return }
        let t = group.segments.first?.start ?? 0
        NotificationCenter.default.post(name: .miniplayerSeek, object: t as NSNumber)
    }

    /// Pin-jump or pin-clear → scroll the targeted group to the top of
    /// the viewport. Disables auto-bottom-follow since the user is
    /// navigating manually now. (No dedupe-anchor sync needed: since
    /// pin-jump suspends Follow, playhead scrolls can't fire until the
    /// user re-enables it — and re-enabling clears the anchor anyway.)
    private func handleScrollToSegmentRequest(_ id: UUID?, proxy: ScrollViewProxy) {
        guard let id = id else { return }
        // The group's id is its first segment's id, which matches
        // PinnedQuote.sourceSegmentID. If the segment lives partway
        // through a group, fall back to whichever group contains it.
        let resolvedGroupID = visibleGroups.first(where: { group in
            group.segments.contains(where: { $0.id == id })
        })?.id
        let scrollTarget = resolvedGroupID ?? id

        // Cancel any pending debounced scroll from the miniplayer's
        // playing-segment updates. Without this, a user pin-jump would
        // land at the pinned quote, then ~100ms later a pending playback
        // scroll would fire and yank the transcript back to wherever
        // playback was. Pin-jump is user-initiated — it wins over
        // whatever the playback was targeting.
        pendingScrollTask?.cancel()
        pendingScrollTask = nil

        autoScroll = false
        performProgrammaticScroll(proxy, to: scrollTarget, anchor: .top, duration: 0.35)
        DispatchQueue.main.async {
            scrollToSegmentID = nil
        }
    }

    /// When the miniplayer's playing segment changes, scroll the
    /// containing group into view (centered) so the user can read
    /// along.
    ///
    /// **Dedupe by target group.** Without the `lastScrolledPlayheadSegmentID`
    /// check, AVPlayer's post-seek time oscillation rapid-fires this
    /// handler with `playingSegmentID` flipping between adjacent
    /// segments of the same group. Each call would kick off a fresh
    /// 0.3s scroll animation, interrupting the previous one in flight,
    /// producing the visible jitter the user reported. With the dedupe,
    /// only the FIRST change to a group triggers a scroll; subsequent
    /// segment-id flips that resolve to the same group are silently
    /// ignored until playback actually crosses into a different group.
    ///
    /// **When dedupe doesn't fire:** when `target != lastScrolledPlayheadSegmentID`
    /// (genuine group transition during natural playback, or a seek
    /// that lands on a new group). Normal scroll behavior applies.
    /// Handle a change in `playingSegmentID` — the segment currently
    /// under the playhead. Delegates to `scrollTo(target:)` after a
    /// short debounce.
    ///
    /// **Debounce rationale.** Two scenarios drive `playingSegmentID`
    /// updates:
    ///   1. **Natural playback:** the miniplayer emits time updates
    ///      every ~500ms. Segments transition every few seconds. One
    ///      scroll per transition, no overlap.
    ///   2. **Scrubbing:** the user drags the miniplayer scrubber.
    ///      Time updates come every 10-50ms as the scrubber moves.
    ///      Without debouncing, every intermediate position triggers
    ///      a scroll, animations pile up, and the transcript
    ///      appears to shake/jitter as animations fight each other.
    ///
    /// The 120ms debounce eliminates the scrubbing case entirely
    /// (rapid updates cancel each other, only the last one fires)
    /// while adding no perceptible latency to natural playback
    /// (500ms interval >> 120ms debounce).
    ///
    /// **Dedupe by SEGMENT.** Earlier revisions deduped by group,
    /// which meant a long single-speaker paragraph scrolled once
    /// (centered) and then sat still while the highlight walked out
    /// of view. Segment-level dedupe + a fractional anchor keeps the
    /// playing sentence at a proportional viewport position: as
    /// playback moves through a tall group, the anchor fraction
    /// advances 0→1 and the group slides smoothly so the highlight
    /// stays on screen. Short groups get the same treatment — the
    /// per-step movement is just tiny.
    private func handlePlayingSegmentChange(_ segID: UUID?, proxy: ScrollViewProxy) {
        guard let segID = segID else {
            // Playback stopped or segment cleared. Cancel any pending
            // scroll and reset the dedupe anchor.
            pendingScrollTask?.cancel()
            pendingScrollTask = nil
            lastScrolledPlayheadSegmentID = nil
            return
        }

        // Follow governs playhead-following. When it's off — either
        // toggled off by the user or auto-suspended because they
        // manually scrolled elsewhere (see the scroll-phase handler)
        // — playback position changes update the inline highlight but
        // never move the scroll position. Re-enabling Follow snaps
        // back to the playhead (see the autoScroll onChange).
        guard autoScroll else { return }

        guard let group = visibleGroups.first(where: { g in
            g.segments.contains(where: { $0.id == segID })
        }) else { return }

        // Dedupe on the segment: skip only if we already scrolled for
        // this exact segment. Different segment in the SAME group now
        // schedules a scroll (with an updated anchor fraction).
        guard segID != lastScrolledPlayheadSegmentID else { return }

        let groupID = group.id
        let anchorFraction = playheadAnchorFraction(forSegment: segID, in: group)

        // Cancel any in-flight debounced scroll from a previous update.
        // If the user is actively scrubbing, this cancellation happens
        // dozens of times — each call takes microseconds, so there's
        // no perceptible cost.
        pendingScrollTask?.cancel()
        pendingScrollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)  // 120ms
            guard !Task.isCancelled else { return }

            // Re-check dedupe AND follow state at fire time. During
            // the 120ms wait, the user may have scrolled manually
            // (suspending follow) or another path may have scrolled
            // (updating the dedupe anchor).
            guard autoScroll, segID != lastScrolledPlayheadSegmentID else { return }
            lastScrolledPlayheadSegmentID = segID

            performProgrammaticScroll(
                proxy,
                to: groupID,
                anchor: UnitPoint(x: 0.5, y: anchorFraction)
            )
        }
    }

    /// Where the playing segment sits within its group, as a 0...1
    /// fraction of the group's TIME span (segment midpoint over group
    /// duration). Used as the scrollTo anchor's y-component:
    /// `scrollTo(id, anchor: UnitPoint(y: f))` aligns the point f-way
    /// down the group view with the point f-way down the viewport —
    /// so early segments render near the top of the viewport, late
    /// segments near the bottom, and the highlight tracks smoothly
    /// through tall groups instead of drifting off-screen below a
    /// fixed center anchor.
    ///
    /// Time-fraction is a proxy for text-position-fraction; the two
    /// diverge when speech density varies within a group, but at
    /// segment granularity the error is a line or two — invisible in
    /// practice.
    private func playheadAnchorFraction(forSegment segID: UUID, in group: SpeakerGroup) -> Double {
        guard let seg = group.segments.first(where: { $0.id == segID }),
              let first = group.segments.first,
              let last = group.segments.last else { return 0.5 }
        let span = last.end - first.start
        guard span > 0.5 else { return 0.5 }
        let mid = (seg.start + seg.end) / 2 - first.start
        return min(max(mid / span, 0), 1)
    }

    /// Receive a `.miniplayerTimeUpdate` notification and recompute
    /// `playingSegmentID`. Linear scan over segments — transcript sizes
    /// don't justify a binary search.
    private func handlePlaybackTimeUpdate(_ note: Notification) {
        let secs = (note.object as? NSNumber)?.doubleValue ?? 0
        playbackTime = secs
        // Match against [start, end) of each segment. The last segment's
        // `end` is whatever the engine assigned (real end time for
        // finalized segments), so we don't need to special-case it.
        let segs = engine.segments
        var found: UUID?
        for seg in segs {
            if secs >= seg.start && secs < seg.end {
                found = seg.id
                break
            }
        }
        if playingSegmentID != found {
            playingSegmentID = found
        }
    }

    /// Group consecutive same-speaker segments into paragraph blocks.
    /// Uses the shared `groupedBySpeaker()` extension from the model so this matches
    /// what the exporter produces.
    /// Group segments into visible paragraphs, splitting on
    /// EFFECTIVE speaker name rather than cluster ID. This is what
    /// causes diarizer-merged speakers to visually split: if
    /// "Speaker 1" contains segments identified as Senator A and
    /// Senator B at the per-segment level, those segments end up in
    /// separate visual groups even though they share a cluster ID.
    ///
    /// **The grouping key** is `engine.displayName(forSegment:)`,
    /// which factors in (in priority order) manual cluster rename,
    /// manual segment ID, manual cluster ID, automatic segment ID,
    /// and finally falls back to the cluster ID itself. Consecutive
    /// segments with identical resolved names group together;
    /// transitions create new groups.
    ///
    /// **Each visible group's `speaker` field carries the effective
    /// name**, not the cluster ID. The cluster ID is still available
    /// via the first segment's `speaker` field, which is what the
    /// "Reassign Speaker" and "Identify Speaker" context menus use
    /// for cluster-level actions.
    private var visibleGroups: [SpeakerGroup] {
        let segments = filteredSegments
        guard !segments.isEmpty else { return [] }

        // Compute cluster majorities once for this render. Used by
        // `displayName(forSegment:clusterMajorities:)` to smooth
        // unidentified segments into their cluster's majority — keeps
        // continuous single-speaker stretches from fragmenting into
        // alternating "Bernie Sanders / Speaker 1 / Bernie Sanders"
        // groups when short segments fail to extract or match.
        // Computed once here rather than per-segment to avoid O(N²)
        // recomputation.
        let majorities = engine.clusterMajorityIdentifications()

        // Resolve each segment's effective name once, then walk
        // through and accumulate runs of identical resolved names.
        // O(N) over segments; the displayName resolution is O(1)
        // per call (dict lookups in VoiceprintService + majorities).
        var groups: [SpeakerGroup] = []
        var currentSegments: [TranscriptSegment] = []
        var currentName: String? = nil

        for seg in segments {
            let resolvedName = engine.displayName(
                forSegment: seg,
                clusterMajorities: majorities
            ) ?? seg.speaker
            if resolvedName == currentName {
                currentSegments.append(seg)
            } else {
                if !currentSegments.isEmpty {
                    groups.append(SpeakerGroup(
                        speaker: currentName,
                        segments: currentSegments
                    ))
                }
                currentSegments = [seg]
                currentName = resolvedName
            }
        }
        if !currentSegments.isEmpty {
            groups.append(SpeakerGroup(
                speaker: currentName,
                segments: currentSegments
            ))
        }
        return groups
    }

    private var filteredSegments: [TranscriptSegment] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return engine.segments }
        return engine.segments.filter { seg in
            if seg.text.lowercased().contains(q) { return true }
            // Match against both the machine label ("Speaker 1") and the user's
            // custom display name ("Alice") so search works either way.
            if let machineLabel = seg.speaker {
                if machineLabel.lowercased().contains(q) { return true }
                if let displayName = engine.displayName(for: machineLabel),
                   displayName.lowercased().contains(q) {
                    return true
                }
            }
            return false
        }
    }

    private var transcriptBackground: some View {
        // Subtle warm paper feel — easier on eyes for long reading
        LinearGradient(
            colors: [
                Color(nsColor: .textBackgroundColor),
                Color(nsColor: .textBackgroundColor).opacity(0.97)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Speaker grouping

private struct SpeakerGroupView: View {
    @EnvironmentObject var engine: TranscriptionEngine
    let group: SpeakerGroup
    let highlight: String
    /// ID of the segment the miniplayer is currently playing (if any).
    /// When any segment in this group matches, the group gets a subtle
    /// background tint so the user can follow along visually. nil =
    /// nothing playing, no highlight.
    let playingSegmentID: UUID?

    /// True when the cursor is hovering over this group's row. Drives
    /// the visibility of the inline pin/unpin button — hidden when
    /// not hovering (to avoid cluttering the transcript), visible on
    /// hover so users can pin during live transcription without
    /// hunting for the right-click target.
    ///
    /// Hover-reveal is the standard macOS affordance for row-level
    /// actions (Finder list view, Mail, Messages all do this) — users
    /// recognize it intuitively. The right-click context menu still
    /// exists as a backup for keyboard-driven workflows or users with
    /// pointing devices that don't track hover (trackpads do; some
    /// mice don't).
    @State private var isHovered: Bool = false

    /// Settings gate for double-click-to-seek. Shares the key with
    /// the toggle in Settings → Miniplayer. Checked at click time in
    /// `seekToSegment(atFraction:)`, so flipping the setting takes
    /// effect immediately without restarting anything.
    @AppStorage("miniplayer.doubleClickSeek")
    private var doubleClickSeekEnabled: Bool = true

    // Identify Speaker sheet state. Replaces the old context-menu-with-
    // hundreds-of-items pattern that made macOS's AppKit menu tracking
    // unresponsive (the `didChangeSubmenu: rep returned item view with
    // wrong item:` log spam). NSMenu chokes on any menu with several
    // hundred items, even when the items are split across submenus —
    // it's a bridge-layer issue between SwiftUI's Menu and NSMenu, not
    // fixed by categorization alone.
    //
    // Sheets sidestep NSMenu entirely. The right-click context menu
    // shows "Identify Speaker (entire cluster)…" and "Identify These
    // Segments…" as single-line entries that trigger a sheet with a
    // searchable, categorized list. Users search by typing the
    // person's name, hit Enter or click to identify. Same functional
    // outcome as the menu, dramatically better UX for large libraries.
    @State private var showIdentifySheet: Bool = false
    @State private var identifyMode: IdentifyMode = .cluster
    @State private var identifyClusterID: String? = nil
    @State private var identifySegmentIDs: [UUID] = []
    @State private var identifyCurrentName: String? = nil

    /// Which "identify" action opened the sheet. Determines which
    /// VoiceprintService method the sheet's confirm action calls.
    enum IdentifyMode {
        case cluster    // sets manual identification for the whole cluster
        case segments   // sets manual identification for specific segments only
    }

    /// True when this group contains the currently-playing segment.
    private var isPlaying: Bool {
        guard let id = playingSegmentID else { return false }
        return group.segments.contains(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let displayedName = group.speaker {
                    // `group.speaker` carries the EFFECTIVE name now
                    // (after per-segment identification), not the raw
                    // cluster ID. For uncertainty rendering, we look
                    // at the first segment's identification state —
                    // since all segments in this visible group share
                    // the same effective name, sampling the first is
                    // representative.
                    //
                    // For the color seed, we use the cluster ID
                    // (from the first segment's raw `speaker` field)
                    // when there's an identified speaker. Same person
                    // identified across different clusters → same
                    // color. Different people in the same cluster
                    // (the merge case we're solving for) → different
                    // effective names → still different colors
                    // because the badge logic computes color from the
                    // CLUSTER for unidentified groups but from the
                    // NAME for identified ones — keeping color tied
                    // to identity, not to raw clustering.
                    let firstSeg = group.segments.first
                    let clusterId = firstSeg?.speaker
                    let isIdentified: Bool = {
                        if let seg = firstSeg {
                            return VoiceprintService.shared.displayInfo(
                                forSegmentId: seg.id,
                                clusterId: clusterId
                            ).isIdentified
                        }
                        return false
                    }()
                    let isUncertain: Bool = {
                        if let seg = firstSeg, let cid = clusterId {
                            let hasManualRename = engine.speakerNames[cid]?.isEmpty == false
                            if hasManualRename { return false }
                            return VoiceprintService.shared.displayInfo(
                                forSegmentId: seg.id,
                                clusterId: cid
                            ).isUncertain
                        }
                        return false
                    }()
                    let colorSeed = isIdentified ? displayedName : (clusterId ?? displayedName)
                    SpeakerBadge(
                        displayName: displayedName,
                        colorSeed: colorSeed,
                        isUncertain: isUncertain
                    )
                }
                Text(group.formattedTimeRange)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                // Multi-pass live indicator: a small dot rendered next to the
                // timestamp when this group is still in the raw or pending
                // state. Pending pulses; raw is steady. Outside the multi-pass
                // pipeline (single-pass live, static mode, every existing
                // session), groups are `.refined` and this view is empty —
                // the UI is byte-identical to before Phase 1.
                if group.refinementState != .refined {
                    RefinementIndicator(state: group.refinementState)
                }
                // Pin/unpin button. Visible when EITHER hovered OR
                // already pinned. Behavior:
                //   - Pinned + hovered: filled orange icon; click to unpin
                //   - Pinned + not hovered: filled orange icon (passive
                //     indicator; still clickable as a bonus)
                //   - Not pinned + hovered: outline gray icon; click to pin
                //   - Not pinned + not hovered: nothing (hidden)
                //
                // The .plain button style strips macOS's default button
                // chrome so the icon reads as an inline affordance rather
                // than a styled button. Same pattern Finder uses for
                // the hover-revealed Quick Look button on file rows.
                if isPinned || isHovered {
                    Button {
                        if isPinned {
                            for q in matchingPins { engine.unpin(q.id) }
                        } else {
                            engine.pinGroup(group)
                        }
                    } label: {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 11))
                            .foregroundStyle(isPinned ? Color.orange : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isPinned ? "Unpin quote" : "Pin quote")
                }
            }
            Text(highlightedText)
                .font(.system(size: 15, design: .serif))
                .lineSpacing(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                // Double-click → seek playback to the clicked SEGMENT.
                // Word-level seeking would need per-word timestamps and
                // text-layout hit-testing SwiftUI doesn't expose;
                // segment granularity (a sentence-ish chunk) is the
                // practical unit.
                //
                // **Why an AppKit event monitor instead of SwiftUI
                // gestures.** With `.textSelection(.enabled)`, mouse
                // events over the text glyphs are consumed by AppKit's
                // selection machinery before SwiftUI's gesture system
                // sees them — both `SpatialTapGesture(count: 2)` AND
                // manual two-tap detection silently never fire over
                // the text. The overlay below is an invisible NSView
                // (hitTest returns nil, so it blocks nothing) that
                // watches raw `.leftMouseDown` events app-wide via a
                // local monitor, filters for clickCount == 2 landing
                // inside its own bounds, and reports the click's
                // y-fraction. Raw NSEvents can't be swallowed by the
                // text selection — the monitor sees them first. The
                // event passes through unconsumed, so the word still
                // gets visually selected as confirmation.
                .overlay(
                    DoubleClickCatcher { yFraction in
                        seekToSegment(atFraction: yFraction)
                    }
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Subtle background tint for the currently-playing group.
        // Padding is added before the background so the tint extends
        // a bit past the text — looks like a highlighted row rather
        // than a tightly-cropped text background.
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isPlaying ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        // Opacity reduction for non-refined groups signals "this will get
        // cleaner soon." 0.65 (not the design doc's original 0.85) was needed
        // in practice — 0.85 against the warm-paper background renders as
        // basically full opacity on most displays. 0.65 is unmistakably
        // faded without making text harder to read.
        .opacity(group.refinementState == .refined ? 1.0 : 0.65)
        .contentShape(Rectangle())  // make whole row right-clickable, not just text bounds
        .onHover { hovering in
            // Cheap state update — no animation here so the pin button
            // appears/disappears instantly rather than fading, matching
            // the snappy feel of Finder's hover-reveal affordances.
            // If we ever want a softer feel, wrap in
            // withAnimation(.easeInOut(duration: 0.1)).
            isHovered = hovering
        }
        .contextMenu {
            Button {
                if isPinned {
                    // Unpin: remove any pin tied to this group's first segment
                    for q in matchingPins { engine.unpin(q.id) }
                } else {
                    engine.pinGroup(group)
                }
            } label: {
                Label(isPinned ? "Unpin Quote" : "Pin Quote",
                      systemImage: isPinned ? "pin.slash" : "pin")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(group.combinedText, forType: .string)
            } label: {
                Label("Copy Text", systemImage: "doc.on.doc")
            }

            // Speaker reassignment submenu. Operates on every segment in
            // this visible paragraph (matches the "whole paragraph" mental
            // model — paragraphs ARE the visible unit here). Choices:
            //   • Existing speakers from the transcript (current one shown
            //     with a checkmark, disabled — no point reassigning to self)
            //   • "UNKNOWN" — explicit ambiguous-speaker marker, matches
            //     the same value Phase 5 uses for empty-overlap fallbacks
            //   • "No Speaker" — clears the label entirely (renders with
            //     no header, same as single-pass-no-diarizer)
            //
            // Existing speakers list comes from `engine.distinctMachineSpeakers`
            // — same source as the SpeakerPanel's renaming list. Display
            // name (user's chosen name) shown when set; machine label is
            // the fallback.
            //
            // **`groupClusterId` vs `group.speaker`.** Since the switch to
            // per-segment matching, `group.speaker` is the EFFECTIVE
            // identified name (e.g. "Bernie Sanders"), not the cluster
            // label ("Speaker 1"). For cluster-level reassignment we
            // need the raw cluster — sourced from the first segment's
            // `speaker` field. A visible group can theoretically span
            // multiple clusters if per-segment matching identified
            // segments from different clusters as the same person; we
            // use the first segment's cluster, accepting the rare
            // multi-cluster case.
            let groupClusterId = group.segments.first?.speaker
            Divider()
            Menu {
                ForEach(engine.distinctMachineSpeakers, id: \.self) { machineLabel in
                    Button {
                        engine.reassignSpeaker(segmentIDs: groupSegmentIDs, to: machineLabel)
                    } label: {
                        if machineLabel == groupClusterId {
                            Label(engine.displayName(for: machineLabel) ?? machineLabel,
                                  systemImage: "checkmark")
                        } else {
                            Text(engine.displayName(for: machineLabel) ?? machineLabel)
                        }
                    }
                    .disabled(machineLabel == groupClusterId)
                }

                // Sentinel options — appear under their own divider since
                // they're semantically different from picking a real
                // existing speaker.
                Divider()

                Button {
                    engine.reassignSpeaker(segmentIDs: groupSegmentIDs, to: "UNKNOWN")
                } label: {
                    if groupClusterId == "UNKNOWN" {
                        Label("UNKNOWN", systemImage: "checkmark")
                    } else {
                        Text("UNKNOWN")
                    }
                }
                .disabled(groupClusterId == "UNKNOWN")

                Button {
                    engine.reassignSpeaker(segmentIDs: groupSegmentIDs, to: nil)
                } label: {
                    if groupClusterId == nil {
                        Label("No Speaker", systemImage: "checkmark")
                    } else {
                        Text("No Speaker")
                    }
                }
                .disabled(groupClusterId == nil)
            } label: {
                Label("Reassign Speaker", systemImage: "person.crop.circle.badge.questionmark")
            }

            // Cluster-level voice identification menu. Sets the
            // identified name for the WHOLE cluster (every segment
            // sharing this cluster ID, even if some of those segments
            // live in different visible groups due to per-segment
            // matching). Use this when the diarizer's clustering is
            // correct and we just want to put a name on it.
            //
            // For correcting individual segments where the diarizer
            // merged two speakers, use the "Identify These Segments"
            // menu below instead — it acts at the visible-group level.
            if let clusterId = groupClusterId {
                Menu {
                    let currentInfo = VoiceprintService.shared.displayInfo(forClusterId: clusterId)
                    let sessionSpeakers = VoiceprintService.shared.sessionSpeakerHistory.sorted()

                    if currentInfo.isIdentified {
                        Button {
                            VoiceprintService.shared.clearIdentification(clusterId: clusterId)
                        } label: {
                            Label("Clear current: \(currentInfo.name)",
                                  systemImage: "xmark.circle")
                        }
                        Divider()
                    }

                    // Speakers already identified in this session.
                    // Small list — no NSMenu tracking issues — so
                    // this can be a flat submenu without any special
                    // handling. Empty on a fresh session; grows as
                    // the user identifies people (manually or
                    // automatically).
                    if !sessionSpeakers.isEmpty {
                        ForEach(sessionSpeakers, id: \.self) { name in
                            Button {
                                VoiceprintService.shared.setManualIdentification(
                                    clusterId: clusterId,
                                    name: name
                                )
                            } label: {
                                if currentInfo.isIdentified && currentInfo.name == name {
                                    Label(name, systemImage: "checkmark")
                                } else {
                                    Text(name)
                                }
                            }
                        }
                        Divider()
                    }

                    // "Other speaker…" opens the searchable sheet
                    // for the full voice-template library. Once the
                    // user picks a name, it gets added to
                    // sessionSpeakerHistory (via
                    // setManualIdentification) so subsequent right-
                    // clicks show it in the immediate list without
                    // needing to search again.
                    Button {
                        identifyMode = .cluster
                        identifyClusterID = clusterId
                        identifySegmentIDs = []
                        identifyCurrentName = currentInfo.isIdentified ? currentInfo.name : nil
                        showIdentifySheet = true
                    } label: {
                        Label(sessionSpeakers.isEmpty ? "Choose speaker…" : "Other speaker…",
                              systemImage: "magnifyingglass")
                    }
                    .disabled(VoiceprintService.shared.templates.isEmpty)
                } label: {
                    Label("Identify Speaker (entire cluster)", systemImage: "person.crop.circle.badge.checkmark")
                }
            }

            // Per-segment voice identification menu. Applies to the
            // segments in THIS visible group only, not the whole
            // cluster. Used to correct individual mistakes from
            // per-segment automatic matching — common case is a
            // single mis-identified segment in the middle of an
            // otherwise correctly-identified run, where the user
            // wants to fix just that segment without nuking the
            // good identifications around it.
            //
            // Sets a manual segment-level identification on every
            // segment in the group. Since manual segment IDs take
            // priority over both automatic IDs and cluster IDs in
            // VoiceprintService's display precedence, the override
            // sticks.
            if !VoiceprintService.shared.templates.isEmpty {
                Menu {
                    let sessionSpeakers = VoiceprintService.shared.sessionSpeakerHistory.sorted()
                    let groupSegmentIdentifications = group.segments.compactMap {
                        VoiceprintService.shared.segmentIdentifications[$0.id]
                    }

                    if !groupSegmentIdentifications.isEmpty {
                        Button {
                            for seg in group.segments {
                                VoiceprintService.shared.clearSegmentIdentification(segmentId: seg.id)
                            }
                        } label: {
                            Label("Clear segment IDs in this group",
                                  systemImage: "xmark.circle")
                        }
                        Divider()
                    }

                    // Session speakers directly — same treatment as
                    // the cluster menu above.
                    if !sessionSpeakers.isEmpty {
                        ForEach(sessionSpeakers, id: \.self) { name in
                            Button {
                                for seg in group.segments {
                                    VoiceprintService.shared.setManualSegmentIdentification(
                                        segmentId: seg.id,
                                        name: name
                                    )
                                }
                            } label: {
                                Text(name)
                            }
                        }
                        Divider()
                    }

                    Button {
                        identifyMode = .segments
                        identifyClusterID = nil
                        identifySegmentIDs = group.segments.map { $0.id }
                        identifyCurrentName = VoiceprintService.shared
                            .segmentIdentifications[group.segments.first?.id ?? UUID()]?.name
                        showIdentifySheet = true
                    } label: {
                        Label(sessionSpeakers.isEmpty ? "Choose speaker…" : "Other speaker…",
                              systemImage: "magnifyingglass")
                    }
                    .disabled(VoiceprintService.shared.templates.isEmpty)
                } label: {
                    Label("Identify These Segments", systemImage: "text.badge.checkmark")
                }
            }

            // Per-sentence reassignment. The paragraph-level menu above
            // operates on every segment in this group; this submenu lets
            // the user fix a single sentence when the diarizer split
            // wasn't quite right at a phrase boundary. Common case: the
            // last sentence of a paragraph actually belongs to the next
            // speaker (or vice versa) and the post-split reabsorb pass
            // didn't catch it (e.g. fragment too long, or didn't end in
            // terminal punctuation).
            //
            // Only surface when there's more than one segment to choose
            // between — for a single-segment paragraph the per-sentence
            // menu would be redundant with the paragraph-level one.
            if group.segments.count > 1 {
                Menu {
                    // One row per segment in the group. The row's label
                    // is a short preview of the sentence so the user can
                    // identify which one they want; the submenu of that
                    // row mirrors the speaker choices from the
                    // paragraph-level menu (existing speakers, UNKNOWN,
                    // No Speaker).
                    ForEach(group.segments) { segment in
                        Menu {
                            ForEach(engine.distinctMachineSpeakers, id: \.self) { machineLabel in
                                Button {
                                    engine.reassignSpeaker(segmentIDs: [segment.id], to: machineLabel)
                                } label: {
                                    if machineLabel == segment.speaker {
                                        Label(engine.displayName(for: machineLabel) ?? machineLabel,
                                              systemImage: "checkmark")
                                    } else {
                                        Text(engine.displayName(for: machineLabel) ?? machineLabel)
                                    }
                                }
                                .disabled(machineLabel == segment.speaker)
                            }

                            Divider()

                            Button {
                                engine.reassignSpeaker(segmentIDs: [segment.id], to: "UNKNOWN")
                            } label: {
                                if segment.speaker == "UNKNOWN" {
                                    Label("UNKNOWN", systemImage: "checkmark")
                                } else {
                                    Text("UNKNOWN")
                                }
                            }
                            .disabled(segment.speaker == "UNKNOWN")

                            Button {
                                engine.reassignSpeaker(segmentIDs: [segment.id], to: nil)
                            } label: {
                                if segment.speaker == nil {
                                    Label("No Speaker", systemImage: "checkmark")
                                } else {
                                    Text("No Speaker")
                                }
                            }
                            .disabled(segment.speaker == nil)
                        } label: {
                            // Sentence preview — first ~60 chars, with
                            // ellipsis if truncated. macOS menu items
                            // can render long labels but get unwieldy
                            // past ~80 chars; 60 keeps the menu visually
                            // tight while preserving enough context for
                            // the user to pick the right sentence.
                            Text(sentencePreview(for: segment))
                        }
                    }
                } label: {
                    Label("Reassign by sentence…", systemImage: "text.alignleft")
                }
            }
        }
        .sheet(isPresented: $showIdentifySheet) {
            IdentifySpeakerSheet(
                mode: identifyMode,
                clusterID: identifyClusterID,
                segmentIDs: identifySegmentIDs,
                currentName: identifyCurrentName,
                onCancel: { showIdentifySheet = false },
                onConfirm: { chosenName in
                    switch identifyMode {
                    case .cluster:
                        if let cid = identifyClusterID {
                            VoiceprintService.shared.setManualIdentification(
                                clusterId: cid,
                                name: chosenName
                            )
                        }
                    case .segments:
                        for segId in identifySegmentIDs {
                            VoiceprintService.shared.setManualSegmentIdentification(
                                segmentId: segId,
                                name: chosenName
                            )
                        }
                    }
                    showIdentifySheet = false
                }
            )
        }
    }

    /// Short preview of a segment's text for the per-sentence reassign
    /// menu. Trims whitespace, truncates to ~60 chars with an ellipsis.
    /// Falls back to a timestamp-based label if the segment is empty
    /// (rare — usually filtered out at the group-building level, but
    /// the menu must remain non-empty if it appears at all).
    private func sentencePreview(for segment: TranscriptSegment) -> String {
        let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return TranscriptSegment.formatTime(segment.start)
        }
        let maxLen = 60
        if trimmed.count <= maxLen {
            return trimmed
        }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: maxLen)
        return trimmed[..<idx].trimmingCharacters(in: .whitespaces) + "…"
    }

    /// IDs of every segment in this paragraph — what `reassignSpeaker`
    /// operates on. Captured as a Set so the engine method's `Set<UUID>`
    /// containment checks are O(1) per segment.
    private var groupSegmentIDs: Set<UUID> {
        Set(group.segments.map(\.id))
    }

    /// Pins matching this group: same source-segment id and matching text. Captures
    /// the case where the same group has been pinned. Used to flip the menu between
    /// "Pin Quote" and "Unpin Quote" and to display the indicator badge.
    private var matchingPins: [PinnedQuote] {
        guard let firstID = group.segments.first?.id else { return [] }
        let combined = group.combinedText
        return engine.pinnedQuotes.filter {
            $0.sourceSegmentID == firstID && $0.text == combined
        }
    }

    private var isPinned: Bool {
        !matchingPins.isEmpty
    }

    /// Map a double-click's vertical position (as a 0...1 fraction of
    /// the text block's height, reported by `DoubleClickCatcher`) to
    /// a segment, and seek the miniplayer to that segment's start.
    ///
    /// **The mapping.** Click y-fraction ≈ character-fraction of the
    /// combined text (uniform line height; wrapped-line variance
    /// averages out at segment granularity). Walk the segments
    /// accumulating their trimmed character counts (+1 per joining
    /// space, matching `combinedText` construction) until the target
    /// character index falls inside one — that's the clicked segment.
    /// Off-by-a-line errors land on an adjacent segment, a couple of
    /// seconds of seek error — acceptable for "jump to what I
    /// clicked."
    private func seekToSegment(atFraction yFraction: Double) {
        guard doubleClickSeekEnabled else { return }
        guard engine.playbackMediaURL != nil else { return }
        let combined = group.combinedText
        let totalChars = combined.count
        guard totalChars > 0 else { return }

        let targetChar = Int(Double(totalChars) * min(max(yFraction, 0), 1))

        var cursor = 0
        var chosen: TranscriptSegment? = group.segments.first
        for seg in group.segments {
            let t = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let end = cursor + t.count
            if targetChar <= end {
                chosen = seg
                break
            }
            cursor = end + 1  // the joining space in combinedText
            chosen = seg      // fall through to last non-empty segment
        }

        guard let seg = chosen else { return }
        NotificationCenter.default.post(name: .miniplayerSeek, object: seg.start as NSNumber)
    }

    private var highlightedText: AttributedString {
        var attr = AttributedString(group.combinedText)

        // Segment-level playback highlight. The group-level tint (the
        // rounded-rect background on the whole paragraph) tells you
        // WHICH paragraph is playing; this tells you WHERE within it.
        // Long single-speaker stretches — a senator holding the floor
        // for five minutes produces one paragraph spanning dozens of
        // segments — were previously untrackable: the group tint never
        // moved, so scrubbing gave no positional feedback within the
        // paragraph.
        //
        // **Range location by ordered search.** `combinedText` joins
        // the segments' trimmed texts with single spaces and then
        // collapses double spaces, so precomputing character offsets
        // arithmetically would desync wherever the collapse fired.
        // Instead we search for each segment's trimmed text in order,
        // advancing the search start past each match. Duplicate
        // segment texts ("Yeah." twice in a paragraph) resolve
        // correctly because the search window only moves forward.
        //
        // Cost: O(paragraph length) per render, only for the playing
        // group (guard below). Non-playing groups skip this entirely.
        if isPlaying, let playingID = playingSegmentID {
            let plain = String(attr.characters)
            var searchStart = plain.startIndex
            for seg in group.segments {
                let needle = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !needle.isEmpty else { continue }
                guard let range = plain.range(of: needle, range: searchStart..<plain.endIndex) else { break }
                if seg.id == playingID {
                    if let aRange = Range(range, in: attr) {
                        attr[aRange].backgroundColor = Color.accentColor.opacity(0.28)
                    }
                    break
                }
                searchStart = range.upperBound
            }
        }

        let q = highlight.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return attr }
        let plain = String(attr.characters)
        var searchStart = plain.startIndex
        while let range = plain.range(of: q, options: .caseInsensitive, range: searchStart..<plain.endIndex) {
            if let aRange = Range(range, in: attr) {
                attr[aRange].backgroundColor = .yellow.opacity(0.35)
                attr[aRange].foregroundColor = .primary
            }
            searchStart = range.upperBound
        }
        return attr
    }
}

/// Small visual cue placed next to a speaker group's timestamp when the group
/// is still in the raw (or in-progress refinement) state. The dot is the same
/// size and color emphasis as a status light — present enough to communicate
/// "this isn't finalized," subtle enough to not steal attention from the text.
///
/// Three states map to three treatments:
///   - `.raw`: solid orange dot. "Live output, will be replaced."
///   - `.pending`: orange dot pulsing between opacities. "Refinement is
///     actively running on this range — replacement is imminent."
///   - `.refined`: this view should never be rendered for `.refined` groups.
///     The caller is expected to guard. If it ever is rendered, it renders
///     nothing rather than a stale indicator.
private struct RefinementIndicator: View {
    let state: SegmentRefinementState
    @State private var pulse: Bool = false

    var body: some View {
        switch state {
        case .raw:
            indicatorBody(opacity: 0.85)
        case .pending:
            indicatorBody(opacity: pulse ? 0.4 : 0.9)
                .onAppear {
                    // Auto-reverse animation produces a steady breathing pulse.
                    // 0.8s feels alive-but-calm; faster reads as nervous.
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulse.toggle()
                    }
                }
        case .refined:
            EmptyView()
        }
    }

    private func indicatorBody(opacity: Double) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.orange)
                .frame(width: 6, height: 6)
                .opacity(opacity)
            Text(state == .pending ? "refining" : "live")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
        }
        .help(state == .pending
              ? "Refining this segment — content will update shortly"
              : "Raw transcript — refinement may update this segment")
    }
}

private struct SpeakerBadge: View {
    /// Text shown in the badge. May be the user's custom name or the machine label.
    let displayName: String
    /// String used to derive the badge color. Should be the *machine label*, not the
    /// display name, so that renaming a speaker doesn't change their color.
    let colorSeed: String
    /// When true, render the display name in italics to signal that
    /// the identification is below the high-confidence threshold. The
    /// voiceprint matcher provides this flag via
    /// `VoiceprintService.displayInfo(forClusterId:)`. False for
    /// manual reassignments, high-confidence matches, and unidentified
    /// speakers (all of which render normally).
    var isUncertain: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(displayName)
                .font(.system(size: 10, weight: .semibold))
                .italic(isUncertain)
                .tracking(0.3)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(color.opacity(0.12))
        )
        .overlay(
            Capsule().stroke(color.opacity(0.25), lineWidth: 0.5)
        )
        .help(isUncertain
              ? "Identified as \(displayName) (low confidence — right-click to confirm or change)"
              : displayName)
    }

    /// Stable color per colorSeed.
    private var color: Color {
        let palette: [Color] = [
            .blue, .purple, .orange, .pink, .teal, .green, .indigo, .red, .mint, .brown
        ]
        var hash = 0
        for char in colorSeed.unicodeScalars {
            hash = (hash &* 31) &+ Int(char.value)
        }
        return palette[abs(hash) % palette.count]
    }
}

// MARK: - IdentifySpeakerSheet

/// Sheet-based UI for identifying a speaker from the voice-template
/// library. Replaces the old context-menu-with-hundreds-of-items
/// approach that made AppKit's menu tracking unresponsive when the
/// library grew past ~200 templates.
///
/// **Why a sheet instead of a Menu.** SwiftUI's `Menu` bridges to
/// `NSMenu`, and NSMenu tracking chokes on any menu containing more
/// than a few hundred items regardless of how they're nested. The
/// symptom is `didChangeSubmenu: rep returned item view with wrong
/// item:` log spam while the menu becomes unresponsive to clicks. A
/// sheet is regular SwiftUI content — no NSMenu bridge, no tracking
/// system to break.
///
/// **UX benefits beyond the fix.** Users can search by typing (much
/// faster than scrolling through hundreds of names) and see the full
/// category structure at once. The full library becomes usable at
/// any size — 660 templates today, 6000 tomorrow.
private struct IdentifySpeakerSheet: View {
    let mode: SpeakerGroupView.IdentifyMode
    let clusterID: String?
    let segmentIDs: [UUID]
    let currentName: String?
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var searchText: String = ""
    @FocusState private var searchFieldFocused: Bool
    @ObservedObject private var voiceprints = VoiceprintService.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode == .cluster ? "Identify Speaker" : "Identify These Segments")
                        .font(.system(size: 15, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)

            Divider()

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search names", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFieldFocused)
                    .onSubmit {
                        // Enter → identify to the first matching result.
                        if let first = firstMatch {
                            onConfirm(first.name)
                        }
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            // List
            List {
                ForEach(filteredCategories) { catGroup in
                    Section(header: Text("\(catGroup.name) (\(catGroup.templates.count))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)) {
                        ForEach(catGroup.templates) { template in
                            Button {
                                onConfirm(template.name)
                            } label: {
                                HStack {
                                    Text(template.name)
                                        .font(.system(size: 12))
                                    Spacer()
                                    if template.name == currentName {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .frame(width: 380, height: 520)
        .onAppear {
            searchFieldFocused = true
        }
    }

    private var subtitle: String {
        switch mode {
        case .cluster:
            return "Pick a name to assign this speaker cluster."
        case .segments:
            return "Pick a name to assign the selected segments."
        }
    }

    /// Categorized templates filtered by the search text. Case-
    /// insensitive substring match on the template name. Categories
    /// with zero matches are dropped from the display.
    private var filteredCategories: [VoiceprintService.CategoryGroup] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        let source = voiceprints.categorizedTemplates.isEmpty
            ? [VoiceprintService.CategoryGroup(name: "All", templates: voiceprints.templates)]
            : voiceprints.categorizedTemplates

        guard !trimmed.isEmpty else { return source }
        let needle = trimmed.lowercased()
        return source.compactMap { group in
            let matched = group.templates.filter { $0.name.lowercased().contains(needle) }
            guard !matched.isEmpty else { return nil }
            return VoiceprintService.CategoryGroup(name: group.name, templates: matched)
        }
    }

    /// First matching template across all filtered categories. Used
    /// for the Enter-to-confirm shortcut.
    private var firstMatch: VoiceprintService.Voiceprint? {
        filteredCategories.first?.templates.first
    }
}

// MARK: - ScrollViewGrabber

/// Invisible NSViewRepresentable that locates the NSScrollView backing
/// the SwiftUI ScrollView it's embedded in, and hands it to the
/// callback. Used by the transcript pane to scope its
/// `willStartLiveScrollNotification` observer (which suspends Follow
/// on user-initiated scrolling) to the transcript's own scroll view.
///
/// **Why this exists instead of `onScrollPhaseChange`.** The SwiftUI
/// scroll-phase modifier changes how the backing NSScrollView routes
/// events on macOS, which broke the transcript rows' tap-to-seek
/// gestures (clicks stopped reaching the miniplayer seek handler).
/// This approach is purely observational — an invisible zero-size
/// view walks `superview` pointers once after insertion, then AppKit
/// notifications do the rest. Nothing about event routing changes.
///
/// **Timing.** The superview walk runs on the next runloop turn after
/// `makeNSView` — at make-time the view isn't in the hierarchy yet.
/// One retry via `updateNSView` covers lazy re-parenting.
private struct ScrollViewGrabber: NSViewRepresentable {
    let onFound: (NSScrollView) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async {
            reportEnclosingScrollView(from: v)
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            reportEnclosingScrollView(from: nsView)
        }
    }

    private func reportEnclosingScrollView(from view: NSView) {
        var current: NSView? = view.superview
        while let c = current {
            if let scrollView = c as? NSScrollView {
                onFound(scrollView)
                return
            }
            current = c.superview
        }
    }
}

// MARK: - DoubleClickCatcher

/// Invisible AppKit overlay that detects double-clicks on the view it
/// covers and reports the click's vertical position as a 0...1
/// fraction of the view's height.
///
/// **Why this exists.** SwiftUI Text with `.textSelection(.enabled)`
/// consumes mouse events over the glyphs at the AppKit layer — no
/// SwiftUI gesture (count-2 taps, manual two-tap tracking) ever fires
/// there. A local NSEvent monitor sees every `.leftMouseDown` BEFORE
/// the responder chain gets it, so nothing can swallow it. The catcher
/// view itself returns nil from `hitTest`, making it completely
/// transparent to event routing: text selection, hover, and the row's
/// existing single-click seek all keep working exactly as before, and
/// the double-click event is passed through unconsumed (so the word
/// still gets visually selected).
///
/// **Coordinates.** The view is flipped (top-left origin) so
/// `convert(_:from: nil)` on the window location yields a local point
/// whose y grows downward — matching how text lays out and what the
/// segment-mapping math expects.
///
/// One monitor per visible group row; each fires only for
/// clickCount == 2 in its own window, then does one rect test.
/// Negligible cost even with dozens of rows rendered.
private struct DoubleClickCatcher: NSViewRepresentable {
    let onDoubleClick: (_ yFraction: Double) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onDoubleClick = onDoubleClick
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }

    final class CatcherView: NSView {
        var onDoubleClick: ((Double) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        /// Fully transparent to hit-testing — this view never
        /// participates in event routing. Detection happens purely
        /// through the event monitor.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self,
                      event.clickCount == 2,
                      event.window === self.window else { return event }
                let local = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(local), self.bounds.height > 0 {
                    let fraction = min(max(Double(local.y / self.bounds.height), 0), 1)
                    self.onDoubleClick?(fraction)
                }
                // Never consume — word selection and everything else
                // downstream proceeds normally.
                return event
            }
        }

        private func removeMonitor() {
            if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}
