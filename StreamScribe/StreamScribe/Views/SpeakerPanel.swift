import SwiftUI

/// Right-hand panel listing distinct speakers in the current transcript with editable
/// name fields. Edits propagate live to the transcript view and exporter via the
/// engine's `speakerNames` map (machine label → display name).
///
/// **Identity awareness.** Rows show the resolved display name (manual rename OR
/// voiceprint identification OR machine label, in priority order) rather than the
/// raw "Speaker N" label. So once a cluster is voice-matched to "Rep. Hal Rogers,"
/// the panel row shows "Rep. Hal Rogers" — same as the badges in the transcript.
/// The `@ObservedObject` on VoiceprintService ensures the panel re-renders when a
/// cluster's identification changes (auto-match landing, manual override, or
/// clearing).
struct SpeakerPanel: View {
    @EnvironmentObject var engine: TranscriptionEngine
    @ObservedObject private var voiceprints = VoiceprintService.shared
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
    @ObservedObject private var voiceprints = VoiceprintService.shared
    let machineLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(speakerColor)
                    .frame(width: 8, height: 8)

                // Primary display name — resolves to (in priority order):
                //   1. Manual rename from the TextField below
                //   2. Voiceprint-identified name (auto or manual)
                //   3. Machine label ("Speaker 1", "Speaker 2", …)
                //
                // The identified name gets the same styling as a
                // manual rename would — no visual distinction — because
                // once the identification lands, it's the same as
                // "the user telling us who this is." If it's wrong,
                // the TextField below lets them override.
                Text(displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                // Only show the raw "Speaker N" as a subtle hint IF
                // the display name has been resolved to something
                // different (either identified or manually renamed).
                // Prevents redundant "Speaker 1  ·  Speaker 1" when
                // there's no override.
                if displayName != machineLabel {
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(machineLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Spacer()
                Text("\(segmentCount) segment\(segmentCount == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            // TextField for manual rename override. Placeholder shows
            // the current effective display name — so if voiceprint
            // identified this cluster as "Rep. Hal Rogers," typing
            // in the field OVERRIDES that (user disagrees with the
            // auto-ID), and clearing the field falls back to the
            // voiceprint identification, then to machine label.
            TextField(displayName, text: nameBinding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
        }
    }

    /// Effective display name for this row. Same priority order as
    /// the transcript badge — manual rename beats voiceprint ID beats
    /// machine label. Wraps `engine.displayName(for:)` and falls back
    /// gracefully if it returns nil.
    private var displayName: String {
        engine.displayName(for: machineLabel) ?? machineLabel
    }

    /// Two-way binding that reads/writes through the engine's speakerNames dict.
    /// Empty string clears the entry so the row falls back to the machine label
    /// (or the voiceprint-identified name, if one exists).
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
