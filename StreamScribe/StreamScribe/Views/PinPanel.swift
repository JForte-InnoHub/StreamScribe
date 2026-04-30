import SwiftUI

/// Right-side panel listing pinned quotes from the transcript. Each row shows the
/// quoted text, the speaker (display name resolved through engine.speakerNames), the
/// timestamp, a copy-to-clipboard button, and an unpin button. Clicking the row
/// requests a scroll to the source segment via `onSelect`.
struct PinPanel: View {
    @EnvironmentObject var engine: TranscriptionEngine
    let onClose: () -> Void
    /// Called when a pin row is clicked. The host uses this to scroll the transcript
    /// view to the corresponding segment.
    let onSelect: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if engine.pinnedQuotes.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(engine.pinnedQuotes) { quote in
                            // Pass the SOURCE segment ID, not the quote's own
                            // id. The host wires this through to
                            // `scrollToSegmentID` in TranscriptPaneView, which
                            // looks up the segment by ID — using the quote id
                            // would never match and the Show button would
                            // silently do nothing. The `?? UUID()` fallback
                            // sends a definitely-non-matching ID so the
                            // transcript view's scroll handler clears state
                            // and no-ops cleanly; the Show button is also
                            // `.disabled(quote.sourceSegmentID == nil)` so
                            // we shouldn't hit this branch in practice.
                            PinRow(quote: quote, onSelect: {
                                onSelect(quote.sourceSegmentID ?? UUID())
                            })
                        }
                    }
                    .padding(16)
                }
            }

            Divider()

            footer
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pinned Quotes")
                    .font(.system(size: 14, weight: .semibold))
                Text("Right-click any segment to pin")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help("Close pinned quotes panel")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "pin")
                .font(.system(size: 32, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("No pins yet")
                .font(.system(size: 12, weight: .medium))
            Text("Right-click a paragraph in the transcript to pin it, or add keywords in the sidebar to auto-pin matching segments.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button("Clear All") {
                engine.clearAllPins()
            }
            .controlSize(.small)
            .disabled(engine.pinnedQuotes.isEmpty)
            Spacer()
            Text("\(engine.pinnedQuotes.count) pin\(engine.pinnedQuotes.count == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
    }
}

private struct PinRow: View {
    @EnvironmentObject var engine: TranscriptionEngine
    let quote: PinnedQuote
    let onSelect: () -> Void

    @State private var didCopy: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Speaker + timestamp header (+ keyword badge for auto-pins)
            HStack(spacing: 8) {
                if let machineLabel = quote.speaker {
                    Circle()
                        .fill(speakerColor(for: machineLabel))
                        .frame(width: 6, height: 6)
                    Text(engine.displayName(for: machineLabel) ?? machineLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(speakerColor(for: machineLabel))
                }
                Text(formattedTimeRange)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                // Keyword badge: distinguishes auto-pinned rows from manual ones at
                // a glance and shows the user *which* keyword caused the pin (useful
                // when watching multiple terms — they'll know whether the hit was
                // for "Putin" or "Ukraine" without reading the snippet).
                if let kw = quote.matchedKeyword {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 8, weight: .semibold))
                        Text(kw)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.yellow.opacity(0.18))
                    )
                    .overlay(
                        Capsule().stroke(Color.yellow.opacity(0.45), lineWidth: 0.5)
                    )
                    .foregroundStyle(Color.orange)
                    .help("Auto-pinned because this segment contains “\(kw)”")
                }
            }

            // The quote itself
            Text(quote.text)
                .font(.system(size: 13, design: .serif))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            // Action row
            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(quote.text, forType: .string)
                    // Brief "Copied" flash on the button label.
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        didCopy = false
                    }
                } label: {
                    Label(didCopy ? "Copied" : "Copy",
                          systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Button {
                    onSelect()
                } label: {
                    Label("Show", systemImage: "arrow.up.right.square")
                        .font(.system(size: 10))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(quote.sourceSegmentID == nil)

                Spacer()

                Button {
                    engine.unpin(quote.id)
                } label: {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 10))
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .help("Unpin")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
        )
    }

    private var formattedTimeRange: String {
        "\(TranscriptSegment.formatTime(quote.start)) – \(TranscriptSegment.formatTime(quote.end))"
    }

    /// Stable color per machine label, matching the SpeakerBadge palette in the
    /// transcript view so pins visually align with their source paragraphs.
    private func speakerColor(for machineLabel: String) -> Color {
        let palette: [Color] = [
            .blue, .purple, .orange, .pink, .teal, .green, .indigo, .red, .mint, .brown
        ]
        var hash = 0
        for char in machineLabel.unicodeScalars {
            hash = (hash &* 31) &+ Int(char.value)
        }
        return palette[abs(hash) % palette.count]
    }
}
