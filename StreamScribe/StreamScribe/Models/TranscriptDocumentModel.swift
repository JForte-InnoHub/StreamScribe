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
    /// Speaker color (NSColor) on the "● Name" span of a header —
    /// the badge layout manager draws the classic tinted capsule
    /// behind ranges carrying this attribute.
    static let ssBadgeColor = NSAttributedString.Key("StreamScribe.badgeColor")
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
        /// Segment IDs rendered in this group — lets sync evict the
        /// segment-range index entries for re-rendered groups.
        var segmentIDs: [UUID]
    }
    private var renderedGroups: [RenderedGroup] = []

    /// segmentID → character range of that segment's body text in the
    /// document. Maintained incrementally by `sync` (entries for
    /// re-rendered groups are evicted and re-added; entries before the
    /// divergence point are untouched since their ranges can't move).
    /// This is Phase 2's lookup primitive: playhead time → segment →
    /// range → highlight + scroll target, all O(1) at the 5Hz tick.
    private var segmentRangeIndex: [UUID: NSRange] = [:]

    /// Character range of a segment's body text, if rendered.
    func range(ofSegment id: UUID) -> NSRange? {
        segmentRangeIndex[id]
    }

    /// The rendered group containing a document character location —
    /// the context-menu primitive: right-click anywhere in a group
    /// (header or body) and get the group identity plus its segment
    /// IDs for identify/pin actions. Linear scan over rendered
    /// groups; hundreds of entries, invoked once per right-click.
    func groupInfo(at location: Int) -> (groupID: UUID, segmentIDs: [UUID])? {
        for group in renderedGroups where NSLocationInRange(location, group.range) {
            return (group.groupID, group.segmentIDs)
        }
        return nil
    }

    /// The segments covered by a document character range, in
    /// document order. Each entry carries: the portion of the
    /// segment's text inside the range (trimmed, for copy), the
    /// UNTRIMMED local character range within the segment's rendered
    /// text (for sub-segment splitting — offsets index into
    /// `seg.text.trimmingCharacters(...)`, which is exactly what the
    /// renderer laid down), and the segment's rendered text length
    /// (so consumers can tell partial coverage from full).
    ///
    /// Headers and separators carry no `ssSegmentID`, so selections
    /// sweeping across them contribute nothing from those characters.
    func segmentSlices(in range: NSRange) -> [(id: UUID, text: String, localRange: NSRange, segmentLength: Int)] {
        guard range.length > 0,
              NSMaxRange(range) <= textStorage.length else { return [] }
        var out: [(UUID, NSRange)] = []
        textStorage.enumerateAttribute(.ssSegmentID, in: range) { value, runRange, _ in
            guard let raw = value as? String, let id = UUID(uuidString: raw) else { return }
            // Merge continuation runs of the same segment (temporary
            // attribute boundaries can split a segment's run).
            if let last = out.last, last.0 == id {
                out[out.count - 1].1 = NSUnionRange(last.1, runRange)
            } else {
                out.append((id, runRange))
            }
        }
        return out.compactMap { (id, docRange) in
            guard let fullRange = segmentRangeIndex[id] else { return nil }
            let local = NSRange(
                location: docRange.location - fullRange.location,
                length: docRange.length
            )
            let text = (textStorage.string as NSString).substring(with: docRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return (id: id, text: text, localRange: local, segmentLength: fullRange.length)
        }
    }

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
        // Extra vertical room vs. the plain-dot design: the badge
        // capsule inflates ~3pt beyond the glyph bounds and needs
        // clearance from the paragraph above and the body below.
        p.paragraphSpacing = 6
        p.paragraphSpacingBefore = 10
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
                  r.displayName == (f.name ?? TranscriptSegment.unknownSpeakerDisplayName),
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

        // Evict index entries for every group being re-rendered — their
        // ranges are about to be invalidated. Entries before the
        // divergence keep their (unmoved) ranges.
        for stale in renderedGroups.suffix(from: divergence) {
            for segID in stale.segmentIDs {
                segmentRangeIndex.removeValue(forKey: segID)
            }
        }

        var cursor = rerenderLocation
        for item in fresh.suffix(from: divergence) {
            let name = item.name ?? TranscriptSegment.unknownSpeakerDisplayName
            let (rendered, localSegmentRanges) = Self.render(group: item.group, displayName: name)
            let range = NSRange(location: cursor, length: rendered.length)
            var segIDs: [UUID] = []
            for (segID, localRange) in localSegmentRanges {
                segmentRangeIndex[segID] = NSRange(
                    location: cursor + localRange.location,
                    length: localRange.length
                )
                segIDs.append(segID)
            }
            newRendered.append(RenderedGroup(
                groupID: item.group.id,
                displayName: name,
                contentHash: item.hash,
                range: range,
                segmentIDs: segIDs
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

        // Diagnostic (migration investigation): logs only when a
        // re-render actually applies — absence of this line after a
        // reassign means sync concluded "in sync," which points at
        // name-resolution equality upstream, not rendering.
        print("[DocRenderer] sync applied: divergence \(divergence)/\(renderedGroups.count) rendered, \(fresh.count) fresh groups; replaced \(replaceRange.length) chars with \(replacement.length).")

        renderedGroups = newRendered
    }

    /// Locate the segment ID at a document character index, if the
    /// character belongs to segment body text. The primitive that
    /// later phases build on (click→seek, selection→time-span).
    func segmentID(at location: Int) -> UUID? {
        guard textStorage.length > 0 else { return nil }
        let clamped = min(max(location, 0), textStorage.length - 1)
        if let raw = textStorage.attribute(.ssSegmentID, at: clamped, effectiveRange: nil) as? String {
            return UUID(uuidString: raw)
        }

        // BOUNDARY FALLBACK (2026-09-15). Not every character in a
        // paragraph carries a segment attribute: the single space this
        // renderer inserts BETWEEN segments has none, and neither does
        // the paragraph's trailing newline. A click landing on either
        // returned nil, and callers fall back to the group's FIRST
        // segment — so selecting just the period at a segment's end and
        // choosing Edit Text… opened the editor on the wrong segment,
        // near the top of a long speaker block.
        //
        // Those gap characters belong to the segment they FOLLOW, so
        // walk backwards. The 4-character bound matters: it covers the
        // one-space join and the newline while stopping a click inside
        // a speaker HEADER from silently resolving to the previous
        // group's last segment — headers are long, so the scan dies
        // inside them and callers keep their existing nil behaviour.
        var index = clamped - 1
        let lowerBound = max(0, clamped - 4)
        while index >= lowerBound {
            if let raw = textStorage.attribute(.ssSegmentID, at: index, effectiveRange: nil) as? String {
                return UUID(uuidString: raw)
            }
            index -= 1
        }
        return nil
    }

    // MARK: Rendering

    private static func render(
        group: SpeakerGroup,
        displayName: String
    ) -> (NSAttributedString, [(UUID, NSRange)]) {
        let out = NSMutableAttributedString()
        let groupIDString = group.id.uuidString

        // Header: "● Name    00:12 – 01:30\n" — the "● Name" span
        // carries .ssBadgeColor, which the pane's BadgeLayoutManager
        // renders as the classic tinted capsule (12% fill, hairline
        // stroke). Name text is color-matched and semibold 10pt with
        // slight tracking — the same recipe as the SwiftUI
        // SpeakerBadge, so the two renderers read identically.
        // Color keys on the MACHINE LABEL — the diarizer's stable
        // identity — never the display name (2026-07-22 fix: renaming
        // a speaker changed their color, because group.speaker carries
        // the RESOLVED name from makeGroups; hashing it re-rolled the
        // palette on every rename). The name is decoration; the color
        // is identity. Keying on the first segment's raw speaker also
        // re-aligns the transcript with SpeakerPanel/PinPanel, which
        // already hash the machine label with this same palette.
        let headerColor = speakerColor(
            for: group.segments.first?.speaker ?? group.speaker ?? displayName
        )
        let header = NSMutableAttributedString()
        let badge = NSMutableAttributedString()
        badge.append(NSAttributedString(string: "● ", attributes: [
            .font: NSFont.systemFont(ofSize: 7, weight: .bold),
            .foregroundColor: headerColor,
            .baselineOffset: 1.5,
        ]))
        badge.append(NSAttributedString(string: displayName, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: headerColor,
            .kern: 0.3,
        ]))
        badge.addAttribute(.ssBadgeColor, value: headerColor,
                           range: NSRange(location: 0, length: badge.length))
        header.append(badge)
        header.append(NSAttributedString(string: "     \(group.formattedTimeRange)", attributes: [
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
        // provenance the old renderer never had. Local ranges are
        // collected relative to `out` (header included) so the caller
        // can offset them by the group's document location for the
        // segment-range index.
        var segmentRanges: [(UUID, NSRange)] = []
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
            let localStart = out.length + body.length
            let text = NSAttributedString(string: trimmed, attributes: [
                .font: bodyFont,
                .foregroundColor: NSColor.labelColor,
                .ssSegmentID: seg.id.uuidString,
            ])
            segmentRanges.append((seg.id, NSRange(location: localStart, length: text.length)))
            body.append(text)
        }
        body.append(NSAttributedString(string: "\n", attributes: [
            .font: bodyFont,
        ]))
        body.addAttributes([
            .ssGroupID: groupIDString,
            .paragraphStyle: bodyParagraphStyle,
        ], range: NSRange(location: 0, length: body.length))
        out.append(body)

        return (out, segmentRanges)
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
