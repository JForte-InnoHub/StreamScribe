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

    /// The model owns the NSTextStorage. Created once per pane
    /// lifetime; State keeps it stable across SwiftUI re-renders.
    @State private var model = TranscriptDocumentModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            DocumentTextView(model: model)
        }
        // Re-sync on every input that can change the rendered
        // document: segments (chunks, refinement replacements),
        // manual renames, and voiceprint identifications (cluster
        // and per-segment). Throttled so a burst of per-chunk
        // updates coalesces — the divergence re-render is cheap but
        // there's no reason to run it at 10Hz during catch-up.
        .onReceive(engine.$segments
            .throttle(for: .milliseconds(300), scheduler: DispatchQueue.main, latest: true)) { _ in
            resync()
        }
        .onReceive(engine.$speakerNames) { _ in resync() }
        .onReceive(voiceprints.$identifications) { _ in resync() }
        .onReceive(voiceprints.$segmentIdentifications) { _ in resync() }
        .onAppear { resync() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Transcript")
                .font(.system(size: 14, weight: .semibold))
            Text("Document renderer · beta")
                .font(.system(size: 10))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
            Spacer()
            Text("\(engine.segments.count) segments")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func resync() {
        let majorities = engine.clusterMajorityIdentifications()
        let groups = TranscriptDocumentModel.makeGroups(
            segments: engine.segments,
            nameResolver: { seg in
                engine.displayName(forSegment: seg, clusterMajorities: majorities)
            }
        )
        model.sync(groups: groups)
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

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let contentSize = scrollView.contentSize
        let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 24, height: 20)

        // Width-tracking, vertically unlimited — the standard
        // document-view configuration.
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: .greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: .greatestFiniteMagnitude,
                                  height: .greatestFiniteMagnitude)

        // Attach the model's storage. From here on, model.sync edits
        // flow straight into layout — no representable updates needed
        // for content changes.
        textView.layoutManager?.replaceTextStorage(model.textStorage)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Content updates flow through the shared NSTextStorage; the
        // representable itself has nothing to reconcile in Phase 1.
    }
}
