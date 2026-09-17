import SwiftUI
import UniformTypeIdentifiers

/// Custom EnvironmentKey for optionally injecting the transcription
/// engine into the Settings scene. Used instead of `@EnvironmentObject`
/// because the latter crashes the entire Settings window with
/// `EnvironmentObject.error()` if injection ever fails — brittle when
/// the Settings scene has its own window lifecycle. This key returns
/// nil when no engine was injected; consumers guard accordingly.
///
/// Injection happens in `StreamScribeApp.swift`'s Settings scene
/// alongside the existing `.environmentObject(transcriptionEngine)`
/// call (belt and suspenders — both paths inject the same instance).
private struct EngineEnvironmentKey: EnvironmentKey {
    static let defaultValue: TranscriptionEngine? = nil
}

extension EnvironmentValues {
    var engineInstance: TranscriptionEngine? {
        get { self[EngineEnvironmentKey.self] }
        set { self[EngineEnvironmentKey.self] = newValue }
    }
}

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

    /// Whether double-clicking a sentence in the transcript seeks
    /// miniplayer playback to that spot. On by default. The key is
    /// read by TranscriptPaneView's SpeakerGroupView at click time,
    /// so toggling takes effect immediately — no restart or session
    /// re-start needed.
    @AppStorage("miniplayer.doubleClickSeek")
    private var doubleClickSeekEnabled: Bool = true

    /// Default length of the miniplayer's replay-buffer clip, in
    /// seconds. Primary-clicking the Clip button exports this many
    /// trailing seconds; the button's menu still offers fixed preset
    /// lengths for one-off clips. Shared key with MiniplayerWindow.
    @AppStorage("miniplayer.clipBufferSeconds")
    private var clipBufferSeconds: Int = 60

    /// Document-renderer beta flag — shared key with ContentView,
    /// which swaps the transcript pane implementation on it.
    @AppStorage("transcript.documentRenderer")
    private var useDocumentRenderer: Bool = true

    @AppStorage(TranscriptCleanupService.enabledKey)
    private var cleanupEnabled: Bool = false
    @AppStorage(TranscriptCleanupService.modelRepoKey)
    private var cleanupModelRepo: String = TranscriptCleanupService.defaultModelRepo
    @AppStorage(TranscriptCleanupService.numeralsKey)
    private var cleanupNumerals: Bool = false
    @AppStorage(TranscriptCleanupService.fastModeKey)
    private var cleanupFastMode: Bool = false
    @AppStorage(TranscriptCleanupService.fastModelRepoKey)
    private var cleanupFastModelRepo: String = TranscriptCleanupService.defaultFastModelRepo

    /// Whether the user has opted in to the Debug menu. Bound to the
    /// "Show Debug menu" toggle in the Advanced section. Same
    /// UserDefaults key the matching @AppStorage in StreamScribeApp
    /// reads to decide whether to render the menu — toggling here
    /// flips the menu's visibility immediately on the next SwiftUI
    /// re-render cycle.
    @AppStorage("debug.menuEnabled") private var debugMenuEnabled: Bool = false

    /// Observed engine reference used by the "Re-apply Dictionary"
    /// button. Read via a custom EnvironmentKey rather than
    /// `@EnvironmentObject` because SwiftUI's Settings scene has a
    /// history of losing environmentObject bindings in certain
    /// window-lifecycle scenarios — resulting in the whole Settings
    /// window crashing with `EnvironmentObject.error()` at open.
    ///
    /// The custom key returns nil when the engine wasn't injected;
    /// the "Re-apply Dictionary" button then disables itself
    /// gracefully rather than crashing the entire Settings window.
    /// This is defense in depth — the injection SHOULD succeed
    /// (StreamScribeApp.swift applies it to the Settings scene) but
    /// even a missing injection now degrades to a disabled button
    /// instead of an app crash.
    @Environment(\.engineInstance) private var engine: TranscriptionEngine?

    /// Observed dictionary state for the editor section. Singleton
    /// shared with the engine's transcribe-time hook.
    @ObservedObject private var customDictionary = CustomDictionary.shared

    /// Observed voiceprint service for the Voiceprints settings
    /// section. Surfaces template count, R2 refresh state, threshold
    /// sliders, and the master enable toggle.
    @ObservedObject private var voiceprints = VoiceprintService.shared

    /// Local state for the in-progress new-entry row. Empty strings
    /// mean the "+" button is disabled. Cleared after each successful
    /// add so the row is ready for the next entry without leftover text.
    @State private var newEntryFind: String = ""
    @State private var newEntryReplace: String = ""

    /// Set after a successful import so the user sees a confirmation
    /// dialog with the imported count. Nil = no recent import.
    @State private var importedEntryCount: Int? = nil

    /// Set when an import succeeds enough to ask the user how to merge.
    /// Holds the decoded data until the user picks Replace or Merge.
    @State private var pendingImportData: Data? = nil

    /// Generic error surfacing for import (file not JSON, wrong schema,
    /// etc.). Drives a simple alert with the message.
    @State private var importErrorMessage: String? = nil

    /// Confirmation after the "Re-apply" button runs, showing the count
    /// of segments updated.
    @State private var reapplyCompletionMessage: String? = nil

    /// "Restore punctuation and capitalization (Parakeet)" toggle in the
    /// Advanced section. **Default OFF** — the current default Parakeet
    /// model (TDT-CTC 1.1B) produces punctuation and capitalization
    /// natively via its CTC head, so post-processing isn't needed.
    /// The toggle remains so users on the 0.6B v3 fallback can opt
    /// into PnC restoration (which requires macOS 26+ with Apple
    /// Intelligence enabled — see the inline availability indicator
    /// below the toggle).
    ///
    /// The same UserDefaults key is read by ParakeetBackend's
    /// `pncRestorationEnabled` static property (kept in sync manually —
    /// both sides use `parakeet.pncRestoration`). The two defaults
    /// must agree; if you flip this, also flip the fallback in
    /// `ParakeetBackend.pncRestorationEnabled`.
    @AppStorage("parakeet.pncRestoration") private var parakeetPnCRestoration: Bool = false

    /// Live availability status of the Foundation Model that powers PnC
    /// restoration. Polled on view appear (and whenever the toggle is
    /// flipped, in case the user just enabled Apple Intelligence in
    /// System Settings and tabbed back). Drives the inline status row
    /// under the PnC toggle so unavailability is visible immediately
    /// rather than buried in console logs.
    @State private var pncAvailabilityReason: String? = nil

    /// "Show all models" toggle. Default off — the model pickers in the
    /// sidebar show only the curated essential set (Whisper Medium,
    /// Large v3 Turbo, Large v3 Turbo 4-bit; Parakeet TDT 0.6B v3 and
    /// TDT-CTC 1.1B). When on, the full list of available models
    /// appears in the pickers — useful for testing, hardware-specific
    /// constraints, or comparing variants. Persisted via @AppStorage
    /// using the same UserDefaults key SidebarView reads.
    @AppStorage("models.showAllModels") private var showAllModels: Bool = false

    /// Observed instance of the singleton UpdateChecker. We observe the
    /// singleton directly rather than receiving it via @EnvironmentObject
    /// because Settings scenes in SwiftUI don't automatically inherit
    /// the environment objects set on WindowGroup content — Settings
    /// runs in its own scene hierarchy. Direct singleton observation
    /// works fine since UpdateChecker.shared is a static reference that
    /// keeps the object alive for the app's lifetime.
    @ObservedObject private var updateChecker = UpdateChecker.shared

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
                Toggle("Double-click transcript to seek", isOn: $doubleClickSeekEnabled)
                HStack {
                    Text("Clip buffer length")
                    Spacer()
                    TextField("", value: $clipBufferSeconds, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $clipBufferSeconds, in: 10...600, step: 10)
                        .labelsHidden()
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Miniplayer")
            } footer: {
                Text("Video cache: when on, the miniplayer plays the original video alongside audio (useful for visually identifying speakers). When off, only audio is fetched and cached — saves bandwidth and disk space on long videos. Local file transcriptions are unaffected; the miniplayer plays the original file directly. Takes effect on the next transcription Start.\n\nDouble-click to seek: when on, double-clicking a sentence in the transcript jumps miniplayer playback to that spot. Turn off if it conflicts with your text-selection habits.\n\nClip buffer length: how far back the miniplayer's Clip button reaches by default. Clicking Clip saves this many trailing seconds; holding the menu open still offers other lengths for one-off clips.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Clean up transcript on completion", isOn: $cleanupEnabled)
                Toggle("Convert spelled-out numbers to numerals", isOn: $cleanupNumerals)
                HStack {
                    Text("Cleanup model")
                    Spacer()
                    TextField("mlx-community/…", text: $cleanupModelRepo)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 320)
                        .disabled(cleanupFastMode)
                }

                Divider()

                Toggle("Fast mode (small dedicated cleanup model)", isOn: $cleanupFastMode)
                HStack {
                    Text("Fast cleanup model")
                    Spacer()
                    TextField("e.g. superwhisper/s1-mini-4bit", text: $cleanupFastModelRepo)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 320)
                        .disabled(!cleanupFastMode)
                }
                Text("Fast mode runs a small model (~0.6B) one segment at a time instead of the 4B model in batches. Much quicker, but it cannot use your Custom Dictionary and known speaker names as spelling hints, and it cannot flag passages as too disfluent to repair — so proper nouns are the thing to check first if accuracy drops. Length validation and verbatim preservation still apply, and Restore Verbatim Text still undoes any change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Transcript Cleanup")
            } footer: {
                Text("When enabled, runs automatically after each session; the transcript pane also has a Clean Up button for running it manually on demand (recommended for long transcripts — review first, then decide). A local LLM fixes punctuation and capitalization, removes filler words and false starts, and corrects obvious mis-transcriptions (your Custom Dictionary terms are provided as known spellings). It is instructed never to paraphrase, every change is length-validated, and the verbatim text is always preserved — any segment the model mishandles keeps its original text. The model (default Qwen3-4B-Instruct, ~2.3GB) downloads on first use and can be swapped for any mlx-community chat model by editing the repo above. After each pass, a before/after report of every change is written to Application Support → StreamScribe → Reports (path printed in the log) for review. Numeral conversion (e.g. \u{201C}sixty six\u{201D} → 66) is optional and off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Use document renderer (beta)", isOn: $useDocumentRenderer)
            } header: {
                Text("Transcript")
            } footer: {
                Text("The document renderer (default) shows the transcript as one selectable document: cross-speaker selection, ⌘F find, Copy with Attribution, Export Clip of Selection, precise double-click seek, header-click seek, and identify/pin context menus. Turn off to use the classic block renderer — currently still the only home of machine-label speaker reassignment. Takes effect immediately.")
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

            // Custom Dictionary section. Extracted into its own
            // computed property `customDictionarySection` to keep the
            // body's expression tree small enough for SwiftUI's type
            // checker to evaluate in reasonable time. The body had
            // grown to ~7 sections and 4 alert modifiers; the
            // Dictionary section alone is ~90 lines with bindings,
            // nested HStacks, and conditional rendering, which tipped
            // the inference over.
            customDictionarySection

            // Voiceprints section. Manages voice template loading
            // from R2, displays the active template list, and exposes
            // identification thresholds + master enable toggle.
            // Extracted as a computed property for the same type-checker
            // reasons as the Custom Dictionary section.
            voiceprintsSection

            // Advanced section. Surfaces opt-in toggles for power-
            // user / diagnostic tools and feature flags. Currently the
            // Debug menu visibility and Parakeet PnC restoration —
            // grouped together because both are "expert" flips users
            // shouldn't need to find but should be able to. Placed
            // near the bottom of Settings (just above Updates) so the
            // routine knobs above it (engine, dictionary, voiceprints)
            // are what users see first.
            Section {
                Toggle("Show Debug menu", isOn: $debugMenuEnabled)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Restore punctuation and capitalization (Parakeet)", isOn: $parakeetPnCRestoration)
                    // Inline availability indicator. When the toggle is on
                    // but the Foundation Model isn't available, show the
                    // reason in red — turning the toggle on without this
                    // feedback used to be a silent no-op (raw output with
                    // no indication why). When available or when the
                    // toggle is off, hide this row to keep the section
                    // visually clean.
                    if parakeetPnCRestoration, let reason = pncAvailabilityReason {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, 22)  // align under toggle label
                    }
                }
                Toggle("Show all models in pickers", isOn: $showAllModels)
            } header: {
                Text("Advanced")
            } footer: {
                Text("""
                    Show Debug menu adds a Debug menu to the menu bar with diagnostic toggles \
                    (Force R2 Mirror, Force Retry Probe Button, etc.). Useful when troubleshooting \
                    network or model-loading issues. Off by default.

                    Restore punctuation runs Parakeet output through Apple's on-device Foundation \
                    Model (macOS 26+, requires Apple Intelligence enabled) to add capitalization \
                    and punctuation. On by default because the current recommended Parakeet model \
                    (TDT 0.6B v3) doesn't produce PnC natively. Adds ~50-200 ms per segment of \
                    latency. Whisper is unaffected — it already has PnC. Turn off for raw \
                    Parakeet output.

                    Show all models reveals the full list of Whisper and Parakeet variants in the \
                    sidebar's model pickers. By default the pickers show a curated set (Whisper \
                    Medium / Large v3 Turbo / Large v3 Turbo 4-bit, Parakeet TDT 0.6B v3 / TDT-CTC \
                    1.1B); turn this on to access smaller variants, older versions, or alternative \
                    architectures.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Updates section. Surfaces the GitHub-Releases-backed
            // update checker. The automatic check fires once per launch
            // (24h throttled) — this button is the manual escape hatch
            // for users who want to check right now.
            Section {
                Button {
                    Task { await updateChecker.checkNow() }
                } label: {
                    HStack {
                        Text("Check for Updates Now")
                        if updateChecker.isChecking {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(updateChecker.isChecking)

                HStack {
                    Text("Current version")
                    Spacer()
                    Text(updateChecker.currentVersion)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if let err = updateChecker.lastCheckError {
                    Text("Last check failed: \(err)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("StreamScribe checks GitHub Releases once per day at launch. When an update is available, you'll see a dialog with a link to the release page. Use the button above to check immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 600)
        .onAppear { refreshPnCAvailability() }
        .onChange(of: parakeetPnCRestoration) { _, _ in refreshPnCAvailability() }
        // Import: stage 1 — file picker errored or schema didn't decode.
        .alert(
            "Import Failed",
            isPresented: Binding(
                get: { importErrorMessage != nil },
                set: { if !$0 { importErrorMessage = nil } }
            ),
            presenting: importErrorMessage
        ) { _ in
            Button("OK", role: .cancel) { importErrorMessage = nil }
        } message: { msg in
            Text(msg)
        }
        // Import: stage 2 — file decoded successfully, ask user how to
        // combine with the current dictionary. We don't auto-replace
        // because users often have local entries they don't want to
        // lose when importing a shared dictionary from a colleague.
        .alert(
            "Import Dictionary",
            isPresented: Binding(
                get: { pendingImportData != nil },
                set: { if !$0 { pendingImportData = nil } }
            )
        ) {
            Button("Replace") {
                applyPendingImport(mode: .replace)
            }
            Button("Merge") {
                applyPendingImport(mode: .merge)
            }
            Button("Cancel", role: .cancel) {
                pendingImportData = nil
            }
        } message: {
            Text("Replace existing entries, or merge (adds non-duplicates only)?")
        }
        // Post-import confirmation.
        .alert(
            "Dictionary Imported",
            isPresented: Binding(
                get: { importedEntryCount != nil },
                set: { if !$0 { importedEntryCount = nil } }
            ),
            presenting: importedEntryCount
        ) { _ in
            Button("OK", role: .cancel) { importedEntryCount = nil }
        } message: { n in
            Text("Loaded \(n) entries.")
        }
        // Post-reapply confirmation.
        .alert(
            "Re-apply Complete",
            isPresented: Binding(
                get: { reapplyCompletionMessage != nil },
                set: { if !$0 { reapplyCompletionMessage = nil } }
            ),
            presenting: reapplyCompletionMessage
        ) { _ in
            Button("OK", role: .cancel) { reapplyCompletionMessage = nil }
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - Voiceprints section

    /// Settings UI for the voiceprint identification system. Three
    /// areas: master enable toggle, threshold sliders (high/low), and
    /// template list with R2 refresh. Mirrors the Custom Dictionary
    /// section's visual layout for consistency.
    private var voiceprintsSection: some View {
        Section {
            voiceprintsHeaderRow
            voiceprintsThresholdsView
            voiceprintsTemplatesList
        } header: {
            Text("Speaker Identification")
        } footer: {
            Text("Identifies speakers by matching their voice against a database of templates hosted on R2. Templates are downloaded once and cached locally. Manual reassignments via the transcript's right-click menu take priority over automatic identification.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Master enable toggle + R2 refresh button + last-refreshed
    /// timestamp. Disabling the toggle skips identification entirely
    /// without clearing the registry — useful for A/B comparisons.
    private var voiceprintsHeaderRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enable speaker identification", isOn: $voiceprints.isEnabled)
                .font(.callout)

            HStack(spacing: 8) {
                Button("Refresh from R2") {
                    Task { await voiceprints.refreshFromRemote() }
                }
                .controlSize(.small)
                .disabled(loadStateIsLoading)

                if let lastRefresh = voiceprints.lastRefreshedAt {
                    Text("Last refreshed: \(relativeTimeString(from: lastRefresh))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                voiceprintsLoadStateLabel
            }
        }
    }

    /// Status text for the current load state. Surfaces R2 errors so
    /// the user knows when templates failed to refresh and they're
    /// running on a stale cache.
    @ViewBuilder
    private var voiceprintsLoadStateLabel: some View {
        switch voiceprints.loadState {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .loaded(let count):
            Text("\(count) loaded")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .error(let msg):
            Text("Error: \(msg)")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// Helper for disabling the refresh button mid-load.
    private var loadStateIsLoading: Bool {
        if case .loading = voiceprints.loadState { return true }
        return false
    }

    /// High and low confidence thresholds via sliders. Range 0.30–
    /// 0.95 — outside that bracket the matcher is either accepting
    /// noise (very low threshold) or rejecting valid matches (very
    /// high). The default 0.50 / 0.75 split is a reasonable starting
    /// point; the user can tune after observing real session
    /// behavior.
    private var voiceprintsThresholdsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("High confidence threshold")
                    .font(.callout)
                Spacer()
                Text(String(format: "%.2f", voiceprints.highConfidenceThreshold))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: $voiceprints.highConfidenceThreshold,
                in: 0.30...0.95,
                step: 0.05
            )

            HStack {
                Text("Low confidence threshold")
                    .font(.callout)
                Spacer()
                Text(String(format: "%.2f", voiceprints.lowConfidenceThreshold))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: $voiceprints.lowConfidenceThreshold,
                in: 0.30...0.95,
                step: 0.05
            )

            Text("Matches above the high threshold are applied directly. Between low and high, names render in italics. Below the low threshold, generic \"Speaker N\" labels are used.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(.top, 4)
    }

    /// List of loaded voice templates. Read-only display — adding /
    /// removing templates is done via the SpeakerEnroll CLI and R2
    /// upload, not through the app. Tap a template to see source
    /// clip info via tooltip. Empty-state message when no templates
    /// have loaded yet.
    @ViewBuilder
    private var voiceprintsTemplatesList: some View {
        if voiceprints.templates.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No templates loaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Upload voiceprints.json to R2 and click Refresh, or check the URLs in the Source URLs field below.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                // Summary line — preserved from the previous UI so
                // total count is still glanceable. Sits above the
                // per-category disclosures so users see the big
                // number before opening any section.
                Text("\(voiceprints.templates.count) templates loaded across \(displayGroupsCount) source(s)")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if voiceprints.categorizedTemplates.isEmpty {
                    // Fallback: only cache-loaded (or refresh hasn't
                    // completed). Render as one flat disclosure so
                    // the list is still browsable during that
                    // interim state.
                    DisclosureGroup("All (\(voiceprints.templates.count))") {
                        templateRows(voiceprints.templates)
                    }
                    .font(.callout)
                } else {
                    // Normal path: one collapsible section per
                    // source category, in the order the URLs are
                    // defined. Each labeled "Category (count)".
                    ForEach(voiceprints.categorizedTemplates) { group in
                        DisclosureGroup("\(group.name) (\(group.templates.count))") {
                            templateRows(group.templates)
                        }
                        .font(.callout)
                    }
                }
            }
        }

        // Source URLs editor — now collapsible via its own
        // DisclosureGroup. Users rarely need to change the URL list
        // after initial setup, so defaulting it collapsed keeps the
        // Voiceprints section visually compact. When expanded, the
        // same TextEditor / help text pair as before.
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $voiceprints.r2URLsRaw)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 66, maxHeight: 132)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                    )
                    .cornerRadius(4)
                Text("One URL per line. Files are fetched in order and merged into one template pool. A single URL still works — just enter one line.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        } label: {
            Text("Source URLs")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    /// Count for the summary line. Prefer the categorized group
    /// count when available; fall back to 1 (representing the
    /// implicit "All" group) when only cache is loaded.
    private var displayGroupsCount: Int {
        voiceprints.categorizedTemplates.isEmpty ? 1 : voiceprints.categorizedTemplates.count
    }

    /// Shared row renderer for template lists. Used by both the
    /// per-category disclosures and the flat-list fallback so
    /// styling stays consistent across both paths.
    @ViewBuilder
    private func templateRows(_ list: [VoiceprintService.Voiceprint]) -> some View {
        ForEach(list) { template in
            HStack {
                Text(template.name)
                    .font(.system(size: 11))
                Spacer()
                if let model = template.embeddingModel {
                    Text(model)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .help("Embedding model: \(template.embeddingModel ?? "unknown"). Source clips: \(template.nClips ?? 1).")
        }
    }

    /// Format a timestamp as "5 minutes ago" / "2 hours ago" /
    /// "yesterday". Avoids needing date formatter overhead inside
    /// the view body.
    private func relativeTimeString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Custom Dictionary section
    //
    // Extracted from `body` to keep that property's expression tree
    // small enough for SwiftUI's type checker. Order of subviews
    // matches the original inline implementation; behavior is
    // identical. See the call site in `body` for the rationale.

    private var customDictionarySection: some View {
        Section {
            dictionaryEntriesView
            newEntryRow
            bulkActionsRow
        } header: {
            Text("Custom Dictionary")
        } footer: {
            Text("Rewrites transcribed text on the fly — e.g. \"Jamie Diamond\" → \"Jamie Dimon\". Matching is case-insensitive and word-bounded (\"Diamond\" doesn't match inside \"diamondback\"). Applied automatically to new segments as they're transcribed. Use Re-apply to update segments produced before you added a rule.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// List of existing entries OR an empty-state placeholder. Each row
    /// binds directly to the @Published array element so edits flow
    /// through the dictionary's didSet → save-to-defaults pipeline
    /// without any explicit save action.
    @ViewBuilder
    private var dictionaryEntriesView: some View {
        if customDictionary.entries.isEmpty {
            Text("No entries yet. Add a find/replace rule below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            ForEach($customDictionary.entries) { $entry in
                dictionaryRow(entry: $entry)
            }
        }
    }

    /// Single editable row for an existing entry: find field, arrow,
    /// replace field, delete button. Extracted as its own function so
    /// the ForEach in `dictionaryEntriesView` stays a single
    /// expression (helps the type checker).
    private func dictionaryRow(entry: Binding<CustomDictionary.Entry>) -> some View {
        HStack(spacing: 8) {
            TextField("Find", text: entry.find)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
                .font(.caption)
            TextField("Replace", text: entry.replace)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            Button {
                customDictionary.remove(id: entry.wrappedValue.id)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove this entry")
        }
    }

    /// Inline "+" new-entry row at the bottom of the entries list.
    /// Submitting either field (Return key) adds the entry — parity
    /// with how most macOS list editors work. Empty either-side
    /// blocks the add via the `disabled` modifier on the button.
    private var newEntryRow: some View {
        HStack(spacing: 8) {
            TextField("Add: find", text: $newEntryFind)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit(addNewEntry)
            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
                .font(.caption)
            TextField("Replace with", text: $newEntryReplace)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit(addNewEntry)
            Button {
                addNewEntry()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(newEntryFind.isEmpty || newEntryReplace.isEmpty)
            .help("Add this entry")
        }
        .padding(.top, 4)
    }

    /// Import / Export / Re-apply buttons. Sits below the editable
    /// rows in the section. Disabled-states reflect what's actionable:
    /// Export needs entries to write, Re-apply needs both entries and
    /// current-session segments.
    private var bulkActionsRow: some View {
        HStack(spacing: 8) {
            Button("Import…") {
                importDictionary()
            }
            .controlSize(.small)

            Button("Export…") {
                exportDictionary()
            }
            .controlSize(.small)
            .disabled(customDictionary.entries.isEmpty)

            Spacer()

            Button("Re-apply to Current Transcript") {
                guard let engine else { return }
                let before = engine.segments.count
                engine.reapplyCustomDictionary()
                reapplyCompletionMessage = "Re-applied dictionary to \(before) segment(s)."
            }
            .controlSize(.small)
            .disabled((engine?.segments.isEmpty ?? true) || customDictionary.entries.isEmpty)
        }
        .padding(.top, 6)
    }

    /// Add the in-progress entry row to the dictionary. Trims whitespace
    /// on both sides — leading/trailing spaces in find patterns would
    /// break the word-boundary regex match anyway, and a literal space
    /// in the middle is preserved by trimmingCharacters(in: .whitespaces).
    /// Clears the input fields on success so the row is ready for the
    /// next entry.
    private func addNewEntry() {
        let find = newEntryFind.trimmingCharacters(in: .whitespacesAndNewlines)
        let replace = newEntryReplace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !find.isEmpty, !replace.isEmpty else { return }
        customDictionary.add(find: find, replace: replace)
        newEntryFind = ""
        newEntryReplace = ""
    }

    /// Export the current dictionary to a JSON file the user picks via
    /// NSSavePanel. Default filename is "StreamScribe Dictionary.json"
    /// for easy identification in Downloads/Documents folders. The
    /// JSON is pretty-printed and key-sorted so a user checking it
    /// into a team repo gets diff-friendly output.
    private func exportDictionary() {
        do {
            let data = try customDictionary.exportToData()
            let panel = NSSavePanel()
            panel.title = "Export Dictionary"
            panel.nameFieldStringValue = "StreamScribe Dictionary.json"
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.begin { response in
                if response == .OK, let url = panel.url {
                    do {
                        try data.write(to: url)
                    } catch {
                        DispatchQueue.main.async {
                            importErrorMessage = "Couldn't write file: \(error.localizedDescription)"
                        }
                    }
                }
            }
        } catch {
            importErrorMessage = "Couldn't encode dictionary: \(error.localizedDescription)"
        }
    }

    /// Import flow: file picker → decode → ask Replace/Merge → apply.
    /// Split across two alerts because the decode step might fail and
    /// the merge decision shouldn't be asked until we have valid data
    /// to apply.
    private func importDictionary() {
        let panel = NSOpenPanel()
        panel.title = "Import Dictionary"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                // Validate the schema by attempting a decode here. If
                // the file isn't ours (or is corrupted), we surface the
                // error now rather than after the user picks Replace/
                // Merge and gets surprised.
                _ = try JSONDecoder().decode(CustomDictionary.ExportPayload.self, from: data)
                DispatchQueue.main.async {
                    pendingImportData = data
                }
            } catch {
                DispatchQueue.main.async {
                    importErrorMessage = "Couldn't read dictionary file. It may not be a valid StreamScribe export: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Stage 2 of import: user picked Replace or Merge. Apply the
    /// staged data and surface the confirmation count.
    private func applyPendingImport(mode: CustomDictionary.ImportMode) {
        guard let data = pendingImportData else { return }
        pendingImportData = nil
        do {
            let count = try customDictionary.importFromData(data, mode: mode)
            importedEntryCount = count
        } catch {
            importErrorMessage = "Import failed during apply: \(error.localizedDescription)"
        }
    }

    /// Read the current Foundation Model availability and update
    /// `pncAvailabilityReason`. Nil means available (or feature not gated);
    /// non-nil means show the inline warning under the toggle with that
    /// reason.
    ///
    /// Called on view appear (so users opening Settings get fresh status)
    /// and on toggle flip (so users enabling Apple Intelligence in System
    /// Settings, then coming back and tapping the toggle, see updated
    /// status immediately without restarting the app).
    private func refreshPnCAvailability() {
        switch PnCRestorer.shared.availability {
        case .available:
            pncAvailabilityReason = nil
        case .unavailable(let reason):
            pncAvailabilityReason = reason
        }
    }
}

#Preview {
    SettingsView()
}
