import SwiftUI

struct ExportSheet: View {
    @Binding var format: TranscriptFormat
    let onExport: () -> Void
    let onCancel: () -> Void

    /// Fired when the user chooses "Export Media…" — saves the source
    /// media file (mp4/m4a/etc.) alongside the transcript. The action
    /// handler is provided by the parent (ContentView), which routes
    /// to `TranscriptionEngine.playbackMediaURL` and drives NSSavePanel.
    let onExportMedia: () -> Void

    /// Whether a media file is cached and available for export. Drives
    /// the disabled state of the "Export Media…" button — if the
    /// engine hasn't materialized a local media file yet (short live
    /// sessions, remote-only sources), the button greys out with a
    /// tooltip explaining why.
    let mediaAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export Transcript")
                    .font(.system(size: 18, weight: .semibold, design: .serif))
                Text("Choose a format below. Formatting options (timestamps, speaker labels) live in Settings…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(TranscriptFormat.allCases) { fmt in
                    formatOption(fmt)
                }
            }

            HStack {
                // "Export Media…" is a separate action from format-
                // based transcript export — it saves the source
                // audio/video file. Placed left of Cancel so it's
                // visible but not the primary action.
                Button("Export Media…", action: onExportMedia)
                    .disabled(!mediaAvailable)
                    .help(mediaAvailable
                          ? "Save the source media file to disk."
                          : "No media file cached for this session yet.")

                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Export…", action: onExport)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func formatOption(_ fmt: TranscriptFormat) -> some View {
        Button {
            format = fmt
        } label: {
            HStack(spacing: 12) {
                Image(systemName: format == fmt ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(format == fmt ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fmt.rawValue)
                        .font(.system(size: 13, weight: .medium))
                    Text(formatDescription(fmt))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(".\(fmt.fileExtension)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(format == fmt
                          ? Color.accentColor.opacity(0.08)
                          : Color.secondary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(format == fmt
                            ? Color.accentColor.opacity(0.4)
                            : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func formatDescription(_ fmt: TranscriptFormat) -> String {
        switch fmt {
        case .plainText: return "Speaker-grouped paragraphs"
        case .markdown:  return "Headers ready for notes apps"
        case .rtf:       return "Formatted document for Word, Pages, and TextEdit"
        case .docx:      return "Native Word document with formatting preserved"
        case .srt:       return "Standard subtitle format for video players"
        case .vtt:       return "Web subtitles with speaker voice tags"
        case .json:      return "Full structured data with all metadata"
        }
    }
}
