import SwiftUI

struct TranscriptPaneView: View {
    @EnvironmentObject var engine: TranscriptionEngine
    @Environment(\.openWindow) private var openWindow
    @Binding var openRightPanel: ContentView.RightPanel?
    @Binding var scrollToSegmentID: UUID?
    @State private var autoScroll: Bool = true
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
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("BOTTOM", anchor: .bottom)
                    }
                }
                .onChange(of: scrollToSegmentID) { _, newValue in
                    handleScrollToSegmentRequest(newValue, proxy: proxy)
                }
                .onChange(of: playingSegmentID) { _, newID in
                    handlePlayingSegmentChange(newID, proxy: proxy)
                }
                .onChange(of: autoScroll, initial: true) { _, newValue in
                    engine.userIsFollowingTranscript = newValue
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
    /// navigating manually now.
    private func handleScrollToSegmentRequest(_ id: UUID?, proxy: ScrollViewProxy) {
        guard let id = id else { return }
        // The group's id is its first segment's id, which matches
        // PinnedQuote.sourceSegmentID. If the segment lives partway
        // through a group, fall back to whichever group contains it.
        let targetID = visibleGroups.first(where: { group in
            group.segments.contains(where: { $0.id == id })
        })?.id ?? id
        autoScroll = false
        withAnimation(.easeInOut(duration: 0.35)) {
            proxy.scrollTo(targetID, anchor: .top)
        }
        DispatchQueue.main.async {
            scrollToSegmentID = nil
        }
    }

    /// When the miniplayer's playing segment changes, scroll the
    /// containing group into view (centered) so the user can read
    /// along.
    private func handlePlayingSegmentChange(_ segID: UUID?, proxy: ScrollViewProxy) {
        guard let segID = segID else { return }
        let targetGroupID = visibleGroups.first(where: { group in
            group.segments.contains(where: { $0.id == segID })
        })?.id
        guard let target = targetGroupID else { return }
        autoScroll = false
        withAnimation(.easeOut(duration: 0.3)) {
            proxy.scrollTo(target, anchor: .center)
        }
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
    private var visibleGroups: [SpeakerGroup] {
        filteredSegments.groupedBySpeaker()
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

    /// True when this group contains the currently-playing segment.
    private var isPlaying: Bool {
        guard let id = playingSegmentID else { return false }
        return group.segments.contains(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let machineLabel = group.speaker {
                    SpeakerBadge(
                        displayName: engine.displayName(for: machineLabel) ?? machineLabel,
                        colorSeed: machineLabel
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
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .help("Pinned")
                }
            }
            Text(highlightedText)
                .font(.system(size: 15, design: .serif))
                .lineSpacing(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
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
            Divider()
            Menu {
                ForEach(engine.distinctMachineSpeakers, id: \.self) { machineLabel in
                    Button {
                        engine.reassignSpeaker(segmentIDs: groupSegmentIDs, to: machineLabel)
                    } label: {
                        // Use a checkmark-style affordance via Label so the
                        // currently-assigned speaker is visually distinct.
                        // SwiftUI doesn't have a first-class "checked menu
                        // item" — checkmark via systemImage approximates it.
                        if machineLabel == group.speaker {
                            Label(engine.displayName(for: machineLabel) ?? machineLabel,
                                  systemImage: "checkmark")
                        } else {
                            Text(engine.displayName(for: machineLabel) ?? machineLabel)
                        }
                    }
                    .disabled(machineLabel == group.speaker)
                }

                // Sentinel options — appear under their own divider since
                // they're semantically different from picking a real
                // existing speaker.
                Divider()

                Button {
                    engine.reassignSpeaker(segmentIDs: groupSegmentIDs, to: "UNKNOWN")
                } label: {
                    if group.speaker == "UNKNOWN" {
                        Label("UNKNOWN", systemImage: "checkmark")
                    } else {
                        Text("UNKNOWN")
                    }
                }
                .disabled(group.speaker == "UNKNOWN")

                Button {
                    engine.reassignSpeaker(segmentIDs: groupSegmentIDs, to: nil)
                } label: {
                    if group.speaker == nil {
                        Label("No Speaker", systemImage: "checkmark")
                    } else {
                        Text("No Speaker")
                    }
                }
                .disabled(group.speaker == nil)
            } label: {
                Label("Reassign Speaker", systemImage: "person.crop.circle.badge.questionmark")
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

    private var highlightedText: AttributedString {
        var attr = AttributedString(group.combinedText)
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

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(displayName)
                .font(.system(size: 10, weight: .semibold))
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
