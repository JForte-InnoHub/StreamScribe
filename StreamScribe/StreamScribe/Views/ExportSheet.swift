import SwiftUI

struct ExportSheet: View {
    @Binding var format: TranscriptFormat
    let onExport: () -> Void
    let onCancel: () -> Void
    /// Triggered by the bottom-left "Export Media…" button. Parent resolves the
    /// source (local file for imported transcriptions, cached mp4 for URL
    /// transcriptions) and runs a save panel. Independent of the transcript
    /// format selection above — media export is a separate flow that just
    /// happens to share this window.
    let onExportMedia: () -> Void
    /// Drives the enabled state of the media-export button. False when the
    /// session has no playable media (URL transcription with video cache
    /// disabled, or media cache was cleared mid-session). Disabling rather
    /// than hiding keeps the bottom bar from reflowing.
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
                Button("Export Media…", action: onExportMedia)
                    .disabled(!mediaAvailable)
                    .help(mediaAvailable
                          ? "Save a copy of the source video or audio for this transcription."
                          : "No media is available to export. URL transcriptions require the video cache to be enabled in Settings.")
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
