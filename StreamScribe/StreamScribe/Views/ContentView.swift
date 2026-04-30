import SwiftUI
import UniformTypeIdentifiers
import AppKit

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
                        engine.segments,
                        format: exportFormat,
                        sourceURL: urlInput,
                        title: engine.detectedTitle,
                        speakerNames: engine.speakerNames,
                        options: options
                    )
                    showExportSheet = false
                },
                onCancel: { showExportSheet = false },
                onExportMedia: { exportSourceMedia() },
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

    /// Save a copy of the session's source media (the same file the miniplayer
    /// plays from) to a user-chosen location. We deliberately just copy the
    /// file rather than re-encoding: for local-file transcriptions the source
    /// is already in its native format, and for URL transcriptions the cache
    /// is a stream-copied mp4 — re-encoding would lose quality for no gain.
    ///
    /// The save panel suggests a filename based on the detected title (falling
    /// back to the cache file's name) and preserves the source's extension so
    /// the user gets a working file regardless of whether the source was a
    /// dropped .mov, a dropped .mp3, or a YouTube-cache .mp4.
    ///
    /// Failure modes (nil media URL, missing file at the URL, copy error) are
    /// all silently no-ops with a console log — same posture as the transcript
    /// exporter above. The button is disabled when media is unavailable, so
    /// the nil case shouldn't fire in practice.
    private func exportSourceMedia() {
        guard let mediaURL = engine.playbackMediaURL else {
            print("[Export] No playback media URL available; ignoring media export.")
            return
        }
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            print("[Export] Media file missing at \(mediaURL.path); ignoring media export.")
            return
        }

        let ext = mediaURL.pathExtension.isEmpty ? "mp4" : mediaURL.pathExtension
        let baseName: String = {
            // Prefer the detected title (sanitized) so YouTube exports come out
            // as "Some Video Title.mp4" instead of "current.mp4". For local
            // files, fall back to the source file's own basename.
            if let title = engine.detectedTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                return sanitizeFilename(title)
            }
            return mediaURL.deletingPathExtension().lastPathComponent
        }()

        let panel = NSSavePanel()
        panel.title = "Export Media"
        if let contentType = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [contentType]
        }
        panel.nameFieldStringValue = "\(baseName).\(ext)"

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            // NSSavePanel guarantees the user confirmed overwrite if the file
            // exists, but it doesn't actually remove the old file for us when
            // we're copying — FileManager.copyItem refuses to overwrite. So
            // we clear the destination first; ignore "no such file" errors
            // from removeItem since that's the common case.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: mediaURL, to: destination)
        } catch {
            print("[Export] Media copy failed: \(error.localizedDescription)")
        }

        showExportSheet = false
    }

    /// Strip characters that are illegal or awkward in filenames on macOS
    /// (and that confuse downstream tools). Keeps Unicode letters and most
    /// punctuation; collapses whitespace runs to a single space.
    private func sanitizeFilename(_ raw: String) -> String {
        let banned: Set<Character> = ["/", ":", "\\", "?", "*", "\"", "<", ">", "|"]
        let cleaned = String(raw.map { banned.contains($0) ? "-" : $0 })
        let collapsed = cleaned.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        // Cap length to a sane limit — APFS allows 255 bytes but very long
        // names look terrible in Save dialogs and Finder.
        return String(collapsed.prefix(120))
    }
}
