import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var engine: TranscriptionEngine
    @State private var urlInput: String = ""
    @State private var showExportSheet: Bool = false
    @State private var exportFormat: TranscriptFormat = .rtf

    // Export formatting preferences. Read from UserDefaults via @AppStorage,
    // populated by the Settings window. Defaults match the historical export
    // behavior so a fresh install produces the same output as before this
    // window was added. The composite `ExportOptions` value gets assembled
    // at export time below — we don't keep an `ExportOptions` mirror in
    // @State because doing so would require manual sync with three separate
    // @AppStorage observers.
    @AppStorage("export.includeTimestamps")
    private var prefIncludeTimestamps: Bool = true

    @AppStorage("export.speakerLabelsBold")
    private var prefSpeakerLabelsBold: Bool = true

    @AppStorage("export.speakerPlacement")
    private var prefSpeakerPlacement: SpeakerPlacement = .above

    @AppStorage("export.includeTitle")
    private var prefIncludeTitle: Bool = true

    @AppStorage("export.includeSource")
    private var prefIncludeSource: Bool = true

    @AppStorage("export.includeGenerated")
    private var prefIncludeGenerated: Bool = true

    @State private var isDropTargeted: Bool = false

    /// Which right-side panel is open, if any. The two panels are mutually exclusive
    /// to keep the layout from getting cluttered on narrow windows.
    @State private var openRightPanel: RightPanel? = nil

    /// Set by PinPanel when the user clicks "Show" on a pin. The transcript pane
    /// observes this and scrolls to the matching segment, then clears it.
    @State private var scrollToSegmentID: UUID? = nil

    enum RightPanel { case speakers, pins }

    var body: some View {
        HSplitView {
            SidebarView(
                urlInput: $urlInput,
                onStart: {
                    // Phase 8: start() is now async (it may probe the source
                    // for duration before kicking off the pipeline — see
                    // `TranscriptionEngine.beginProbe`). Wrap in a Task so
                    // the button's closure can fire-and-forget.
                    let input = urlInput
                    Task { await engine.start(urlString: input) }
                },
                onStop: { engine.stop() },
                onExport: { showExportSheet = true }
            )
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)

            TranscriptPaneView(
                openRightPanel: $openRightPanel,
                scrollToSegmentID: $scrollToSegmentID
            )
            .frame(minWidth: 480)

            if openRightPanel == .speakers {
                SpeakerPanel(onClose: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        openRightPanel = nil
                    }
                })
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if openRightPanel == .pins {
                PinPanel(
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            openRightPanel = nil
                        }
                    },
                    onSelect: { segmentID in
                        // Tell the transcript view to scroll there. The panel stays
                        // open so the user can keep clicking through pins.
                        scrollToSegmentID = segmentID
                    }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // Drag-and-drop the *whole* window: drop a video/audio file anywhere onto the app
        // and we populate the URL field with its path. Don't auto-start — let the user
        // confirm engine choice first, then hit Start.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay(dropOverlay)
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(
                format: $exportFormat,
                onExport: {
                    // Assemble ExportOptions from the AppStorage-backed
                    // preferences at the moment of export. Doing it here
                    // (rather than holding an ExportOptions mirror in
                    // @State) means changes the user makes in the Settings
                    // window are picked up immediately on the next export
                    // — no observer plumbing required.
                    let options = ExportOptions(
                        includeTimestamps: prefIncludeTimestamps,
                        speakerLabelsBold: prefSpeakerLabelsBold,
                        speakerPlacement: prefSpeakerPlacement,
                        includeTitle: prefIncludeTitle,
                        includeSource: prefIncludeSource,
                        includeGenerated: prefIncludeGenerated
                    )
                    TranscriptExporter.saveToDisk(
                        segmentsForExport(engine: engine),
                        format: exportFormat,
                        sourceURL: urlInput,
                        title: engine.detectedTitle,
                        speakerNames: engine.speakerNames,
                        options: options
                    )
                    showExportSheet = false
                },
                onCancel: { showExportSheet = false },
                onExportMedia: {
                    exportMedia(engine: engine)
                    showExportSheet = false
                },
                mediaAvailable: engine.playbackMediaURL != nil
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportTranscript)) { _ in
            if !engine.segments.isEmpty {
                showExportSheet = true
            }
        }
    }

    /// Visual feedback while a drag is hovering. Shows a tinted border with a friendly hint.
    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                Color.accentColor.opacity(isDropTargeted ? 0.8 : 0),
                style: StrokeStyle(lineWidth: 4, dash: [10, 6])
            )
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.opacity(isDropTargeted ? 0.05 : 0))
            )
            .overlay(
                Group {
                    if isDropTargeted {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.system(size: 36))
                            Text("Drop to load file")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            )
            .padding(8)
            .allowsHitTesting(false)  // pass clicks through; this is a visual overlay only
            .animation(.easeOut(duration: 0.15), value: isDropTargeted)
    }

    /// Pull the first dropped file URL and stuff its path into the URL field.
    /// We don't auto-start because: (a) the user might want to switch engines first,
    /// (b) starting silently from a drop feels like an accident waiting to happen.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        // loadItem on .fileURL returns a Data containing a bookmark or NSURL representation.
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data,
               let resolved = URL(dataRepresentation: data, relativeTo: nil) {
                url = resolved
            } else if let direct = item as? URL {
                url = direct
            }
            guard let url else { return }
            DispatchQueue.main.async {
                // If we're not already running, populate the input. If we are, ignore the
                // drop — drops mid-stream would be confusing.
                if !engine.state.isActive {
                    urlInput = url.path
                }
            }
        }
        return true
    }

    /// Build the segment array sent to `TranscriptExporter` with each
    /// segment's `speaker` field replaced by its EFFECTIVE display
    /// name — the result of walking the same precedence the transcript
    /// pane uses (manual rename → manual segment ID → manual cluster
    /// ID → automatic segment ID → cluster ID fallback). Without this
    /// step, exports would show generic "Speaker 1" labels even when
    /// the on-screen transcript shows "Bernie Sanders," because the
    /// exporter operates purely on cluster IDs.
    ///
    /// **Why mutate rather than thread voiceprint state through the
    /// exporter.** The exporter is a pure renderer — it takes
    /// segments + speakerNames and produces output. Adding a
    /// VoiceprintService dependency would couple a stateless renderer
    /// to a runtime singleton, complicating testing and making the
    /// exporter aware of features outside its concern. Pre-resolving
    /// here means the exporter sees segments whose `speaker` field
    /// already IS the display name, and its existing grouping
    /// (`groupedBySpeaker()`) naturally splits cluster merges
    /// because segments with different identified names now have
    /// different speaker fields.
    private func segmentsForExport(engine: TranscriptionEngine) -> [TranscriptSegment] {
        // Compute cluster majorities once so the per-segment loop
        // below is O(N), not O(N²). Without this, every displayName
        // call would re-walk segments to determine its cluster's
        // majority.
        let majorities = engine.clusterMajorityIdentifications()

        return engine.segments.map { seg -> TranscriptSegment in
            var copy = seg
            // `displayName(forSegment:clusterMajorities:)` returns the
            // effective name already factoring in voiceprint
            // identifications + manual cluster reassignments +
            // per-segment overrides + cluster majority smoothing.
            // For unidentified speakers with no cluster majority it
            // returns the cluster ID unchanged, so this is a safe
            // transformation in all cases.
            if let resolved = engine.displayName(
                forSegment: seg,
                clusterMajorities: majorities
            ) {
                copy.speaker = resolved
            }
            return copy
        }
    }

    /// Handle the "Export Media…" button: copy whatever's at
    /// `engine.playbackMediaURL` (either the original local file for
    /// imported transcriptions, or the cached mp4 for URL-based ones)
    /// to a user-chosen location. Opens an NSSavePanel with a sensible
    /// default filename derived from the detected title.
    ///
    /// **Why copy rather than move.** The source might still be in use
    /// — the miniplayer holds it open for playback, the engine may
    /// re-read it for refinement passes, and the cache manager owns
    /// its lifecycle. Moving would yank the file out from under those
    /// consumers. Copy is the safe operation.
    ///
    /// **Filename strategy.** Use the detected title (the video's
    /// human-readable title from yt-dlp's metadata) as the base name,
    /// falling back to "StreamScribe Media" when no title is
    /// available. Preserve the source file's extension so the
    /// exported file opens with the right default app — mp4 for
    /// video, m4a for audio-only. Strip filesystem-unsafe characters
    /// from the title (slashes, colons on older filesystems) before
    /// using it.
    ///
    /// **Errors are silent in v1.** A failure here would be unusual
    /// (disk full, permissions, simultaneous deletion), and the user
    /// will notice the file isn't where they expected. Adding a
    /// proper error alert is straightforward later if it comes up
    /// in practice.
    private func exportMedia(engine: TranscriptionEngine) {
        guard let sourceURL = engine.playbackMediaURL else { return }

        let panel = NSSavePanel()
        panel.title = "Export Media"
        panel.canCreateDirectories = true

        // Derive extension from the source URL. Fall back to mp4
        // (the most common cache format) if the URL has none — this
        // shouldn't happen with our cache filenames but is harmless
        // belt-and-suspenders.
        let ext = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension

        // Sanitize the title for use as a filename. Strips POSIX path
        // separators and control characters. Doesn't try to handle
        // every edge case (windows-style invalid chars, length limits)
        // — NSSavePanel does additional validation and the user can
        // edit the suggestion before confirming.
        let rawTitle = engine.detectedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String = {
            guard let t = rawTitle, !t.isEmpty else { return "StreamScribe Media" }
            let bad = CharacterSet(charactersIn: "/\\:")
                .union(.controlCharacters)
            return t.components(separatedBy: bad).joined(separator: " ")
        }()
        panel.nameFieldStringValue = "\(title).\(ext)"

        if let contentType = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [contentType]
        }

        panel.begin { response in
            guard response == .OK, let destURL = panel.url else { return }
            do {
                // If the user picked a destination that already
                // exists, NSSavePanel has already confirmed the
                // overwrite with them — we just need to remove the
                // existing file before copyItem (which errors on
                // existing destination).
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
            } catch {
                print("[ExportMedia] copy failed: \(error.localizedDescription)")
            }
        }
    }
}
