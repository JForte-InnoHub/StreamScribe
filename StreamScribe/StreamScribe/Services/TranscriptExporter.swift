import Foundation
import AppKit
import UniformTypeIdentifiers

enum TranscriptFormat: String, CaseIterable, Identifiable {
    case plainText = "Plain Text"
    case markdown = "Markdown"
    case rtf = "Rich Text (.rtf)"
    case docx = "Word Document (.docx)"
    case srt = "SubRip (.srt)"
    case vtt = "WebVTT (.vtt)"
    case json = "JSON"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .plainText: return "txt"
        case .markdown:  return "md"
        case .rtf:       return "rtf"
        case .docx:      return "docx"
        case .srt:       return "srt"
        case .vtt:       return "vtt"
        case .json:      return "json"
        }
    }

    var contentType: UTType {
        switch self {
        case .plainText: return .plainText
        case .markdown:  return UTType("net.daringfireball.markdown") ?? .plainText
        case .rtf:       return .rtf
        // The system has a registered UTType for Office Open XML word
        // documents; reach it by file extension (filename-based lookup
        // is the most reliable across macOS versions). Fall back to
        // generic data if for some reason it's missing — the save panel
        // still works, the file is still valid .docx, just no type icon.
        case .docx:      return UTType(filenameExtension: "docx") ?? .data
        case .srt:       return UTType(filenameExtension: "srt") ?? .plainText
        case .vtt:       return UTType(filenameExtension: "vtt") ?? .plainText
        case .json:      return .json
        }
    }

    /// True for formats whose renderer returns binary bytes rather than a
    /// UTF-8 string. The save path dispatches on this to pick between
    /// `renderData(...)` and `render(...)`. Today only `.docx` is binary;
    /// keep this property here so adding future binary formats (PDF, ePub,
    /// whatever) is a one-line change to the enum.
    var isBinary: Bool {
        switch self {
        case .docx: return true
        default:    return false
        }
    }
}

/// Layout choice for the speaker label relative to the body text of each
/// transcript segment. The renderers (RTF, Markdown, Plain Text) each
/// honor this in a format-appropriate way; subtitle-style formats (SRT,
/// VTT, JSON) ignore it since they have their own structural conventions.
enum SpeakerPlacement: String, CaseIterable, Identifiable, Equatable {
    /// Speaker name on its own header row, body text below. Today's behavior
    /// for RTF and Markdown — kept as default so existing exports look the
    /// same out of the box.
    case above

    /// "Speaker Name: body text…" on a single paragraph. In RTF, the body
    /// gets a hanging indent so wrapped lines align under the start of the
    /// body text (Speaker Name acts like a column label). Markdown can't
    /// express hanging indents portably so it just emits the bold name
    /// inline. Plain text mirrors markdown without the bold markers.
    case inline

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .above:  return "Above each segment"
        case .inline: return "Inline with hanging indent"
        }
    }
}

/// User-configurable options for transcript export. Threaded into every
/// renderer so format-specific code can decide what each option means in its
/// own context (e.g. "include timestamps" is meaningful in five formats but
/// ignored in SRT/VTT, where timestamps are structurally required).
///
/// Designed to grow. Add new fields as needed; default values keep the
/// existing call sites working unchanged. The struct is value-type and small,
/// so passing it by value through the renderer chain has no real cost.
struct ExportOptions: Equatable {
    /// When true, include per-segment timestamps in formats where they're
    /// optional (markdown headers, rtf headers, plain-text headers, json
    /// fields). SRT and VTT ignore this — those formats require timestamps to
    /// be valid, so they always emit them regardless of the user's setting.
    var includeTimestamps: Bool

    /// Whether speaker labels render in bold in formats that have a bold
    /// concept (RTF, Markdown). Plain text ignores this. Defaulted to true
    /// because today's output already bolds speaker labels and most users
    /// expect them visually distinct from the body.
    var speakerLabelsBold: Bool

    /// Where the speaker label sits relative to the body text. See
    /// `SpeakerPlacement` for the per-format semantics.
    var speakerPlacement: SpeakerPlacement

    /// Document-level metadata toggles. Each controls a top-of-document line
    /// in RTF and Markdown exports:
    ///   - `includeTitle`: the "Transcript" title (h1 in markdown, bold
    ///     in RTF — historically always shown).
    ///   - `includeSource`: the "Source: <url>" line. Useful for archival
    ///     contexts; some users want clean prose without the URL.
    ///   - `includeGenerated`: the "Generated: <date>" line. Some workflows
    ///     don't want a wall-clock timestamp in the exported file (e.g.,
    ///     reproducibility, sharing without revealing capture time).
    ///
    /// Plain text export never had a document header block (no title, no
    /// source/generated metadata) — these toggles have no effect there.
    /// JSON has its own structured metadata fields and also ignores these.
    /// SRT/VTT are subtitle formats with no document header at all.
    ///
    /// All default to true so RTF and Markdown exports look the same as
    /// before these toggles existed.
    var includeTitle: Bool
    var includeSource: Bool
    var includeGenerated: Bool

    /// Sensible defaults for first-time export: include timestamps, bold
    /// speaker labels, place them above each segment, include all metadata
    /// lines. Matches the pre-Settings-window behavior so a fresh install
    /// looks identical to what users were already getting.
    static let `default` = ExportOptions(
        includeTimestamps: true,
        speakerLabelsBold: true,
        speakerPlacement: .above,
        includeTitle: true,
        includeSource: true,
        includeGenerated: true
    )
}

enum TranscriptExporter {

    /// `speakerNames` maps machine labels (e.g. "Speaker 1") to user-provided display
    /// names (e.g. "Alice"). When a label has no entry, the machine label is used as-is.
    ///
    /// `title` is the detected source title (YouTube video title, podcast episode
    /// name, local filename, etc. — surfaced via `engine.detectedTitle`). When
    /// supplied and `options.includeTitle` is on, it replaces the generic
    /// "Transcript" heading in markdown/RTF/docx exports. Nil falls back to
    /// "Transcript" so existing-behavior is preserved for sources without a
    /// probed title (HLS manifests, direct audio URLs, anything the probe
    /// couldn't title).
    ///
    /// Binary formats: `.docx` returns its bytes via `renderData(...)`, not this
    /// method — this returns an empty string for binary formats. `saveToDisk`
    /// dispatches correctly; programmatic callers should check `format.isBinary`
    /// before deciding which method to call.
    static func render(_ segments: [TranscriptSegment], as format: TranscriptFormat,
                       sourceURL: String? = nil,
                       title: String? = nil,
                       speakerNames: [String: String] = [:],
                       options: ExportOptions = .default) -> String {
        switch format {
        case .plainText: return renderPlainText(segments, speakerNames: speakerNames, options: options)
        case .markdown:  return renderMarkdown(segments, sourceURL: sourceURL, title: title, speakerNames: speakerNames, options: options)
        case .rtf:       return renderRTF(segments, sourceURL: sourceURL, title: title, speakerNames: speakerNames, options: options)
        case .docx:      return ""  // binary format — see renderData
        case .srt:       return renderSRT(segments, speakerNames: speakerNames)
        case .vtt:       return renderVTT(segments, speakerNames: speakerNames)
        case .json:      return renderJSON(segments, sourceURL: sourceURL, speakerNames: speakerNames, options: options)
        }
    }

    /// Render binary export formats. Returns nil for formats whose output is
    /// a UTF-8 string — call `render(...)` for those. Today only `.docx` is
    /// binary.
    ///
    /// `.docx` is generated via `NSAttributedString`'s built-in Office Open
    /// XML exporter, which ships with macOS Foundation. The renderer builds
    /// a NSMutableAttributedString that parallels the RTF output (same
    /// title/metadata/speaker-group structure, same font choices) and lets
    /// Foundation produce the .docx ZIP. The supported attribute subset is
    /// a documented limitation of the macOS .docx exporter — fonts, sizes,
    /// bold/italic, foreground color, paragraph indentation all survive;
    /// some advanced attributes (tracking, expansion, etc.) don't, but we
    /// don't use any of those in the transcript renderer anyway.
    @MainActor
    static func renderData(_ segments: [TranscriptSegment], as format: TranscriptFormat,
                           sourceURL: String? = nil,
                           title: String? = nil,
                           speakerNames: [String: String] = [:],
                           options: ExportOptions = .default) -> Data? {
        switch format {
        case .docx:
            return renderDOCX(segments, sourceURL: sourceURL, title: title,
                              speakerNames: speakerNames, options: options)
        default:
            return nil
        }
    }

    /// Show the macOS save panel and write the file.
    @MainActor
    static func saveToDisk(_ segments: [TranscriptSegment], format: TranscriptFormat,
                           sourceURL: String?, title: String? = nil,
                           speakerNames: [String: String] = [:],
                           options: ExportOptions = .default) {
        let panel = NSSavePanel()
        panel.title = "Export Transcript"
        panel.allowedContentTypes = [format.contentType]
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "transcript-\(stamp).\(format.fileExtension)"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        if format.isBinary {
            // Binary formats route through renderData and write raw bytes.
            // Failure here (nil return) means the renderer couldn't produce
            // a document — for docx this typically only happens if the
            // macOS Foundation .docx exporter fails on the attributed
            // string, which shouldn't happen for our limited attribute set
            // but we still want to avoid silently writing an empty file.
            if let data = renderData(segments, as: format, sourceURL: sourceURL,
                                     title: title, speakerNames: speakerNames,
                                     options: options) {
                try? data.write(to: url, options: .atomic)
            } else {
                print("[Export] \(format.rawValue) renderer returned nil; no file written.")
            }
        } else {
            let body = render(segments, as: format, sourceURL: sourceURL, title: title, speakerNames: speakerNames, options: options)
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Helper

    /// Resolve a machine label to its display name, falling back to the machine label.
    private static func displayName(_ machineLabel: String?, _ speakerNames: [String: String]) -> String? {
        guard let label = machineLabel else { return nil }
        if let custom = speakerNames[label]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        return label
    }

    // MARK: - Format renderers

    private static func renderPlainText(_ segs: [TranscriptSegment],
                                        speakerNames: [String: String],
                                        options: ExportOptions) -> String {
        let groups = segs.groupedBySpeaker()
        guard !groups.isEmpty else { return "" }

        // Plain text ignores `speakerLabelsBold` (no markup language) but
        // honors `speakerPlacement`. .above is the historical behavior:
        // speaker header on its own line, body below. .inline runs the
        // speaker label and body together on one paragraph, "Speaker: text",
        // mirroring how interview transcripts are usually typed up by hand.
        // No hanging indent is applied because plain text has no controlled
        // line wrapping; consumer apps wrap to their own width.
        var parts: [String] = []
        for group in groups {
            let nameOpt = displayName(group.speaker, speakerNames)
            var block = ""

            switch options.speakerPlacement {
            case .above:
                if let name = nameOpt {
                    if options.includeTimestamps {
                        block += "\(name) [\(group.formattedTimeRange)]\n"
                    } else {
                        block += "\(name)\n"
                    }
                } else if options.includeTimestamps {
                    block += "[\(group.formattedTimeRange)]\n"
                }
                block += group.combinedText

            case .inline:
                let prefix: String
                if let name = nameOpt {
                    if options.includeTimestamps {
                        prefix = "\(name) [\(group.formattedTimeRange)]: "
                    } else {
                        prefix = "\(name): "
                    }
                } else if options.includeTimestamps {
                    prefix = "[\(group.formattedTimeRange)] "
                } else {
                    prefix = ""
                }
                block += "\(prefix)\(group.combinedText)"
            }

            parts.append(block)
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    private static func renderMarkdown(_ segs: [TranscriptSegment], sourceURL: String?,
                                       title: String?,
                                       speakerNames: [String: String],
                                       options: ExportOptions) -> String {
        // Title and metadata block each gated on their respective option,
        // matching the RTF renderer. The trailing `---` separator is only
        // emitted when at least one header line exists; without it, the
        // first speaker section would start with a stray rule.
        //
        // Title text: prefer the probe-supplied `title` (YouTube video name,
        // podcast episode, local filename) and fall back to the generic
        // "Transcript" when the probe didn't find one (HLS, direct audio,
        // any source the title probe couldn't resolve). Markdown's `#`
        // doesn't need any escaping for normal title characters; if a title
        // contains literal `#` or backticks we still emit it verbatim
        // because that's typically what the user wants — the heading
        // renders fine even with those characters present.
        var out = ""
        if options.includeTitle {
            let heading = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? "Transcript"
            out += "# \(heading)\n\n"
        }
        if options.includeSource, let src = sourceURL {
            out += "**Source:** \(src)\n\n"
        }
        if options.includeGenerated {
            out += "**Generated:** \(Date())\n\n"
        }
        if options.includeTitle || options.includeSource || options.includeGenerated {
            out += "---\n\n"
        }

        let groups = segs.groupedBySpeaker()

        // Compose the speaker label according to `speakerLabelsBold`. Markdown's
        // `**...**` is the bold delimiter; when bolding is off, the label is
        // emitted plain. Used inline (`.inline` mode) or in the `###` header
        // (`.above` mode) by wrapping the name token.
        let nameWrap: (String) -> String = { name in
            options.speakerLabelsBold ? "**\(name)**" : name
        }

        for group in groups {
            let nameOpt = displayName(group.speaker, speakerNames)

            switch options.speakerPlacement {
            case .above:
                // Header line composition. Backticked time range is appended only
                // when the user wants timestamps; otherwise the name (or just the
                // separator if no speaker) stands alone. The `###` carries its
                // own visual emphasis; the bold wrap from `nameWrap` is layered
                // on top because some readers render `###` plain.
                switch (nameOpt, options.includeTimestamps) {
                case (let .some(name), true):
                    out += "### \(nameWrap(name)) `\(group.formattedTimeRange)`\n\n"
                case (let .some(name), false):
                    out += "### \(nameWrap(name))\n\n"
                case (.none, true):
                    out += "### `\(group.formattedTimeRange)`\n\n"
                case (.none, false):
                    // No speaker, no timestamp — emit a thematic break to keep
                    // the section break visible. Without it the body paragraphs
                    // would run together with no visual separator.
                    out += "---\n\n"
                }
                out += "\(group.combinedText)\n\n"

            case .inline:
                // Inline mode: speaker label + ": " + body on one paragraph.
                // Markdown doesn't express hanging indents portably, so this
                // is just visually inline; consumer renderers (Pandoc, GitHub,
                // VS Code preview) all wrap normally without the hanging
                // structure. Timestamp joins the label in parens when
                // requested, same convention as the RTF inline mode.
                let prefix: String
                if let name = nameOpt {
                    if options.includeTimestamps {
                        prefix = "\(nameWrap(name)) (\(group.formattedTimeRange)): "
                    } else {
                        prefix = "\(nameWrap(name)): "
                    }
                } else if options.includeTimestamps {
                    prefix = "(\(group.formattedTimeRange)) "
                } else {
                    prefix = ""
                }
                out += "\(prefix)\(group.combinedText)\n\n"
            }
        }
        return out
    }

    /// RTF (Rich Text Format) — opens natively in Word, TextEdit, Pages, and most
    /// word processors without needing the .docx ZIP container. Content mirrors the
    /// Markdown export's structure: title, source/generated metadata, then per
    /// speaker block (name + time range, then body paragraph).
    ///
    /// RTF spec notes that matter here:
    ///   • The whole document is wrapped in `{\rtf1...}`.
    ///   • `\ansi\deflang1033` declares Windows-1252 encoding + US English; we don't
    ///     actually emit Windows-1252 bytes, but the header is conventional and Word
    ///     wants it.
    ///   • Font sizes use half-points (`\fs28` = 14pt).
    ///   • Non-ASCII chars get the `\u<signed16>?` form with a `?` ASCII fallback.
    ///     Codepoints > 32767 use the negative-int trick (RTF readers treat the
    ///     16-bit value as signed). Codepoints > 0xFFFF are written as surrogate
    ///     pairs since RTF's \u is fundamentally a UTF-16 code unit.
    ///   • `\par` ends a paragraph; we double-up after blocks for visual spacing.
    private static func renderRTF(_ segs: [TranscriptSegment], sourceURL: String?,
                                  title: String?,
                                  speakerNames: [String: String],
                                  options: ExportOptions) -> String {
        // Document header. Single font (Helvetica) defined in the font table — we
        // stay sans-serif rather than the Word default Calibri because the rest of
        // the app uses system sans-serif and we don't want to depend on a font
        // that may not be installed on every reader's machine. Most readers
        // gracefully substitute when Helvetica is unavailable.
        var out = "{\\rtf1\\ansi\\ansicpg1252\\deflang1033"
        out += "{\\fonttbl{\\f0\\fswiss Helvetica;}}"
        out += "{\\colortbl;\\red102\\green102\\blue102;}"  // color 1 = mid-grey for timestamps
        out += "\\f0\\fs22 "  // default body: 11pt Helvetica

        // Title — conditional on `options.includeTitle`. Kept at \fs36 (18pt)
        // when shown; the title is the one place we deliberately use a
        // larger font size, since it visually anchors the document.
        //
        // Title text: prefer the probe-supplied `title` (YouTube video name,
        // podcast episode, local filename) and fall back to the generic
        // "Transcript" when the probe didn't find one. Run through rtfEscape
        // so non-ASCII titles ("Frédéric's podcast — Episode 5") survive the
        // ANSI codepage and embedded braces/backslashes in the title can't
        // break the RTF stream.
        if options.includeTitle {
            let heading = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? "Transcript"
            out += "{\\b\\fs36 " + rtfEscape(heading) + "}\\par\\par"
        }

        // Metadata block (mirrors the markdown export). We render dates with a
        // simple US-English DateFormatter so the output is locale-stable across
        // the user's system; the markdown export leaves `Date()` unformatted, but
        // RTF readers don't introspect dates so we may as well make it readable.
        //
        // Source and Generated lines are each independently gated on their
        // toggle. When both are off, we skip the trailing blank `\par` too so
        // the body doesn't open with a stray empty line.
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var emittedMetadataLine = false
        if options.includeSource, let src = sourceURL {
            out += "{\\b Source: }" + rtfEscape(src) + "\\par"
            emittedMetadataLine = true
        }
        if options.includeGenerated {
            out += "{\\b Generated: }" + rtfEscape(df.string(from: Date())) + "\\par"
            emittedMetadataLine = true
        }
        if emittedMetadataLine {
            out += "\\par"
        }

        // Speaker groups. The italic grey time-range block is conditional on
        // the user's includeTimestamps option. When off, headers are bold name
        // only (or omitted entirely if no speaker label exists, matching how
        // the original code handled the no-name case).
        //
        // Two layouts driven by `options.speakerPlacement`:
        //
        // .above (default, historical behavior): speaker name on its own line,
        //     body paragraph below.
        //
        // .inline: "Speaker Name: body text…" on one paragraph, body wrapping
        //     under the body text via RTF's hanging-indent paragraph props.
        //     We use \li2160\fi-2160 (left indent 2160 twips = 1.5 inches,
        //     first line indent -2160 twips back to the margin). The negative
        //     fi cancels the li for the first line — so the speaker name
        //     starts at the left margin, wrapped body lines indent by 1.5".
        //     2160 twips ≈ enough room for short display names like "Alice"
        //     or "Speaker 1" without crowding. Long names will overflow into
        //     the body column on the first line, which still reads as
        //     intended — speaker labels are short by convention.
        //
        // Font size: speaker labels render at body size (no explicit \fsXX),
        // letting them inherit the document default of \fs22 (11pt). Earlier
        // revisions used \fs26 (13pt) which made speaker labels visually
        // larger than the body — clean-looking in isolation but it created
        // a visual hierarchy mismatch (label looks like a header, body
        // looks like content). Matching sizes treats the speaker label as
        // a column label / inline tag — the right visual register for a
        // transcript.
        //
        // `\b` for bold is conditional on `options.speakerLabelsBold` for both
        // layouts.
        let groups = segs.groupedBySpeaker()
        let boldOn  = options.speakerLabelsBold ? "\\b " : ""
        let boldOff = options.speakerLabelsBold ? "\\b0 " : ""

        for group in groups {
            let nameOpt = displayName(group.speaker, speakerNames)

            switch options.speakerPlacement {
            case .above:
                // Existing behavior. Header row above, body paragraph below.
                // Speaker label uses body font size (inherits document default
                // \fs22); no explicit \fsXX. Bold (when enabled via the
                // `speakerLabelsBold` option) gives enough emphasis without
                // a separate size hierarchy.
                //
                // Each `\par` terminator is emitted as `\par ` (trailing space)
                // because RTF control words consume the immediately following
                // letters as part of their name. Without the space, `\par`
                // followed by body text starting with a letter (e.g. "I") gets
                // parsed as the undefined control word `\parI...`, which the
                // RTF parser silently drops. Symptom: the first word of every
                // body paragraph that starts with a letter disappears in
                // rendered RTF. The trailing space is consumed as the control
                // word terminator and is NOT rendered as a visible space.
                switch (nameOpt, options.includeTimestamps) {
                case (let .some(name), true):
                    out += "{" + boldOn + rtfEscape(name) + "}"
                    out += "  {\\i\\cf1\\fs20 " + rtfEscape(group.formattedTimeRange) + "\\cf0}"
                    out += "\\par "
                case (let .some(name), false):
                    out += "{" + boldOn + rtfEscape(name) + "}\\par "
                case (.none, true):
                    out += "{\\i\\cf1\\fs20 " + rtfEscape(group.formattedTimeRange) + "\\cf0}\\par "
                case (.none, false):
                    // No speaker, no timestamp — skip the header line entirely.
                    break
                }
                out += rtfEscape(group.combinedText) + "\\par\\par "

            case .inline:
                // Hanging-indent paragraph: speaker name + ": " + body on one
                // visual paragraph; wrapped body lines align under the body
                // text rather than under the speaker name. Timestamp (when
                // included) joins the speaker label in parens to avoid taking
                // up its own line — keeps the inline layout's compactness.
                out += "{\\li2160\\fi-2160 "
                if let name = nameOpt {
                    let header: String
                    if options.includeTimestamps {
                        header = "\(name) (\(group.formattedTimeRange)): "
                    } else {
                        header = "\(name): "
                    }
                    out += "{" + boldOn + rtfEscape(header) + boldOff + "}"
                } else if options.includeTimestamps {
                    // No speaker but timestamps requested — render the
                    // timestamp as the leading label in italic grey, same
                    // visual weight as the above-mode timestamp.
                    out += "{\\i\\cf1\\fs20 " + rtfEscape("(\(group.formattedTimeRange)) ") + "\\cf0}"
                }
                out += rtfEscape(group.combinedText)
                out += "\\par\\par}"
            }
        }

        // Close document. The trailing `\n` after `}` is convention; some readers
        // are picky about a missing newline at EOF.
        out += "}\n"
        return out
    }

    /// Escape a string for embedding inside RTF body text. Handles:
    ///   • RTF's three special chars: `\` `{` `}`
    ///   • Newlines → `\par`
    ///   • Non-ASCII Unicode → `\u<codepoint>?` (signed 16-bit form, with a `?`
    ///     ASCII fallback for readers that ignore \u). For BMP codepoints we emit
    ///     a single \u; for supplementary-plane codepoints we emit a surrogate
    ///     pair, since RTF's \u operates on UTF-16 code units.
    private static func rtfEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "{":  out += "\\{"
            case "}":  out += "\\}"
            case "\n": out += "\\par "
            case "\r": continue   // strip; \n already handled
            case "\t": out += "\\tab "
            default:
                let cp = scalar.value
                if cp < 0x80 {
                    // Pure ASCII — emit as-is.
                    out.unicodeScalars.append(scalar)
                } else if cp <= 0xFFFF {
                    // Basic Multilingual Plane. RTF's \u argument is a signed 16-bit
                    // integer; codepoints ≥ 0x8000 must be expressed as their
                    // negative two's-complement equivalent for legacy compatibility.
                    let signed = cp >= 0x8000 ? Int(cp) - 0x10000 : Int(cp)
                    out += "\\u\(signed)?"
                } else {
                    // Supplementary plane (emoji, rare CJK extensions, etc.). RTF's
                    // \u is a UTF-16 code unit, so we encode as a surrogate pair.
                    // Per UTF-16 spec: high = ((cp - 0x10000) >> 10) + 0xD800,
                    //                  low  = ((cp - 0x10000) & 0x3FF) + 0xDC00.
                    let offset = cp - 0x10000
                    let high = Int((offset >> 10) + 0xD800)
                    let low  = Int((offset & 0x3FF) + 0xDC00)
                    // Both surrogates are in 0xD800..0xDFFF (≥ 0x8000), so always
                    // emit as negative signed-16 form.
                    let signedHigh = high - 0x10000
                    let signedLow  = low - 0x10000
                    out += "\\u\(signedHigh)?\\u\(signedLow)?"
                }
            }
        }
        return out
    }

    // MARK: - DOCX

    /// Build a .docx file by constructing an NSAttributedString and asking
    /// macOS Foundation to serialize it as Office Open XML.
    ///
    /// Layout parallels the RTF renderer: optional title (large bold heading),
    /// optional source + generated metadata block, then per-speaker-group
    /// paragraphs with the same `.above` vs `.inline` placement rules. Same
    /// font choices (Helvetica, 11pt body, 18pt title), same secondary color
    /// for timestamps.
    ///
    /// macOS's Office Open XML writer supports a documented subset of
    /// `NSAttributedString` attributes — fonts, sizes, bold/italic via font
    /// traits, foreground color, paragraph indentation (firstLineHeadIndent,
    /// headIndent). We don't use anything outside that subset. Tables,
    /// embedded images, headers/footers, page numbering — none of those
    /// fit our transcript model and none are needed here.
    ///
    /// Why `@MainActor`: NSFont/NSColor/NSParagraphStyle live in AppKit, and
    /// while they're documented as thread-safe to *read*, constructing them
    /// from arbitrary actors is fraught. The save panel that triggers this
    /// is already on MainActor, so staying here is free.
    @MainActor
    private static func renderDOCX(_ segs: [TranscriptSegment], sourceURL: String?,
                                   title: String?,
                                   speakerNames: [String: String],
                                   options: ExportOptions) -> Data? {
        let result = NSMutableAttributedString()

        // Font sizes match the RTF renderer's half-point math, expressed in
        // points here. \fs22 → 11pt body, \fs36 → 18pt title, \fs20 → 10pt
        // timestamp. Helvetica chosen for the same reason as RTF: the rest
        // of the app uses system sans-serif and Helvetica substitutes
        // gracefully when unavailable.
        let bodyFont = NSFont(name: "Helvetica", size: 11)
            ?? NSFont.systemFont(ofSize: 11)
        let bodyBoldFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
        let titleFont = NSFontManager.shared.convert(
            NSFont(name: "Helvetica", size: 18) ?? NSFont.systemFont(ofSize: 18),
            toHaveTrait: .boldFontMask
        )
        let timestampFont = NSFontManager.shared.convert(
            NSFont(name: "Helvetica", size: 10) ?? NSFont.systemFont(ofSize: 10),
            toHaveTrait: .italicFontMask
        )

        // Mid-grey for timestamps, matching the RTF \cf1 color (102, 102, 102).
        let timestampColor = NSColor(calibratedRed: 0.4, green: 0.4, blue: 0.4, alpha: 1.0)

        // Title block. Same fallback-to-"Transcript" semantics as the markdown
        // and RTF renderers when the probed title is nil/empty.
        if options.includeTitle {
            let heading = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? "Transcript"
            result.append(NSAttributedString(string: heading + "\n\n", attributes: [
                .font: titleFont
            ]))
        }

        // Metadata block (matches RTF). Locale-stable date formatting so
        // the output is independent of the user's system locale.
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var emittedMetadataLine = false
        if options.includeSource, let src = sourceURL {
            result.append(NSAttributedString(string: "Source: ", attributes: [.font: bodyBoldFont]))
            result.append(NSAttributedString(string: src + "\n", attributes: [.font: bodyFont]))
            emittedMetadataLine = true
        }
        if options.includeGenerated {
            result.append(NSAttributedString(string: "Generated: ", attributes: [.font: bodyBoldFont]))
            result.append(NSAttributedString(string: df.string(from: Date()) + "\n", attributes: [.font: bodyFont]))
            emittedMetadataLine = true
        }
        if emittedMetadataLine {
            result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
        }

        // Speaker groups. Mirrors the RTF layout rules exactly:
        //   - .above: speaker name on its own line (optional timestamp inline
        //     in grey italic), body paragraph below, double newline between
        //     groups.
        //   - .inline: hanging-indent paragraph with speaker label + ": " +
        //     body on a single visual paragraph. The hanging indent is
        //     expressed via NSMutableParagraphStyle (firstLineHeadIndent=0
        //     + headIndent set to about 1.5"). Word renders this faithfully.
        let groups = segs.groupedBySpeaker()
        let nameFont = options.speakerLabelsBold ? bodyBoldFont : bodyFont

        // 1.5 inches × 72 points/inch = 108 points. Roughly matches the
        // RTF renderer's 2160 twips (twip = 1/1440 inch ≈ 1/20 point;
        // 2160 twips = 108 points). Same column-label feel.
        let hangingIndent: CGFloat = 108

        let inlineParaStyle = NSMutableParagraphStyle()
        inlineParaStyle.firstLineHeadIndent = 0
        inlineParaStyle.headIndent = hangingIndent

        for group in groups {
            let nameOpt = displayName(group.speaker, speakerNames)

            switch options.speakerPlacement {
            case .above:
                switch (nameOpt, options.includeTimestamps) {
                case (let .some(name), true):
                    result.append(NSAttributedString(string: name, attributes: [.font: nameFont]))
                    result.append(NSAttributedString(string: "  " + group.formattedTimeRange + "\n", attributes: [
                        .font: timestampFont,
                        .foregroundColor: timestampColor
                    ]))
                case (let .some(name), false):
                    result.append(NSAttributedString(string: name + "\n", attributes: [.font: nameFont]))
                case (.none, true):
                    result.append(NSAttributedString(string: group.formattedTimeRange + "\n", attributes: [
                        .font: timestampFont,
                        .foregroundColor: timestampColor
                    ]))
                case (.none, false):
                    break  // no header line
                }
                result.append(NSAttributedString(string: group.combinedText + "\n\n", attributes: [
                    .font: bodyFont
                ]))

            case .inline:
                let paraStart = result.length
                if let name = nameOpt {
                    let header: String
                    if options.includeTimestamps {
                        header = "\(name) (\(group.formattedTimeRange)): "
                    } else {
                        header = "\(name): "
                    }
                    result.append(NSAttributedString(string: header, attributes: [.font: nameFont]))
                } else if options.includeTimestamps {
                    result.append(NSAttributedString(string: "(\(group.formattedTimeRange)) ", attributes: [
                        .font: timestampFont,
                        .foregroundColor: timestampColor
                    ]))
                }
                result.append(NSAttributedString(string: group.combinedText + "\n\n", attributes: [
                    .font: bodyFont
                ]))
                // Apply the hanging-indent paragraph style to the entire
                // paragraph we just wrote (header + body). NSAttributedString
                // applies paragraph styles to whole paragraphs by definition,
                // so attaching the style to ANY character in the paragraph
                // range covers the whole thing; we attach to the full range
                // to be explicit.
                let paraLen = result.length - paraStart
                if paraLen > 0 {
                    result.addAttribute(.paragraphStyle,
                                        value: inlineParaStyle,
                                        range: NSRange(location: paraStart, length: paraLen))
                }
            }
        }

        // Hand off to Foundation's Office Open XML writer. The
        // `documentType` key tells it which container format to produce;
        // the rest of the attributes dictionary is left default so the
        // page setup uses Foundation's standards (letter size, default
        // margins). Failure is rare in practice — it's only documented
        // to throw if the attribute set is unsupported, and our subset
        // is well within the supported range.
        let range = NSRange(location: 0, length: result.length)
        let docAttrs: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.officeOpenXML
        ]
        do {
            return try result.data(from: range, documentAttributes: docAttrs)
        } catch {
            print("[Export] DOCX serialization failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func renderSRT(_ segs: [TranscriptSegment],
                                  speakerNames: [String: String]) -> String {
        var out = ""
        for (i, s) in segs.enumerated() {
            out += "\(i + 1)\n"
            out += "\(srtTimestamp(s.start)) --> \(srtTimestamp(s.end))\n"
            if let name = displayName(s.speaker, speakerNames) {
                out += "[\(name)] \(s.text)\n\n"
            } else {
                out += "\(s.text)\n\n"
            }
        }
        return out
    }

    private static func renderVTT(_ segs: [TranscriptSegment],
                                  speakerNames: [String: String]) -> String {
        var out = "WEBVTT\n\n"
        for (i, s) in segs.enumerated() {
            out += "\(i + 1)\n"
            out += "\(vttTimestamp(s.start)) --> \(vttTimestamp(s.end))\n"
            if let name = displayName(s.speaker, speakerNames) {
                out += "<v \(name)>\(s.text)\n\n"
            } else {
                out += "\(s.text)\n\n"
            }
        }
        return out
    }

    private static func renderJSON(_ segs: [TranscriptSegment], sourceURL: String?,
                                   speakerNames: [String: String],
                                   options: ExportOptions) -> String {
        // Substitute display names into the segments before encoding so consumers of
        // the JSON see what the user sees on screen. Original machine labels are
        // exposed as `machineSpeaker` for traceability.
        //
        // When timestamps are disabled, `start` and `end` are encoded as nil and
        // JSONEncoder omits them entirely thanks to the optional types — so
        // consumers can check for key presence rather than seeing zero values
        // that might be confused with real timestamps.
        struct ExportedSegment: Encodable {
            let id: UUID
            let text: String
            let start: TimeInterval?
            let end: TimeInterval?
            let speaker: String?           // display name
            let machineSpeaker: String?    // original diarizer label
            let isFinalized: Bool
        }
        struct Payload: Encodable {
            let source: String?
            let generatedAt: Date
            let speakerNames: [String: String]
            let segments: [ExportedSegment]
        }
        let mapped = segs.map {
            ExportedSegment(
                id: $0.id,
                text: $0.text,
                start: options.includeTimestamps ? $0.start : nil,
                end: options.includeTimestamps ? $0.end : nil,
                speaker: displayName($0.speaker, speakerNames),
                machineSpeaker: $0.speaker,
                isFinalized: $0.isFinalized
            )
        }
        let payload = Payload(
            source: sourceURL,
            generatedAt: Date(),
            speakerNames: speakerNames,
            segments: mapped
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(payload),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "[]"
    }

    // MARK: - Timestamp helpers

    private static func srtTimestamp(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? seconds : 0
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        let ms = Int((total - floor(total)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    private static func vttTimestamp(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? seconds : 0
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        let ms = Int((total - floor(total)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}
