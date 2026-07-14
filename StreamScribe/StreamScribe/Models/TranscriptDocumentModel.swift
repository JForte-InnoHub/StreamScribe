import AppKit

// MARK: - Custom attributes
//
// The document model's core idea: the transcript is ONE attributed
// string, and every character knows which segment (and speaker group)
// it belongs to via custom attributes. Everything the old per-view
// architecture did with view identity — seek on click, context menus,
// playhead highlight, pin anchoring — becomes an attribute lookup at
// a character index, and everything it COULDN'T do — cross-group
// selection, precise hit-testing, find-and-replace — falls out of
// NSTextView for free.
extension NSAttributedString.Key {
    /// UUID string of the TranscriptSegment this character belongs to.
    /// Present on body text only (not headers or separators).
    static let ssSegmentID = NSAttributedString.Key("StreamScribe.segmentID")
    /// UUID string of the SpeakerGroup (its first segment's id).
    /// Present on the whole group's range including its header.
    static let ssGroupID = NSAttributedString.Key("StreamScribe.groupID")
    /// Marker (Bool true) on speaker-header paragraphs. Lets later
    /// phases treat header ranges differently (skip in selection→clip
    /// time mapping, exclude from copy-with-attribution body, etc).
    static let ssIsHeader = NSAttributedString.Key("StreamScribe.isHeader")
}

// MARK: - TranscriptDocumentModel

/// Owns the transcript's NSTextStorage and keeps it in sync with the
/// engine's segment array — Phase 1 of the document-renderer overhaul
/// (the architecture decision record lives in the PR description;
/// short version: single NSTextView document instead of per-group
/// SwiftUI Text views, unlocking cross-group selection features).
///
/// **Sync strategy: re-render from first divergence.** Rebuilding the
/// whole document on every change would be O(session) work per chunk
/// — the LS-EEND lesson all over again, but on the main thread where
/// it would stutter scrolling. Instead each rendered group keeps a
/// signature (group id + resolved display name + content hash). On
/// sync, walk the freshly computed groups against the rendered
/// signatures; the first mismatch marks the divergence point. Delete
/// document text from there to the end, re-render forward. In live
/// mode the common cases are:
///   - New chunk appends segments → divergence at (or one before)
///     the last rendered group → tiny tail re-render.
///   - Refinement replaces a 30-60s window → divergence at that
///     window's first group — near the tail by construction, since
///     refinement trails the live edge.
///   - Rename / voiceprint identification lands → divergence at the
///     renamed speaker's first group — can be large, but these are
///     rare user-scale events, not per-chunk events.
///
/// **Threading.** Everything here is @MainActor: NSTextStorage must
/// be mutated on the main thread, and the string-building for typical
/// divergence tails is far too small to justify off-main staging.
@MainActor
final class TranscriptDocumentModel {

    let textStorage = NSTextStorage()

    /// Signature of each rendered group, in document order, with the
    /// NSRange it currently occupies in `textStorage`.
    private struct RenderedGroup {
        let groupID: UUID
        let displayName: String
        let contentHash: Int
        var range: NSRange
    }
    private var renderedGroups: [RenderedGroup] = []

    // MARK: Styling

    private static let bodyFont = NSFont.systemFont(ofSize: 15, weight: .regular)
        .withSerifDesign()
    private static let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    private static let bodyParagraphStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 5
        p.paragraphSpacing = 18
        return p
    }()

    private static let headerParagraphStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = 4
        p.paragraphSpacingBefore = 6
        return p
    }()

    // MARK: Grouping

    /// Group segments into runs of identical resolved display name —
    /// the same walk `TranscriptPaneView.visibleGroups` does, taken
    /// as input here so the model doesn't depend on the engine type.
    /// `nameResolver` is expected to encapsulate rename + voiceprint
    /// + cluster-majority resolution (the caller passes a closure
    /// over `engine.displayName(forSegment:clusterMajorities:)`).
    static func makeGroups(
        segments: [TranscriptSegment],
        nameResolver: (TranscriptSegment) -> String?
    ) -> [(name: String?, group: SpeakerGroup)] {
        guard !segments.isEmpty else { return [] }
        var result: [(String?, SpeakerGroup)] = []
        var currentSegments: [TranscriptSegment] = []
        var currentName: String? = nil
        for seg in segments {
            let resolved = nameResolver(seg) ?? seg.speaker
            if resolved == currentName, !currentSegments.isEmpty {
                currentSegments.append(seg)
            } else {
                if !currentSegments.isEmpty {
                    result.append((currentName, SpeakerGroup(speaker: currentName, segments: currentSegments)))
                }
                currentSegments = [seg]
                currentName = resolved
            }
        }
        if !currentSegments.isEmpty {
            result.append((currentName, SpeakerGroup(speaker: currentName, segments: currentSegments)))
        }
        return result
    }

    // MARK: Sync

    /// Bring `textStorage` up to date with `groups`. See the class
    /// docstring for the divergence strategy.
    func sync(groups: [(name: String?, group: SpeakerGroup)]) {
        // Compute fresh signatures.
        let fresh: [(name: String?, group: SpeakerGroup, hash: Int)] = groups.map {
            ($0.name, $0.group, Self.contentHash(of: $0.group))
        }

        // Find first divergence between rendered state and fresh state.
        var divergence = 0
        while divergence < renderedGroups.count && divergence < fresh.count {
            let r = renderedGroups[divergence]
            let f = fresh[divergence]
            guard r.groupID == f.group.id,
                  r.displayName == (f.name ?? "Speaker"),
                  r.contentHash == f.hash else { break }
            divergence += 1
        }

        // Fully in sync?
        if divergence == renderedGroups.count && divergence == fresh.count {
            return
        }

        // Document location where re-rendering starts: the start of
        // the first divergent rendered group, or end-of-document if
        // we're purely appending.
        let rerenderLocation: Int
        if divergence < renderedGroups.count {
            rerenderLocation = renderedGroups[divergence].range.location
        } else {
            rerenderLocation = textStorage.length
        }

        // Build replacement text for everything from the divergence on.
        let replacement = NSMutableAttributedString()
        var newRendered: [RenderedGroup] = Array(renderedGroups.prefix(divergence))
        var cursor = rerenderLocation
        for item in fresh.suffix(from: divergence) {
            let name = item.name ?? "Speaker"
            let rendered = Self.render(group: item.group, displayName: name)
            let range = NSRange(location: cursor, length: rendered.length)
            newRendered.append(RenderedGroup(
                groupID: item.group.id,
                displayName: name,
                contentHash: item.hash,
                range: range
            ))
            replacement.append(rendered)
            cursor += rendered.length
        }

        // Apply as a single edit for one layout/notification pass.
        let replaceRange = NSRange(location: rerenderLocation,
                                   length: textStorage.length - rerenderLocation)
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: replaceRange, with: replacement)
        textStorage.endEditing()

        renderedGroups = newRendered
    }

    /// Locate the segment ID at a document character index, if the
    /// character belongs to segment body text. The primitive that
    /// later phases build on (click→seek, selection→time-span).
    func segmentID(at location: Int) -> UUID? {
        guard location >= 0, location < textStorage.length else { return nil }
        guard let raw = textStorage.attribute(.ssSegmentID, at: location, effectiveRange: nil) as? String else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    // MARK: Rendering

    private static func render(group: SpeakerGroup, displayName: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let groupIDString = group.id.uuidString

        // Header: "● Name    00:12 – 01:30\n"
        let headerColor = speakerColor(for: group.speaker ?? displayName)
        let header = NSMutableAttributedString()
        header.append(NSAttributedString(string: "● ", attributes: [
            .font: headerFont,
            .foregroundColor: headerColor,
        ]))
        header.append(NSAttributedString(string: displayName, attributes: [
            .font: headerFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        header.append(NSAttributedString(string: "   \(group.formattedTimeRange)", attributes: [
            .font: timeFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        header.append(NSAttributedString(string: "\n"))
        header.addAttributes([
            .ssIsHeader: true,
            .ssGroupID: groupIDString,
            .paragraphStyle: headerParagraphStyle,
        ], range: NSRange(location: 0, length: header.length))
        out.append(header)

        // Body: segments joined by single spaces, each segment's
        // range carrying its own ssSegmentID. This mirrors
        // `combinedText`'s construction so the visible text is
        // identical to the old renderer's — but with per-character
        // provenance the old renderer never had.
        let body = NSMutableAttributedString()
        var first = true
        for seg in group.segments {
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !first {
                body.append(NSAttributedString(string: " ", attributes: [
                    .font: bodyFont,
                    .foregroundColor: NSColor.labelColor,
                ]))
            }
            first = false
            body.append(NSAttributedString(string: trimmed, attributes: [
                .font: bodyFont,
                .foregroundColor: NSColor.labelColor,
                .ssSegmentID: seg.id.uuidString,
            ]))
        }
        body.append(NSAttributedString(string: "\n", attributes: [
            .font: bodyFont,
        ]))
        body.addAttributes([
            .ssGroupID: groupIDString,
            .paragraphStyle: bodyParagraphStyle,
        ], range: NSRange(location: 0, length: body.length))
        out.append(body)

        return out
    }

    private static func contentHash(of group: SpeakerGroup) -> Int {
        var hasher = Hasher()
        for seg in group.segments {
            hasher.combine(seg.id)
            hasher.combine(seg.text)
        }
        return hasher.finalize()
    }

    /// Same palette + hash as the SwiftUI SpeakerBadge so the two
    /// renderers stay visually consistent during the migration.
    private static func speakerColor(for label: String) -> NSColor {
        let palette: [NSColor] = [
            .systemBlue, .systemPurple, .systemOrange, .systemPink, .systemTeal,
            .systemGreen, .systemIndigo, .systemRed, .systemMint, .systemBrown,
        ]
        var hash = 0
        for char in label.unicodeScalars {
            hash = (hash &* 31) &+ Int(char.value)
        }
        return palette[abs(hash) % palette.count]
    }
}

private extension NSFont {
    /// Serif-design variant of the receiver, matching the SwiftUI
    /// renderer's `.font(.system(size: 15, design: .serif))`.
    func withSerifDesign() -> NSFont {
        guard let descriptor = fontDescriptor.withDesign(.serif) else { return self }
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
