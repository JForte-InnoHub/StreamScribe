import SwiftUI

/// Right-hand panel listing distinct speakers in the current transcript with editable
/// name fields. Edits propagate live to the transcript view and exporter via the
/// engine's `speakerNames` map (machine label → display name).
struct SpeakerPanel: View {
    @EnvironmentObject var engine: TranscriptionEngine
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if engine.distinctMachineSpeakers.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(engine.distinctMachineSpeakers, id: \.self) { machineLabel in
                            SpeakerRow(machineLabel: machineLabel)
                        }
                    }
                    .padding(20)
                }
            }

            Divider()

            footer
        }
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Speakers")
                    .font(.system(size: 14, weight: .semibold))
                Text("Rename to update transcript")
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
            .help("Close speaker panel")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 32, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("No speakers yet")
                .font(.system(size: 12, weight: .medium))
            Text("Speakers appear here once the transcript starts populating with diarization enabled.")
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
            Button("Reset Names") {
                engine.speakerNames = [:]
            }
            .controlSize(.small)
            .disabled(engine.speakerNames.isEmpty)
            Spacer()
            Text("\(engine.distinctMachineSpeakers.count) speaker\(engine.distinctMachineSpeakers.count == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
    }
}

private struct SpeakerRow: View {
    @EnvironmentObject var engine: TranscriptionEngine
    let machineLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(speakerColor)
                    .frame(width: 8, height: 8)
                Text(machineLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(segmentCount) segment\(segmentCount == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            TextField(machineLabel, text: nameBinding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
        }
    }

    /// Two-way binding that reads/writes through the engine's speakerNames dict.
    /// Empty string clears the entry so the row falls back to the machine label.
    private var nameBinding: Binding<String> {
        Binding(
            get: { engine.speakerNames[machineLabel] ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    engine.speakerNames.removeValue(forKey: machineLabel)
                } else {
                    engine.speakerNames[machineLabel] = newValue
                }
            }
        )
    }

    private var segmentCount: Int {
        engine.segments.lazy.filter { $0.speaker == machineLabel }.count
    }

    /// Match the color used by the SpeakerBadge in the transcript pane so panel and
    /// transcript stay visually consistent. Hash function must be identical to the one
    /// in TranscriptPaneView.SpeakerBadge.
    private var speakerColor: Color {
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
