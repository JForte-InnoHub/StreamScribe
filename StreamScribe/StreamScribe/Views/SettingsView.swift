import SwiftUI

/// Single-pane Settings window content. Wired up as the `Settings { ... }`
/// scene in `StreamScribeApp`, which gets the macOS-standard menu item
/// (StreamScribe → Settings…, ⌘,) and window chrome automatically.
///
/// Storage strategy: all preferences are `@AppStorage`-backed. UserDefaults
/// keys live under per-feature namespaces (`export.*`, `mlx.*`, etc.) so
/// each section claims its own prefix. Consumers read the same defaults
/// directly when they need a value, so changes here take effect on the
/// next read without any explicit sync.
struct SettingsView: View {
    // Mirrors of `ExportOptions` fields. Keys deliberately verbose so they
    // self-document in `defaults read` output and the like.
    @AppStorage("export.includeTimestamps")
    private var includeTimestamps: Bool = true

    @AppStorage("export.speakerLabelsBold")
    private var speakerLabelsBold: Bool = true

    /// `SpeakerPlacement` is stored as its rawValue String. `@AppStorage`
    /// supports `RawRepresentable` enums whose RawValue is one of the
    /// supported primitive types — String fits.
    @AppStorage("export.speakerPlacement")
    private var speakerPlacement: SpeakerPlacement = .above

    // Document header toggles. These control the title/source/generated
    // lines at the top of RTF and Markdown exports. Each defaults true so
    // existing exports look identical to pre-Settings behavior.
    @AppStorage("export.includeTitle")
    private var includeTitle: Bool = true

    @AppStorage("export.includeSource")
    private var includeSource: Bool = true

    @AppStorage("export.includeGenerated")
    private var includeGenerated: Bool = true

    /// MLX buffer cache limit in megabytes. Constants (key name, default,
    /// bounds) are defined alongside the consuming helper in
    /// `Services/Backends/Backend.swift` (`mlxCacheLimitMBKey` etc.) so
    /// the storage layer and the UI agree on the same range. Backends
    /// re-read this at session start via `applyMLXCacheLimit()` so
    /// slider changes take effect on the next Start without restarting
    /// the app.
    @AppStorage(mlxCacheLimitMBKey)
    private var mlxCacheLimitMB: Int = mlxCacheLimitDefaultMB

    /// Whether to include video in the miniplayer cache. When off, only
    /// audio is fetched and saved — useful for very long sources, slow
    /// connections, or if the user only needs the audio to identify
    /// speakers. Toggling takes effect on the next transcription Start;
    /// in-flight transcriptions stay on whatever setting they began
    /// with (the engine captures the value at session start).
    @AppStorage(mediaCacheIncludeVideoKey)
    private var cacheVideoEnabled: Bool = mediaCacheIncludeVideoDefault

    /// Whether the user has opted in to the Debug menu. Bound to the
    /// "Show Debug menu" toggle in the Advanced section. Same
    /// UserDefaults key the matching @AppStorage in StreamScribeApp
    /// reads to decide whether to render the menu — toggling here
    /// flips the menu's visibility immediately on the next SwiftUI
    /// re-render cycle.
    @AppStorage("debug.menuEnabled") private var debugMenuEnabled: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("Include timestamps", isOn: $includeTimestamps)
                Toggle("Bold speaker labels", isOn: $speakerLabelsBold)

                Picker("Speaker label placement", selection: $speakerPlacement) {
                    ForEach(SpeakerPlacement.allCases) { placement in
                        Text(placement.displayName).tag(placement)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Transcript Export")
            } footer: {
                Text("Applies to .rtf, .md, and .txt exports. Subtitle formats (.srt, .vtt) and .json ignore these.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Include title", isOn: $includeTitle)
                Toggle("Include source URL", isOn: $includeSource)
                Toggle("Include generated date", isOn: $includeGenerated)
            } header: {
                Text("Document Header")
            } footer: {
                Text("Applies to .rtf and .md exports. Plain text and other formats don't have document headers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Include video in miniplayer cache", isOn: $cacheVideoEnabled)
            } header: {
                Text("Miniplayer")
            } footer: {
                Text("When on, the miniplayer plays the original video alongside audio (useful for visually identifying speakers). When off, only audio is fetched and cached — saves bandwidth and disk space on long videos. Local file transcriptions are unaffected; the miniplayer plays the original file directly. Takes effect on the next transcription Start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                // Slider works on Double bindings; project the Int storage
                // through a computed Binding so we keep persistence Int-typed
                // (round numbers in `defaults read`, exact values for the
                // backend's clamp logic).
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("MLX buffer cache limit")
                        Spacer()
                        Text("\(mlxCacheLimitMB) MB")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(mlxCacheLimitMB) },
                            set: { mlxCacheLimitMB = Int($0) }
                        ),
                        in: Double(mlxCacheLimitMinMB)...Double(mlxCacheLimitMaxMB),
                        step: 128
                    )
                    HStack {
                        Text("\(mlxCacheLimitMinMB) MB")
                        Spacer()
                        Text("\(mlxCacheLimitMaxMB) MB")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            } header: {
                Text("Performance")
            } footer: {
                Text("Caps the MLX framework's GPU buffer cache for Parakeet and Sortformer. Higher values keep more intermediates resident between chunks (faster, more memory); lower values force more frequent eviction (slower individual chunks, but prevents the unbounded cache growth that can slow inference to a crawl on multi-hour sessions). Default \(mlxCacheLimitDefaultMB) MB works well for most cases. Takes effect on the next transcription Start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Advanced section. Surfaces opt-in toggles for power-
            // user / diagnostic tools that the average user
            // shouldn't see by default. Currently just the Debug
            // menu visibility — if the menu's contents get richer
            // (e.g. log-level controls, cache inspectors, profiling),
            // more toggles can join this section.
            Section {
                Toggle("Show Debug menu", isOn: $debugMenuEnabled)
            } header: {
                Text("Advanced")
            } footer: {
                Text("Adds a Debug menu to the menu bar with diagnostic toggles (Force R2 Mirror, Force Retry Probe Button, etc.). Useful when troubleshooting network or model-loading issues. Off by default for new users.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 600)
    }
}

#Preview {
    SettingsView()
}
