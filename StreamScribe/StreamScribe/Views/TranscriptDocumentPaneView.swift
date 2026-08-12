import SwiftUI
import AppKit
import Combine

/// Phase-1 host for the document-renderer transcript — the NSTextView
/// overhaul's first buildable slice. Renders the full transcript as a
/// single selectable text document via TranscriptDocumentModel.
///
/// **What works in this phase:** live-updating rendering (incremental
/// re-render from first divergence), speaker headers with the same
/// palette as the classic pane, full cross-group text selection,
/// standard Copy, and ⌘F-style find via NSTextView's built-in finder
/// bar. **What doesn't yet:** playhead highlight, follow/scroll,
/// click-to-seek, context menus, pins — those are Phases 2-4 and the
/// classic pane remains the default until they land.
///
/// The renderer is toggled in Settings → Transcript ("Use document
/// renderer (beta)") so both panes coexist during migration and any
/// regression is one toggle away from escape.
struct TranscriptDocumentPaneView: View {
    @EnvironmentObject private var engine: TranscriptionEngine
    @ObservedObject private var voiceprints = VoiceprintService.shared
    @Environment(\.openWindow) private var openWindow

    /// Right-panel routing — same binding the classic pane drives, so
    /// the speaker/pin panels work identically under both renderers.
    @Binding var openRightPanel: ContentView.RightPanel?

    /// Pin-jump navigation: the pins panel's "Show" writes a segment
    /// ID here; the pane scrolls to it, flashes it, and resets the
    /// binding. Same contract the classic pane implements.
    @Binding var scrollToSegmentID: UUID?

    /// The model owns the NSTextStorage. Created once per pane
    /// lifetime; State keeps it stable across SwiftUI re-renders.
    @State private var model = TranscriptDocumentModel()

    /// AppKit-side mechanics (highlight, scroll, manual-scroll
    /// detection). Bridges the representable's NSTextView back to
    /// this SwiftUI layer.
    @State private var controller = DocumentPlayheadController()

    /// Follow mode — same semantics as the classic pane, ported:
    /// ON = transcript tracks the playhead (or the live tail when
    /// nothing is playing); user-initiated scrolling suspends it;
    /// re-enabling snaps back.
    @State private var follow: Bool = true

    @State private var playingSegmentID: UUID? = nil

    /// Scrub debounce — port of the classic pane's 120ms coalescing:
    /// rapid playhead updates during scrubbing cancel each other and
    /// only the last one scrolls. (Highlight updates are NOT
    /// debounced — they're temporary-attribute writes, cheap enough
    /// to track every tick.)
    @State private var pendingScrollTask: Task<Void, Never>? = nil

    /// Transient feedback for selection actions ("Copied ✓" /
    /// export errors), shown in the header, auto-clearing.
    @State private var actionStatus: String? = nil
    @State private var actionStatusClearTask: Task<Void, Never>? = nil

    /// Double-click-to-seek gate — same key as the classic pane and
    /// Settings → Miniplayer.
    @AppStorage("miniplayer.doubleClickSeek")
    private var doubleClickSeekEnabled: Bool = true

    // Identify-sheet state (Phase 4) — mirrors the classic pane's,
    // sharing the same IdentifySpeakerSheet.
    @State private var showIdentifySheet: Bool = false
    @State private var showEditSheet: Bool = false
    @State private var editTargetSegmentID: UUID? = nil
    @State private var editDraftText: String = ""
    @State private var identifyMode: TranscriptIdentifyMode = .cluster
    @State private var identifyClusterID: String? = nil
    @State private var identifySegmentIDs: [UUID] = []
    @State private var identifyCurrentName: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            DocumentTextView(
                model: model,
                controller: controller,
                onCopyWithAttribution: { range in copyWithAttribution(range) },
                onExportClip: engine.playbackMediaURL?.isFileURL == true
                    ? { range in exportClip(range) }
                    : nil,
                onDoubleClickCharacter: { index in handleDoubleClick(at: index) },
                onHeaderClick: { index in handleHeaderClick(at: index) },
                buildContextItems: { index in contextItems(at: index) },
                buildSelectionContextItems: { range in selectionContextItems(for: range) }
            )
        }
        .sheet(isPresented: $showEditSheet) {
            SegmentEditSheet(
                draft: $editDraftText,
                onSave: {
                    if let id = editTargetSegmentID {
                        engine.updateSegmentText(id: id, newText: editDraftText)
                    }
                    showEditSheet = false
                },
                onDelete: {
                    if let id = editTargetSegmentID {
                        engine.deleteSegments(ids: [id])
                    }
                    showEditSheet = false
                },
                onCancel: { showEditSheet = false }
            )
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
                                clusterId: cid, name: chosenName
                            )
                        }
                    case .segments:
                        // Unified model: identifying segments splits
                        // them into a new machine speaker and names
                        // that cluster — the person always lands in
                        // the Speakers panel.
                        engine.identifySegments(Set(identifySegmentIDs), as: chosenName)
                    }
                    showIdentifySheet = false
                }
            )
        }
        .onReceive(engine.$segments
            .throttle(for: .milliseconds(300), scheduler: DispatchQueue.main, latest: true)) { _ in
            resync()
            // Live tail-follow: with Follow on and no playback
            // driving position, appended content keeps the view
            // pinned to the end — the classic pane's BOTTOM behavior.
            if follow && playingSegmentID == nil {
                controller.scrollToEnd(animated: true)
            }
        }
        .onReceive(engine.$speakerNames) { _ in resync() }
        .onReceive(voiceprints.$identifications) { _ in resync() }
        .onReceive(NotificationCenter.default.publisher(for: .miniplayerTimeUpdate)) { note in
            guard let t = (note.object as? NSNumber)?.doubleValue else { return }
            handlePlayheadTime(t)
        }
        .onAppear {
            controller.onUserScroll = {
                // Manual scroll suspends Follow — ported behavior.
                // No suppression window needed here, unlike the
                // SwiftUI pane: we own this NSScrollView and all
                // programmatic scrolls go through the controller's
                // setBoundsOrigin path, which never posts
                // willStartLiveScroll (that notification is
                // gesture-only when AppKit is driven directly —
                // the SwiftUI bridge was what blurred it before).
                if follow {
                    follow = false
                    pendingScrollTask?.cancel()
                    pendingScrollTask = nil
                    print("[DocRenderer] Follow suspended — user scrolled.")
                }
            }
            resync()
        }
        .onChange(of: scrollToSegmentID) { _, target in
            guard let target else { return }
            defer { scrollToSegmentID = nil }
            // Resolve the pin's anchor: by segment ID when it still
            // exists, else by the pin's timestamp (splits and
            // refinement can retire IDs; the first split piece keeps
            // the original ID so this mostly hits, but time is the
            // durable fallback).
            var range = model.range(ofSegment: target)
            if range == nil,
               let pin = engine.pinnedQuotes.first(where: { $0.sourceSegmentID == target }),
               let seg = engine.segments.first(where: { pin.start >= $0.start && pin.start < $0.end })
                    ?? engine.segments.first(where: { $0.start >= pin.start }) {
                range = model.range(ofSegment: seg.id)
            }
            guard let r = range else { return }
            // Jumping is a deliberate navigation — suspend Follow so
            // the live tail / playhead doesn't yank the view back.
            if follow {
                follow = false
                pendingScrollTask?.cancel()
            }
            controller.scroll(to: r, animated: true)
            controller.flash(range: r)
        }
        .onChange(of: follow) { _, isOn in
            guard isOn else { return }
            // Re-enable → snap to the playhead's position. Clearing
            // the anchor first is essential — the last scroll may have
            // targeted the same anchor we're about to snap to, and
            // stale dedupe would eat the snap-back.
            lastScrollAnchorID = nil
            if let segID = playingSegmentID, let range = model.range(ofSegment: segID) {
                controller.scroll(to: range, animated: true)
            } else {
                controller.scrollToEnd(animated: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Session title replaces the old "Document renderer · beta"
            // capsule (2026-07-22, user request): the beta badge
            // outlived its usefulness once this renderer became the
            // default, and the probed media title is what belongs at
            // the top of a transcript. Falls back to "Transcript"
            // before metadata arrives (and for local files without
            // any).
            Text({
                if let title = engine.detectedTitle, !title.isEmpty { return title }
                return "Transcript"
            }())
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(engine.detectedTitle ?? "")
            Spacer()
            if let status = actionStatus {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(status.hasPrefix("⚠") ? .red : .green)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Toggle(isOn: $follow) {
                Text("Follow")
                    .font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            .help("Track playback (or the live tail) automatically. Scrolling manually pauses following; re-enable to snap back.")
            Text("\(engine.segments.count) segments")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            // Right-panel toggles + miniplayer — mirrored from the
            // classic pane so the header affordances survive the
            // renderer switch.
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

            Button {
                controller.showFindBar()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("f", modifiers: .command)
            .help("Find in transcript (⌘F)")
            .disabled(engine.segments.isEmpty)

            // Manual LLM cleanup — user-triggered so the multi-minute
            // cost on long transcripts is a choice, not an ambush.
            Button {
                engine.startManualTranscriptCleanup()
            } label: {
                Image(systemName: engine.isCleanupRunning ? "sparkles.rectangle.stack" : "sparkles")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help(engine.isCleanupRunning
                  ? "Cleanup running… progress shows in the status area"
                  : "Clean up transcript with the local LLM (punctuation, fillers, duplicates, names). Verbatim text is preserved; a change report is written afterward.")
            .disabled(engine.state.isActive || engine.isCleanupRunning || engine.segments.isEmpty)

            Button {
                openWindow(id: WindowID.miniplayer)
            } label: {
                Image(systemName: "play.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Open miniplayer")
            .disabled(engine.playbackMediaURL == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Dedupe for playhead scrolls, tracked separately from
    /// `playingSegmentID` because in silence gaps the scroll anchors
    /// to a NEARBY segment while the playing segment is nil — the
    /// two identities diverge exactly when gap-anchoring kicks in.
    @State private var lastScrollAnchorID: UUID? = nil

    // MARK: Playhead

    /// Resolve an engine time to a segment, update the highlight, and
    /// (when following) scroll to keep the position visible. Segment
    /// resolution is the classic pane's linear scan — O(segments),
    /// trivial at 5Hz even on multi-hour sessions.
    ///
    /// **Gap anchoring.** Playhead time frequently resolves to NO
    /// segment: leading silence before the gavel (often 10+ minutes,
    /// where the silence gate produced no segments at all) and
    /// inter-segment gaps. The highlight correctly clears there —
    /// nothing is being said — but Follow must still track position:
    /// without an anchor, scrubbing into a gap left the view stranded
    /// at its last position (field bug: scrubbing to the start of the
    /// session parked the transcript mid-document, because t≈0 lives
    /// in the leading silence). In a gap we anchor to the nearest
    /// UPCOMING segment — where playback will next produce text — so
    /// scrub-to-start lands at the document top and mid-session gaps
    /// settle on the next thing that will be said.
    private func handlePlayheadTime(_ t: TimeInterval) {
        var found: UUID? = nil
        for seg in engine.segments {
            if t >= seg.start && t < seg.end {
                found = seg.id
                break
            }
        }

        if found != playingSegmentID {
            playingSegmentID = found
            // Highlight tracks every change, follow or not.
            if let id = found, let range = model.range(ofSegment: id) {
                controller.highlight(range: range)
            } else {
                controller.clearHighlight()
            }
        }

        guard follow else { return }

        // Scroll anchor: the playing segment, or in a gap the nearest
        // upcoming segment (falling back to the last segment when
        // scrubbed past the end of transcribed content).
        let anchorID = found
            ?? engine.segments.first(where: { $0.start >= t })?.id
            ?? engine.segments.last?.id
        guard let anchor = anchorID, anchor != lastScrollAnchorID else { return }

        pendingScrollTask?.cancel()
        pendingScrollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, follow else { return }
            guard let range = model.range(ofSegment: anchor) else { return }
            lastScrollAnchorID = anchor
            controller.scroll(to: range, animated: true)
        }
    }

    private func resync() {
        let groups = TranscriptDocumentModel.makeGroups(
            segments: engine.segments,
            nameResolver: { seg in
                engine.displayName(forSegment: seg)
            }
        )
        model.sync(groups: groups)
        // Ranges may have moved for the playing segment (divergence
        // re-render behind it). Re-apply the highlight at its current
        // range so it never sits on stale coordinates.
        if let id = playingSegmentID {
            if let range = model.range(ofSegment: id) {
                controller.highlight(range: range)
            } else {
                controller.clearHighlight()
            }
        }
    }

    // MARK: Selection actions (Phase 3)

    /// Copy the selection as attributed quotes:
    ///
    ///     Rep. Hal Rogers [12:34]: …selected text…
    ///
    ///     Sen. Warren [13:02]: …
    ///
    /// Consecutive selected segments by the same (resolved) speaker
    /// merge into one quote block; partial selections copy exactly
    /// the selected words, not whole segments. The name resolution is
    /// the same displayName path the rendering uses, so what you copy
    /// matches what you see.
    private func copyWithAttribution(_ range: NSRange) {
        let slices = model.segmentSlices(in: range)
        guard !slices.isEmpty else { return }

        var segByID: [UUID: TranscriptSegment] = [:]
        for seg in engine.segments { segByID[seg.id] = seg }

        struct QuoteBlock {
            var name: String
            var start: TimeInterval
            var texts: [String]
        }
        var blocks: [QuoteBlock] = []
        for slice in slices {
            guard let seg = segByID[slice.id] else { continue }
            let name = engine.displayName(forSegment: seg)
                ?? seg.speaker ?? TranscriptSegment.unknownSpeakerDisplayName
            if var last = blocks.last, last.name == name {
                last.texts.append(slice.text)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(QuoteBlock(name: name, start: seg.start, texts: [slice.text]))
            }
        }
        guard !blocks.isEmpty else { return }

        let text = blocks.map { block in
            "\(block.name) [\(TranscriptSegment.formatTime(block.start))]: \(block.texts.joined(separator: " "))"
        }.joined(separator: "\n\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showActionStatus("Copied \(blocks.count) quote\(blocks.count == 1 ? "" : "s") with attribution ✓")
    }

    /// Export the media span covered by the selection via
    /// ClipExporter. Span = first selected segment's start to last
    /// selected segment's end; stream-copy keyframe snapping adds a
    /// couple seconds of lead-in, which is desirable context for a
    /// pulled quote. Reveals the clip in Finder on success.
    private func exportClip(_ range: NSRange) {
        let slices = model.segmentSlices(in: range)
        guard let source = engine.playbackMediaURL, source.isFileURL,
              !slices.isEmpty else { return }

        var segByID: [UUID: TranscriptSegment] = [:]
        for seg in engine.segments { segByID[seg.id] = seg }
        let covered = slices.compactMap { segByID[$0.id] }
        guard let start = covered.map(\.start).min(),
              let end = covered.map(\.end).max(), end > start else { return }

        showActionStatus("Exporting clip…")
        Task {
            do {
                let url = try await ClipExporter.exportSpan(from: source, start: start, end: end)
                await MainActor.run {
                    showActionStatus("Clip saved ✓")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                await MainActor.run {
                    showActionStatus("⚠ \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Hit-testing seek + context menu (Phase 4)

    /// Double-click on body text → seek playback to the CLICKED WORD
    /// — the character's `ssSegmentID` attribute finds the segment,
    /// and the local character offset within it resolves to a time
    /// via the segment's word clock (exact, when word timings exist)
    /// or character interpolation (sub-second, when they don't).
    /// Native word-selection still happens (we don't consume the
    /// event) and doubles as visual confirmation of the seek target.
    private func handleDoubleClick(at characterIndex: Int) {
        guard doubleClickSeekEnabled,
              engine.playbackMediaURL != nil,
              let segID = model.segmentID(at: characterIndex),
              let seg = engine.segments.first(where: { $0.id == segID }),
              let segRange = model.range(ofSegment: segID) else { return }
        let localOffset = characterIndex - segRange.location
        let t = seg.time(atCharacterOffset: localOffset)
        NotificationCenter.default.post(name: .miniplayerSeek, object: t as NSNumber)
    }

    /// Single click on a speaker HEADER → seek to the group's start.
    /// The classic pane's click-anywhere-to-seek doesn't translate to
    /// a selectable document (single click IS selection there);
    /// headers aren't meaningful selection targets, so they take the
    /// seek role.
    private func handleHeaderClick(at characterIndex: Int) {
        guard engine.playbackMediaURL != nil,
              let info = model.groupInfo(at: characterIndex),
              let firstID = info.segmentIDs.first,
              let seg = engine.segments.first(where: { $0.id == firstID }) else { return }
        NotificationCenter.default.post(name: .miniplayerSeek, object: seg.start as NSNumber)
    }

    /// Group-scoped context-menu items for a right-click at a
    /// character location — identify (cluster + segments, with the
    /// session-speaker quick list and the shared search sheet), clear,
    /// and pin. Parity notes: the classic pane's Reassign Speaker
    /// (machine-label) menu is NOT ported — voiceprint identification
    /// is the primary flow and the classic pane remains available for
    /// reassignment until a later pass.
    private func contextItems(at characterIndex: Int) -> [NSMenuItem] {
        guard let info = model.groupInfo(at: characterIndex) else { return [] }
        var segByID: [UUID: TranscriptSegment] = [:]
        for seg in engine.segments { segByID[seg.id] = seg }
        let groupSegments = info.segmentIDs.compactMap { segByID[$0] }
        guard !groupSegments.isEmpty else { return [] }
        let clusterId = groupSegments.first?.speaker

        var items: [NSMenuItem] = []

        // Pin — reconstructs the SpeakerGroup the engine's pin API
        // expects from the rendered group's segments.
        let pinGroup = SpeakerGroup(speaker: clusterId, segments: groupSegments)
        items.append(HandlerMenuItem(title: "Pin This Paragraph") {
            engine.pinGroup(pinGroup)
        })

        // Edit Text — targets the exact segment under the click
        // (falls back to the group's first segment when the click
        // landed on the header rather than body text). Corrections
        // are best made here, next to the miniplayer, rather than
        // after export.
        let clickedSegID = model.segmentID(at: characterIndex) ?? groupSegments.first?.id
        if let segID = clickedSegID, let seg = segByID[segID] {
            items.append(HandlerMenuItem(title: "Edit Text…") {
                editTargetSegmentID = segID
                editDraftText = seg.text
                showEditSheet = true
            })
            // Verbatim recovery (2026-08-07). rawText has always held
            // the original ASR words whenever cleanup or refinement
            // replaced them — this is the first way to actually get
            // them back. Shown only when there is something to restore.
            if let raw = seg.rawText, !raw.isEmpty, raw != seg.text {
                items.append(HandlerMenuItem(title: "Restore Verbatim Text") {
                    engine.restoreVerbatim(ids: [segID])
                })
            }
        }

        // Identify actions require templates + a cluster identity.
        let voiceprints = VoiceprintService.shared
        if let clusterId, !voiceprints.templates.isEmpty {
            items.append(.separator())

            let currentInfo = voiceprints.displayInfo(forClusterId: clusterId)
            if currentInfo.isIdentified {
                items.append(HandlerMenuItem(title: "Clear Identification: \(currentInfo.name)") {
                    voiceprints.clearIdentification(clusterId: clusterId)
                })
            }

            // Session speakers directly — same design as the classic
            // pane's menu (small list, sheet for the full library).
            let sessionSpeakers = voiceprints.sessionSpeakerHistory.sorted()
            for name in sessionSpeakers {
                let title = (currentInfo.isIdentified && currentInfo.name == name)
                    ? "✓ \(name)" : name
                items.append(HandlerMenuItem(title: title) {
                    voiceprints.setManualIdentification(clusterId: clusterId, name: name)
                })
            }

            items.append(HandlerMenuItem(
                title: sessionSpeakers.isEmpty ? "Choose Speaker…" : "Other Speaker…"
            ) {
                identifyMode = .cluster
                identifyClusterID = clusterId
                identifySegmentIDs = []
                identifyCurrentName = currentInfo.isIdentified ? currentInfo.name : nil
                showIdentifySheet = true
            })

            items.append(HandlerMenuItem(title: "Identify These Segments…") {
                identifyMode = .segments
                identifyClusterID = nil
                identifySegmentIDs = info.segmentIDs
                identifyCurrentName = nil
                showIdentifySheet = true
            })
        }

        return items
    }

    /// Selection-scoped context items — the reassignment feature this
    /// overhaul was substantially FOR: select exactly the sentences
    /// that were misattributed (any span, any granularity down to a
    /// single segment, across group boundaries) and reassign just
    /// those to the correct speaker. The classic pane could only
    /// operate on whole paragraphs or per-sentence submenus; here the
    /// selection IS the scope, which is both more precise and more
    /// direct.
    ///
    /// The submenu lists machine speakers with their resolved display
    /// names ("Rep. Hal Rogers (Speaker 1)") so users pick people,
    /// not opaque labels; a ✓ marks the label the selection already
    /// (uniformly) has. `engine.reassignSpeaker` handles the segment
    /// mutation and regrouping; the document re-renders through the
    /// normal divergence sync.
    private func selectionContextItems(for range: NSRange) -> [NSMenuItem] {
        let slices = model.segmentSlices(in: range)
        guard !slices.isEmpty else { return [] }

        var segByID: [UUID: TranscriptSegment] = [:]
        for seg in engine.segments { segByID[seg.id] = seg }
        let selectedSegments = slices.compactMap { segByID[$0.id] }
        let currentLabels = Set(selectedSegments.compactMap(\.speaker))
        let uniformLabel = currentLabels.count == 1 ? currentLabels.first : nil

        let machineSpeakers = engine.distinctMachineSpeakers
        guard !machineSpeakers.isEmpty else { return [] }

        // Sub-segment aware: pass each covered segment's LOCAL
        // selected range; the engine splits partially covered
        // segments at (word-snapped) selection boundaries and
        // reassigns exactly the selected words. Fully covered
        // segments reassign whole, as before.
        let splittingSlices = slices.map { (segmentID: $0.id, localRange: $0.localRange) }

        var items: [NSMenuItem] = []

        // Pin Selection — the literal selected text (not the whole
        // paragraph; "Pin This Paragraph" in the location menu still
        // does that). Span times from the covered segments.
        if let firstSeg = selectedSegments.first, let lastSeg = selectedSegments.last {
            let pinText = slices.map(\.text).joined(separator: " ")
            let pinStart = firstSeg.start
            let pinEnd = lastSeg.end
            let pinSpeaker = firstSeg.speaker
            let pinSourceID = firstSeg.id
            items.append(HandlerMenuItem(title: "Pin Selection") {
                engine.pinSelection(
                    text: pinText,
                    speaker: pinSpeaker,
                    start: pinStart,
                    end: pinEnd,
                    sourceSegmentID: pinSourceID
                )
            })
        }

        // Delete Selected Text — the DEFAULT delete (2026-07-22 UX
        // feedback: segment boundaries are invisible to users; partial
        // deletion is the common case). Removes exactly the selected
        // words via the same slice machinery as reassignment;
        // immediate, like saving an edit. Whole-segment removal stays
        // available as the explicit secondary action below, with its
        // confirmation (larger blast radius, no undo).
        if !selectedSegments.isEmpty {
            items.append(HandlerMenuItem(title: "Delete Selected Text") {
                engine.deleteSelectedText(splittingSlices)
            })

            let deleteIDs = Set(selectedSegments.map(\.id))
            items.append(HandlerMenuItem(title: "Delete \(deleteIDs.count) Entire Segment\(deleteIDs.count == 1 ? "" : "s")…") {
                let alert = NSAlert()
                alert.messageText = "Delete \(deleteIDs.count) entire segment\(deleteIDs.count == 1 ? "" : "s")?"
                alert.informativeText = "Every segment the selection touches will be removed in full — including text outside the selection. This cannot be undone."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Delete")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    engine.deleteSegments(ids: deleteIDs)
                }
            })
        }

        let submenu = NSMenu()
        for label in machineSpeakers {
            let displayName = engine.displayName(for: label) ?? label
            let title = displayName == label ? label : "\(displayName) (\(label))"
            let item = HandlerMenuItem(title: title) {
                // Diagnostic breadcrumb for the migration
                // investigation: what the action believes at click
                // time. Read alongside the engine's [Reassign] line
                // and the model's [DocRenderer] sync line.
                let resolved = engine.displayName(for: label) ?? label
                print("[DocRenderer] Reassign action: \(splittingSlices.count) slice(s) → \(label) (resolves to '\(resolved)'); current labels: \(currentLabels.sorted())")
                engine.reassignSpeaker(splittingSlices: splittingSlices, to: label)
            }
            if label == uniformLabel {
                item.state = .on
            }
            submenu.addItem(item)
        }

        // New Speaker — the recovery path for a diarizer that merged
        // two people into one cluster: no existing label is correct
        // for the selection, so mint a fresh one and move the text
        // there. The new label appears immediately as its own group;
        // right-click it to identify or rename like any speaker.
        submenu.addItem(.separator())
        submenu.addItem(HandlerMenuItem(title: "New Speaker") {
            let fresh = engine.nextUnusedMachineLabel
            print("[DocRenderer] Reassign action: \(splittingSlices.count) slice(s) → NEW label \(fresh); current labels: \(currentLabels.sorted())")
            engine.reassignSpeaker(splittingSlices: splittingSlices, to: fresh)
        })

        let parent = NSMenuItem(
            title: "Reassign Selection To",
            action: nil,
            keyEquivalent: ""
        )
        parent.submenu = submenu
        items.append(parent)
        return items
    }

    private func showActionStatus(_ text: String) {
        actionStatus = text
        actionStatusClearTask?.cancel()
        actionStatusClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            actionStatus = nil
        }
    }
}

// MARK: - DocumentPlayheadController

/// AppKit mechanics for Phase 2: temporary-attribute highlighting,
/// programmatic scrolling, and user-scroll detection. Owns weak
/// references into the representable's view hierarchy.
///
/// **Highlight via temporary attributes.** TextKit 1's
/// `NSLayoutManager.addTemporaryAttribute` colors a range WITHOUT
/// touching the text storage — no re-layout, no interference with the
/// model's divergence signatures, and cheap enough to move every
/// playhead tick. This is exactly what temporary attributes exist for
/// (Xcode's find-highlighting uses the same machinery) and one of the
/// concrete reasons Phase 1 pinned the view to TextKit 1.
@MainActor
final class DocumentPlayheadController {
    weak var textView: NSTextView?
    weak var scrollView: NSScrollView?

    /// Fired on user-initiated scroll gestures (live-scroll
    /// notifications scoped to our scroll view).
    var onUserScroll: (() -> Void)?

    private var highlightedRange: NSRange? = nil
    private var scrollObserver: NSObjectProtocol? = nil

    func attach(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onUserScroll?()
            }
        }
    }

    func highlight(range: NSRange) {
        guard let lm = textView?.layoutManager,
              let storageLength = textView?.textStorage?.length,
              NSMaxRange(range) <= storageLength else { return }
        if let old = highlightedRange {
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: old)
        }
        lm.addTemporaryAttribute(
            .backgroundColor,
            value: NSColor.controlAccentColor.withAlphaComponent(0.28),
            forCharacterRange: range
        )
        highlightedRange = range
    }

    func clearHighlight() {
        guard let lm = textView?.layoutManager, let old = highlightedRange else { return }
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: old)
        highlightedRange = nil
    }

    /// Show the NSTextView find bar (⌘F). `usesFindBar` was enabled
    /// at construction; this triggers it explicitly — SwiftUI's
    /// default Edit menu carries no Find item to route through the
    /// responder chain, so the pane's search button (and its ⌘F
    /// shortcut) drive it directly.
    func showFindBar() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.showFindInterface.rawValue
        tv.performTextFinderAction(sender)
    }

    /// Attention flash for pin-jump navigation: a brief orange
    /// emphasis on the target range that fades after ~1.6s. Separate
    /// bookkeeping from the playhead highlight — the two coexist
    /// (jumping to a pin while something is playing must not eat the
    /// playhead's highlight when the flash clears).
    private var flashRange: NSRange? = nil
    private var flashClearTask: Task<Void, Never>? = nil

    func flash(range: NSRange) {
        guard let lm = textView?.layoutManager,
              let storageLength = textView?.textStorage?.length,
              NSMaxRange(range) <= storageLength else { return }
        // Clear any previous flash first (rapid double-jumps).
        if let old = flashRange, old != highlightedRange {
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: old)
        }
        lm.addTemporaryAttribute(
            .backgroundColor,
            value: NSColor.systemOrange.withAlphaComponent(0.35),
            forCharacterRange: range
        )
        flashRange = range
        flashClearTask?.cancel()
        flashClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled, let self, let r = self.flashRange else { return }
            self.textView?.layoutManager?
                .removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
            self.flashRange = nil
            // If the flash covered the playhead's segment, restore
            // its highlight rather than leaving it bare.
            if let playing = self.highlightedRange, NSIntersectionRange(playing, r).length > 0 {
                self.textView?.layoutManager?.addTemporaryAttribute(
                    .backgroundColor,
                    value: NSColor.controlAccentColor.withAlphaComponent(0.28),
                    forCharacterRange: playing
                )
            }
        }
    }

    /// Scroll so `range` sits in the upper third of the viewport —
    /// the reading position, leaving room below for where playback is
    /// headed. Driven through `setBoundsOrigin` inside an animation
    /// context: direct clip-view scrolling never posts live-scroll
    /// notifications, so programmatic moves can't masquerade as user
    /// gestures (the failure mode that needed a suppression window in
    /// the SwiftUI pane).
    func scroll(to range: NSRange, animated: Bool) {
        guard let tv = textView, let sv = scrollView,
              let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        rect.origin.x += tv.textContainerOrigin.x
        rect.origin.y += tv.textContainerOrigin.y

        let visibleHeight = sv.contentView.bounds.height
        let targetY = max(0, rect.midY - visibleHeight / 3)
        let maxY = max(0, (sv.documentView?.frame.height ?? 0) - visibleHeight)
        let clampedY = min(targetY, maxY)
        setScrollY(clampedY, animated: animated)
    }

    func scrollToEnd(animated: Bool) {
        guard let sv = scrollView else { return }
        let visibleHeight = sv.contentView.bounds.height
        let maxY = max(0, (sv.documentView?.frame.height ?? 0) - visibleHeight)
        setScrollY(maxY, animated: animated)
    }

    private func setScrollY(_ y: CGFloat, animated: Bool) {
        guard let sv = scrollView else { return }
        let target = NSPoint(x: sv.contentView.bounds.origin.x, y: y)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                sv.contentView.animator().setBoundsOrigin(target)
            }
        } else {
            sv.contentView.setBoundsOrigin(target)
        }
        sv.reflectScrolledClipView(sv.contentView)
    }

    deinit {
        if let obs = scrollObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}

// MARK: - DocumentTextView

/// NSScrollView + NSTextView host wired to the model's shared
/// NSTextStorage. Read-only, selectable, with the system finder bar
/// enabled (⌘F works out of the box — a feature the SwiftUI pane
/// never had).
///
/// **TextKit note.** `replaceTextStorage` routes the view through the
/// classic TextKit 1 stack. That's deliberate for the migration:
/// TK1's layoutManager APIs (character↔glyph↔point mapping) are the
/// stable, documented primitives Phases 2-4 build on for playhead
/// highlighting and click hit-testing. TK2 migration can happen
/// later behind this same representable without touching callers.
private struct DocumentTextView: NSViewRepresentable {
    let model: TranscriptDocumentModel
    let controller: DocumentPlayheadController
    /// Selection-menu actions (Phase 3). `onExportClip` is nil when
    /// no exportable media is loaded — the menu item is omitted
    /// rather than disabled, matching the miniplayer clip button's
    /// convention.
    let onCopyWithAttribution: ((NSRange) -> Void)?
    let onExportClip: ((NSRange) -> Void)?
    /// Hit-testing hooks (Phase 4): character index of a double-click
    /// on body text, single-click on a header line, and group-scoped
    /// context items for a right-click location.
    let onDoubleClickCharacter: ((Int) -> Void)?
    let onHeaderClick: ((Int) -> Void)?
    let buildContextItems: ((Int) -> [NSMenuItem])?
    /// Selection-scoped items (reassignment) — invoked with the live
    /// selection range when the context menu opens over a selection.
    let buildSelectionContextItems: ((NSRange) -> [NSMenuItem])?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let contentSize = scrollView.contentSize

        // Custom TextKit 1 stack: the model's storage drives a
        // BadgeLayoutManager (draws the classic speaker-badge
        // capsules behind .ssBadgeColor ranges) into a width-tracking
        // container. Building the stack by hand replaces the earlier
        // replaceTextStorage approach — same TextKit 1 semantics, but
        // with our layout manager in the chain.
        let layoutManager = BadgeLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        ))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        model.textStorage.addLayoutManager(layoutManager)

        let textView = SelectionActionTextView(
            frame: NSRect(origin: .zero, size: contentSize),
            textContainer: textContainer
        )
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 24, height: 20)

        // Width-tracking, vertically unlimited — the standard
        // document-view configuration. (Container width tracking was
        // set at stack construction above.)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)

        textView.onCopyWithAttribution = onCopyWithAttribution
        textView.onExportClip = onExportClip
        textView.onDoubleClickCharacter = onDoubleClickCharacter
        textView.onHeaderClick = onHeaderClick
        textView.buildContextItems = buildContextItems
        textView.buildSelectionContextItems = buildSelectionContextItems
        textView.isHeaderAt = { [weak model] index in
            guard let model, index >= 0, index < model.textStorage.length else { return false }
            return model.textStorage.attribute(.ssIsHeader, at: index, effectiveRange: nil) != nil
        }

        scrollView.documentView = textView
        controller.attach(textView: textView, scrollView: scrollView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Content updates flow through the shared NSTextStorage. The
        // action closures DO need refreshing here — onExportClip
        // flips between nil and non-nil as media availability changes
        // (a session starting/stopping mid-pane-lifetime).
        guard let tv = nsView.documentView as? SelectionActionTextView else { return }
        tv.onCopyWithAttribution = onCopyWithAttribution
        tv.onExportClip = onExportClip
        tv.onDoubleClickCharacter = onDoubleClickCharacter
        tv.onHeaderClick = onHeaderClick
        tv.buildContextItems = buildContextItems
        tv.buildSelectionContextItems = buildSelectionContextItems
    }
}

// MARK: - SelectionActionTextView

/// NSTextView subclass that appends selection actions to the standard
/// text context menu. `menu(for:)` is the supported AppKit
/// customization point — the system menu (Copy, Look Up, Services…)
/// stays intact below our items.
private final class SelectionActionTextView: NSTextView {
    var onCopyWithAttribution: ((NSRange) -> Void)?
    var onExportClip: ((NSRange) -> Void)?
    var onDoubleClickCharacter: ((Int) -> Void)?
    var onHeaderClick: ((Int) -> Void)?
    var buildContextItems: ((Int) -> [NSMenuItem])?
    var buildSelectionContextItems: ((NSRange) -> [NSMenuItem])?
    /// Header test at a character index — injected by the
    /// representable so this class stays attribute-key-agnostic.
    var isHeaderAt: ((Int) -> Bool)?

    /// Character index under an event's location, or nil if the
    /// click landed past the end of content.
    private func characterIndex(for event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        guard index >= 0, index < (textStorage?.length ?? 0) else { return nil }
        return index
    }

    /// Hit-testing seek hooks. Both paths call `super` afterward so
    /// native behavior (selection, word-select on double-click)
    /// proceeds untouched — the word-selection flash doubles as
    /// confirmation of where the seek landed, same trick the classic
    /// pane used.
    override func mouseDown(with event: NSEvent) {
        if let index = characterIndex(for: event) {
            if event.clickCount == 2 {
                onDoubleClickCharacter?(index)
            } else if event.clickCount == 1, isHeaderAt?(index) == true {
                onHeaderClick?(index)
            }
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        var insertIndex = 0

        // Selection actions (Phase 3) — only with a live selection.
        let selection = selectedRange()
        if selection.length > 0 {
            if let handler = onCopyWithAttribution {
                let item = HandlerMenuItem(title: "Copy with Attribution") { [weak self] in
                    guard let self else { return }
                    handler(self.selectedRange())
                }
                menu.insertItem(item, at: insertIndex)
                insertIndex += 1
            }
            if let handler = onExportClip {
                let item = HandlerMenuItem(title: "Export Clip of Selection") { [weak self] in
                    guard let self else { return }
                    handler(self.selectedRange())
                }
                menu.insertItem(item, at: insertIndex)
                insertIndex += 1
            }
            // Selection-scoped structural actions (speaker
            // reassignment) — built against the live selection.
            if let builder = buildSelectionContextItems {
                for item in builder(selection) {
                    menu.insertItem(item, at: insertIndex)
                    insertIndex += 1
                }
            }
        }

        // Group-scoped actions (Phase 4) — identify, pin — at the
        // right-click LOCATION, selection or not. Same mental model
        // as the classic pane: right-click a paragraph to act on it.
        if let builder = buildContextItems,
           let index = characterIndex(for: event) {
            let groupItems = builder(index)
            if !groupItems.isEmpty {
                if insertIndex > 0 {
                    menu.insertItem(.separator(), at: insertIndex)
                    insertIndex += 1
                }
                for item in groupItems {
                    menu.insertItem(item, at: insertIndex)
                    insertIndex += 1
                }
            }
        }

        if insertIndex > 0 {
            menu.insertItem(.separator(), at: insertIndex)
        }
        return menu
    }
}

/// NSMenuItem that carries its own action closure — avoids threading
/// a target object through the menu construction.
private final class HandlerMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) {
        fatalError("not used")
    }

    @objc private func fire() {
        handler()
    }
}

// MARK: - BadgeLayoutManager

/// TextKit 1 layout manager that draws the classic speaker-badge
/// capsule behind any character range carrying `.ssBadgeColor` — the
/// same recipe as the SwiftUI SpeakerBadge (capsule, 12% tint fill,
/// 25%-tint hairline stroke) so the two renderers read identically.
///
/// Drawing at the layout-manager level (rather than text attachments
/// or background-color attributes) keeps the badge's name REAL TEXT:
/// selectable, copyable, and ⌘F-findable, with rounded corners and
/// padding that plain `.backgroundColor` can't do. The capsule rect
/// is the badge run's glyph bounding rect inflated by the classic
/// padding (8pt horizontal, ~3pt vertical); the header paragraph
/// style reserves the vertical clearance.
private final class BadgeLayoutManager: NSLayoutManager {

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }

        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.ssBadgeColor, in: charRange) { value, runRange, _ in
            guard let color = value as? NSColor else { return }
            let glyphRange = self.glyphRange(forCharacterRange: runRange, actualCharacterRange: nil)
            var rect = self.boundingRect(forGlyphRange: glyphRange, in: container)
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            rect = rect.insetBy(dx: -8, dy: -2.5)

            let capsule = NSBezierPath(
                roundedRect: rect,
                xRadius: rect.height / 2,
                yRadius: rect.height / 2
            )
            color.withAlphaComponent(0.12).setFill()
            capsule.fill()
            color.withAlphaComponent(0.25).setStroke()
            capsule.lineWidth = 0.5
            capsule.stroke()
        }
    }
}

/// Modal editor for one segment's text (2026-07-21 transcript-editing
/// feature). Deliberately segment-scoped rather than free-form inline
/// editing: the document renderer's range bookkeeping (badges, seek
/// hit-testing, selection slicing) assumes render-owned text, and a
/// modal keeps the mutation atomic through the engine API where the
/// userEdited protections apply.
private struct SegmentEditSheet: View {
    @Binding var draft: String
    let onSave: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit Segment Text")
                .font(.headline)
            TextEditor(text: $draft)
                .font(.system(size: 13))
                .frame(minWidth: 420, minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Text("The original transcription is preserved verbatim behind the scenes. Edited segments are protected from refinement and cleanup overwrites. Saving empty text deletes the segment.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Delete Segment", role: .destructive, action: onDelete)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
