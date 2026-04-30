import Foundation
import SwiftUI
import Combine
import AVFoundation

/// The brain of the app: takes a URL, pulls audio, transcribes it, and assigns speakers.
///
/// New architecture (with swappable engines):
///
///   AudioStreamExtractor (ffmpeg)
///        │  Float32 PCM @ 16kHz
///        ▼
///   Ring buffer + chunker  ──►  TranscriptionBackend  (WhisperKit or Parakeet)
///        │                      DiarizationBackend    (SpeakerKit, Sortformer, or off)
///        ▼
///   merge by time overlap  ──►  @Published segments  ──►  SwiftUI
///
/// Engine choices are exposed as @Published properties; switching them between sessions
/// rebuilds the backend on next start. This makes A/B comparison straightforward — pick an
/// engine combo, run a stream, export, switch combo, run the same stream, compare.
///
/// IMPLEMENTATION NOTE — `@Published` and `objectWillChange`:
/// We rely on compiler-synthesized `ObservableObject` conformance. Earlier versions of this
/// file declared `objectWillChange` explicitly to work around a build-time conformance error,
/// but that *broke* @Published-driven UI updates at runtime: the synthesis mechanism that
/// makes @Published trigger objectWillChange.send() requires the synthesized
/// ObservableObjectPublisher, not a hand-rolled one. By removing the explicit declaration
/// AND keeping @MainActor off the class itself (we apply it per-method instead), conformance
/// synthesizes cleanly and @Published updates flow to the UI as expected.
/// Phase 7 telemetry: rolling latency stats for the refinement pipeline.
/// The engine publishes one of these as `refinementStats` and updates it
/// after every refinement pass (success or fail). Read by:
///   - The adaptive-cadence logic, which inspects p95 latency over a
///     rolling window to decide whether to slow down or recover.
///   - The Debug "Show Stats" menu (⌘⇧S), which logs a snapshot.
///
/// Memory bound: `latencies` is capped at `Self.windowSize` (10) — older
/// entries drop off the front as new ones arrive. Negligible footprint.
struct RefinementStats: Equatable {
    /// Number of refinement passes that completed successfully this session.
    var windowsRefined: Int = 0

    /// Number of windows the scheduler dropped because the previous pass
    /// was still running (buffer trimmed past one cadence without firing
    /// new inference). A nonzero value means refinement isn't keeping up.
    var windowsDropped: Int = 0

    /// Number of refinement passes that hit an error path and reverted to
    /// raw. Distinct from `windowsDropped` (those never started); these
    /// did start but failed (e.g. backend threw, audio buffer too short).
    var windowsFailed: Int = 0

    /// Per-pass durations (seconds), most recent last. Capped at
    /// `windowSize`; older entries fall off the front.
    var latencies: [TimeInterval] = []

    /// Rolling window size for p50/p95 calculations and adaptive cadence
    /// decisions. 10 windows = roughly the last 5 minutes at the default
    /// 30s cadence — enough signal to detect a sustained slowdown without
    /// being so long that recovery takes ages.
    static let windowSize: Int = 10

    /// Median latency over the rolling window. Returns 0 when empty so the
    /// adaptive-cadence comparison ("p95 > cadence") trivially passes at
    /// session start before any data exists.
    var p50: TimeInterval {
        guard !latencies.isEmpty else { return 0 }
        let sorted = latencies.sorted()
        return sorted[sorted.count / 2]
    }

    /// p95 latency over the rolling window. With windowSize=10 this is the
    /// 9th-percentile element (effectively the worst-case excluding a
    /// single outlier). Returns 0 when empty.
    var p95: TimeInterval {
        guard !latencies.isEmpty else { return 0 }
        let sorted = latencies.sorted()
        // `Int(Double(count) * 0.95)` clamped to last valid index — for
        // count=10 that's index 9; for count=1 it's index 0.
        let idx = min(sorted.count - 1, Int(Double(sorted.count) * 0.95))
        return sorted[idx]
    }

    /// Append a new latency. Trims to `windowSize` from the front so the
    /// vector stays bounded. Caller increments the relevant counter
    /// separately — this method only touches the timing series.
    mutating func record(latency: TimeInterval) {
        latencies.append(latency)
        if latencies.count > Self.windowSize {
            latencies.removeFirst(latencies.count - Self.windowSize)
        }
    }
}

final class TranscriptionEngine: ObservableObject {

    // MARK: - Engine choices (user-facing)

    /// The transcription engine for the raw pass — in multi-pass live, the
    /// low-latency pipeline that drives the 5s display chunks. In single-pass
    /// live and static, this IS the only engine. Named `transcriptionEngine`
    /// (not `rawTranscriptionEngine`) for backwards compatibility with the
    /// existing sidebar picker, which has always been "the engine."
    ///
    /// When multi-pass refinement is on AND `useSplitRefinedEngine` is true,
    /// the refined pass uses `refinedTranscriptionEngine` instead. Otherwise
    /// both passes use this property (the Phase 3 "option β" default).
    @Published var transcriptionEngine: TranscriptionEngineKind = .whisperKit
    @Published var diarizationEngine: DiarizationEngineKind = .speakerKit

    /// Opt-in toggle for using a different engine on the refined pass than the
    /// raw pass. Only meaningful when `refinementEnabled` is true. Default
    /// `false` preserves the "same engine both slots" behavior the engine has
    /// always shipped with.
    ///
    /// The canonical use case is Parakeet-raw + Whisper-refined: Parakeet for
    /// low-latency display because it's a streaming ASR with sub-realtime
    /// inference; Whisper-large-v3-turbo for the refined cleanup because it's
    /// trained on 30s clips and that's where its accuracy peaks. The handoff
    /// doc §13 explicitly endorsed this as the right way to enable Parakeet
    /// in live mode: an opt-in setting, not a forced default.
    ///
    /// `MULTI_PASS_DESIGN.md §3.5` originally specced four properties (raw
    /// engine + refined engine + raw model + refined model). We collapsed it
    /// to two: the model-name and language properties are already keyed by
    /// engine kind (`whisperModelName`, `parakeetModelName`,
    /// `selectedLanguageCode`), so they're shared regardless of which slot
    /// the engine is in. Simpler state, same expressiveness.
    @Published var useSplitRefinedEngine: Bool = false

    /// The transcription engine for the refined pass when
    /// `useSplitRefinedEngine && refinementEnabled` is true. Otherwise unused —
    /// `rebuildBackends` reads `transcriptionEngine` for both slots.
    ///
    /// Defaults to `.whisperKit` because the dominant motivating use case for
    /// the split (Parakeet-raw) wants Whisper on the refined side.
    @Published var refinedTranscriptionEngine: TranscriptionEngineKind = .whisperKit

    /// Live-mode post-finish re-diarization toggle. When `true` AND the session
    /// is live AND a diarizer is enabled, the engine accumulates the entire
    /// audio stream into `fullPcmBuffer` (same buffer static-mode uses) and,
    /// after transcription completes (user stop, stream end, or other natural
    /// termination), runs one final whole-file diarization pass with a
    /// fresh `SpeakerKitBackend`. The resulting turns replace `allSpeakerTurns`
    /// and every segment in `segments` gets re-attributed to the new labels.
    ///
    /// Rationale: Sortformer (the streaming MLX diarizer that pairs with
    /// Parakeet) is fast and low-latency but its speaker IDs are derived
    /// chunk-by-chunk, so identity can drift or fragment across long
    /// sessions. SpeakerKit's whole-file pyannote clustering produces more
    /// stable, globally-consistent speaker labels at the cost of needing
    /// the whole audio at once — which is fine at the end of the session.
    ///
    /// This is always SpeakerKit on the finalization pass regardless of the
    /// live diarizer choice; the whole point is to use the more accurate
    /// whole-file algorithm as a cleanup step.
    ///
    /// Memory cost: 64 KB/s of audio retained for the entire session
    /// (16 kHz mono Float32). ~230 MB/hour. For multi-hour livestreams the
    /// user should weigh the accuracy gain against the RSS footprint. The
    /// default is false so opting in is explicit.
    ///
    /// No-op in static mode (whole-file SpeakerKit already runs there) and
    /// when `diarizationEngine == .off` (nothing to re-diarize). The UI
    /// disables the toggle in those configurations rather than letting the
    /// flag silently do nothing.
    @Published var postFinishRediarizeEnabled: Bool = false

    /// Multi-pass live-mode toggle. When `true` AND `resolvedSessionMode == .live`,
    /// the engine will eventually run a small-chunk raw pass alongside a 30s
    /// rolling refined pass (see `MULTI_PASS_DESIGN.md`). When `false`, live mode
    /// is the single-pass behavior the app has always had.
    ///
    /// Defined here in Phase 1 so:
    ///   - the segment-lifecycle stamping in `appendTranscribedSegments` has a
    ///     stable flag to gate on,
    ///   - existing live-mode users see zero behavior change until they opt in,
    ///   - and Phase 4 (refinement scheduler) has a place to hang the actual
    ///     parallel-pipeline logic without adding more @Published state then.
    ///
    /// Captured at session start into `useMultiPassLive` so the user can toggle
    /// the UI control mid-session without disturbing an in-flight pipeline.
    @Published var refinementEnabled: Bool = false

    /// Length of each refinement window in seconds. The refined pass runs
    /// transcription + diarization over a buffer of this duration. Default
    /// 30s per design §3.5 — Whisper's native training window, so this is the
    /// "no out-of-distribution accuracy loss" sweet spot. The published field
    /// is in place so Phase 6 can expose a slider; Phase 4 only reads from it.
    @Published var refineWindowSeconds: Double = 30.0

    /// How often a refinement window fires, in seconds of accumulated audio.
    /// Default 30s matches `refineWindowSeconds` so windows are non-overlapping
    /// (design §3.3: "conservative; we may revisit to use overlapping
    /// refinement [...] if accuracy at chunk boundaries is poor"). A cadence
    /// shorter than the window produces overlapping windows; we don't support
    /// that yet — each refinement consumes its cadence-worth of new audio off
    /// the front of the refine buffer, and `replaceSegments` would clobber
    /// already-refined segments if windows overlapped. Phase 4 only honors
    /// `cadence >= window`; smaller values get clamped.
    @Published var refineCadenceSeconds: Double = 30.0

    /// Mirror of `TranscriptPaneView`'s `autoScroll` — true when the user is
    /// at the bottom of the transcript and watching new content arrive, false
    /// when they've navigated away (clicked a pin, scrolled up manually). The
    /// view writes this on its own state changes; the engine reads it in
    /// `replaceSegments` to decide whether to animate the cross-fade (design
    /// §5.2 "no animation runs — they're not looking at it").
    ///
    /// This is a small layering compromise — the engine isn't supposed to
    /// know about UI state — but the alternative (passing `withAnimation`
    /// instructions across the engine→view boundary on every refinement) was
    /// worse. Treat this as a hint, not a contract; if the view ever stops
    /// writing it, the default `true` keeps animations running, which is the
    /// safe failure mode.
    @Published var userIsFollowingTranscript: Bool = true

    /// Phase 7 telemetry: rolling stats for the refinement pipeline. Updated
    /// after every `performRefinementPass` (success or fail), read by the
    /// adaptive-cadence logic and by the Debug "Show Stats" menu. Default
    /// is empty — sessions without refinement never write to it.
    @Published var refinementStats: RefinementStats = RefinementStats()

    /// Active cadence — what the scheduler currently uses to time its
    /// windows. Distinct from `refineCadenceSeconds` (the user's nominal
    /// setting from the sidebar slider): the auto-adjust logic in Phase 7
    /// can temporarily increase this above the nominal when refinement is
    /// running consistently slow, and decay it back down when speed
    /// recovers. The nominal value is the floor.
    ///
    /// Reset to `refineCadenceSeconds` at each `start()`.
    @Published private(set) var activeRefineCadence: Double = 30.0

    /// User-selected session mode. `.auto` (default) preserves the original
    /// heuristic — bounded duration → static, otherwise live. Explicit `.live`
    /// or `.static` overrides that heuristic. The choice is read once at
    /// `start()` and held for the session; changing this property mid-pipeline
    /// has no effect (we disable the picker in the UI while a session is
    /// active to avoid the appearance otherwise).
    @Published var sessionMode: SessionMode = .auto

    /// What `.auto` would resolve to right now, given the currently-known
    /// source state. Updated as URL detection runs. Drives the sidebar picker's
    /// "Auto (Static)" / "Auto (Live)" subtitle so the user sees what's about
    /// to happen without having to commit to an explicit override.
    @Published private(set) var resolvedSessionMode: SessionMode = .live

    /// Selected model name per engine. We keep separate selections so switching engines
    /// preserves what the user picked for each.
    @Published var whisperModelName: String = TranscriptionEngine.defaultWhisperModel
    @Published var parakeetModelName: String = TranscriptionEngine.defaultParakeetModel

    // MARK: - Available models (driven from UI)

    static let availableWhisperModels: [String] = [
        "openai_whisper-tiny.en",
        "openai_whisper-base.en",
        "openai_whisper-small.en",
        "openai_whisper-medium.en",
        "openai_whisper-large-v3",
        "openai_whisper-large-v3-v20240930",
        "openai_whisper-large-v3-v20240930_turbo",
        "openai_whisper-large-v3-v20240930_turbo_632MB",
    ]
    static let defaultWhisperModel = "openai_whisper-large-v3-v20240930_turbo_632MB"

    /// Parakeet variants on HuggingFace's mlx-community. TDT (token-and-duration) variants
    /// are usually the best speed/accuracy point; CTC is simpler/faster; RNN-T is the
    /// classic trade-off. Sizes are 0.6B (~600MB-1GB) and 1.1B (~1-2GB) parameters.
    static let availableParakeetModels: [String] = [
        "mlx-community/parakeet-tdt-0.6b-v3",
        "mlx-community/parakeet-tdt-0.6b-v2",
        "mlx-community/parakeet-tdt-1.1b",
        "mlx-community/parakeet-tdt_ctc-1.1b",
        "mlx-community/parakeet-tdt_ctc-110m",
        "mlx-community/parakeet-ctc-0.6b",
        "mlx-community/parakeet-ctc-1.1b",
        "mlx-community/parakeet-rnnt-0.6b",
        "mlx-community/parakeet-rnnt-1.1b",
    ]
    static let defaultParakeetModel = "mlx-community/parakeet-tdt-0.6b-v3"

    /// Common languages Whisper handles well. The first option is "Auto-detect" (nil).
    /// "en" forces English, which avoids unreliable per-chunk language detection on
    /// short audio windows — see WhisperKitBackend for why this matters.
    /// Add more codes here as needed; Whisper supports 99 languages but this list keeps
    /// the picker tractable.
    static let availableLanguages: [(code: String?, name: String)] = [
        (nil,   "Auto-detect"),
        ("en",  "English"),
        ("es",  "Spanish"),
        ("fr",  "French"),
        ("de",  "German"),
        ("it",  "Italian"),
        ("pt",  "Portuguese"),
        ("nl",  "Dutch"),
        ("pl",  "Polish"),
        ("ru",  "Russian"),
        ("ja",  "Japanese"),
        ("ko",  "Korean"),
        ("zh",  "Chinese"),
        ("ar",  "Arabic"),
        ("hi",  "Hindi"),
        ("tr",  "Turkish"),
        ("vi",  "Vietnamese"),
        ("uk",  "Ukrainian"),
        ("sv",  "Swedish"),
        ("da",  "Danish"),
        ("no",  "Norwegian"),
        ("fi",  "Finnish"),
        ("cs",  "Czech"),
        ("ro",  "Romanian"),
        ("el",  "Greek"),
        ("he",  "Hebrew"),
        ("th",  "Thai"),
        ("id",  "Indonesian"),
    ]
    static let defaultLanguageCode: String? = "en"

    // MARK: - Published UI state

    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var state: EngineState = .idle

    /// True from the moment the user clicks Stop until the state machine
    /// actually reaches `.idle`. Used by the sidebar to render "Stopping…"
    /// on the primary button so the user gets immediate visual feedback
    /// even when the underlying state path takes a while (graceful multi-
    /// pass teardown can take up to 15s waiting for in-flight refinement;
    /// instant stop is usually <1s but a running chunk inference still has
    /// to finish because actor methods don't honor Task.isCancelled mid-
    /// CoreML/MLX call).
    ///
    /// Distinct from `state.isFinalizing` which only covers the graceful
    /// multi-pass path. This flag also turns true for instant-stop sessions
    /// so the UX is consistent across modes.
    @Published private(set) var isStopping: Bool = false

    @Published private(set) var detectedSource: StreamSource = .unknown
    @Published var detectedLanguage: String?

    /// Title of the source being transcribed. Populated by `beginProbe`:
    ///   - yt-dlp sources: pulled from yt-dlp's `%(title)s` field at probe time
    ///     (e.g. video/podcast/Spaces titles).
    ///   - Local files: derived from the filename minus extension.
    ///   - HLS / direct audio / no probe yet: nil. We could shell out to
    ///     ffprobe for `format_tags.title` but most HLS manifests don't
    ///     carry it; not worth the latency.
    /// Cleared (set to nil) at the top of every `beginProbe` so a stale
    /// title from a prior URL never lingers on the new URL's display.
    @Published private(set) var detectedTitle: String?

    @Published private(set) var elapsedSeconds: TimeInterval = 0

    /// User-selected language. `nil` = auto-detect (less reliable on short chunks).
    /// Defaults to English which is what most users will want and which sidesteps a
    /// real bug where Whisper Turbo's auto-detection fails on padded short chunks.
    @Published var selectedLanguageCode: String? = TranscriptionEngine.defaultLanguageCode

    /// Average chunks-per-second processing speed. Useful when comparing engines.
    /// >1.0 = faster than realtime; <1.0 = falling behind.
    @Published private(set) var realtimeFactor: Double = 0

    /// User-provided display names keyed by machine label (e.g. "Speaker 1" → "Alice").
    /// Only populated when the user types into the speaker panel; absent entries fall
    /// back to the machine label at render time. We keep this separate from the segment
    /// data so the diarizer's output stays untouched and renaming is reversible.
    @Published var speakerNames: [String: String] = [:]

    /// User-pinned excerpts. Order = insertion order. Pins survive everything except
    /// hitting Start on a new source (which clears them like any other session state).
    @Published private(set) var pinnedQuotes: [PinnedQuote] = []

    // MARK: - Miniplayer / audio playback

    /// URL the miniplayer should play back. Two sources:
    ///   - **Local file transcriptions:** the original file path the user
    ///     imported. Set in `start()` immediately so the miniplayer is
    ///     usable mid-transcription too if the user opens it.
    ///   - **Live / URL transcriptions:** the .mkv file ffmpeg wrote to
    ///     disk as a side output during the transcription. Set when the
    ///     pipeline reaches the natural-end / cancellation branch and
    ///     `runPipeline` confirms the file exists.
    /// Cleared (set to nil) at the top of `start()` so the previous
    /// run's URL doesn't leak into the new session before the new
    /// pipeline completes.
    @Published private(set) var playbackMediaURL: URL?

    /// Pin a whole segment group as a single quote. Convenience for the right-click
    /// context menu in the transcript view. The combined text and timestamps are
    /// snapshotted at pin time.
    func pinGroup(_ group: SpeakerGroup) {
        let quote = PinnedQuote(
            text: group.combinedText,
            speaker: group.speaker,
            start: group.start,
            end: group.end,
            sourceSegmentID: group.segments.first?.id
        )
        // Avoid duplicate pins of the same content. Same source segment + same text =
        // already pinned; ignore the request.
        if pinnedQuotes.contains(where: {
            $0.sourceSegmentID == quote.sourceSegmentID && $0.text == quote.text
        }) {
            return
        }
        pinnedQuotes.append(quote)
    }

    func unpin(_ id: UUID) {
        pinnedQuotes.removeAll { $0.id == id }
    }

    func clearAllPins() {
        pinnedQuotes.removeAll()
    }

    // MARK: - Keyword auto-pin

    /// Substrings the user wants flagged. When a transcribed segment contains any of
    /// these (case-insensitively), it's auto-pinned. The list is user-editable from
    /// the sidebar and deliberately persists across Start/Stop cycles — it's a setting,
    /// not session state. Adding a new keyword mid-run triggers a retroactive scan
    /// of existing segments so the user doesn't lose pins for already-transcribed
    /// content.
    @Published var watchedKeywords: [String] = [] {
        didSet {
            // Hop to MainActor to safely read/write @Published state. SwiftUI
            // bindings already run on MainActor, so this Task is effectively
            // synchronous in the common case, but the hop keeps us correct if
            // anything ever mutates this property from a background queue.
            let old = oldValue
            Task { @MainActor [weak self] in
                self?.rescanForNewKeywords(oldKeywords: old)
            }
        }
    }

    /// When true, every keyword-driven auto-pin also fires a system notification.
    /// Off by default — notifications are opt-in.
    @Published var notifyOnKeywordHit: Bool = false

    /// Find the first watched keyword present in `text`. Case-insensitive substring
    /// match, returned in the user's original casing so it renders nicely on badges
    /// ("Putin" not "putin", regardless of segment text).
    func firstMatchingKeyword(in text: String) -> String? {
        guard !watchedKeywords.isEmpty else { return nil }
        let lower = text.lowercased()
        for kw in watchedKeywords {
            let trimmed = kw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if lower.contains(trimmed.lowercased()) {
                return trimmed
            }
        }
        return nil
    }

    /// If `segment.text` matches any watched keyword and the segment isn't already
    /// pinned, append a new auto-pin and (optionally) post a system notification.
    /// Called by the pipeline as new segments come in.
    @MainActor
    private func checkKeywordsAndAutoPin(segment: TranscriptSegment) {
        guard let keyword = firstMatchingKeyword(in: segment.text) else { return }

        // Don't double-pin if the user already manually pinned this segment, or if
        // a previous keyword check already auto-pinned it.
        if pinnedQuotes.contains(where: { $0.sourceSegmentID == segment.id }) {
            return
        }

        let quote = PinnedQuote(
            text: segment.text,
            speaker: segment.speaker,
            start: segment.start,
            end: segment.end,
            sourceSegmentID: segment.id,
            matchedKeyword: keyword
        )
        pinnedQuotes.append(quote)

        // Only notify when the user has opted in. We resolve the speaker's display
        // name (if any) so the notification reads naturally — falling back to the
        // machine label, which is also what the user sees in the transcript.
        if notifyOnKeywordHit {
            let speakerForNotification = displayName(for: segment.speaker)
            NotificationService.shared.postKeywordHit(
                keyword: keyword,
                snippet: segment.text,
                speaker: speakerForNotification
            )
        }
    }

    /// When the watched-keyword list grows, scan all existing segments and auto-pin
    /// matches that aren't yet pinned. Removing keywords does NOT unpin previous hits
    /// — those represent past matches and the user can manually unpin if desired.
    /// Called from the `watchedKeywords` didSet so changes apply retroactively.
    /// Annotated `@MainActor` because it reads/writes `@Published` state; SwiftUI
    /// bindings already run on MainActor so this is redundant in practice but makes
    /// the contract explicit and protects against future programmatic edits from
    /// background contexts.
    @MainActor
    private func rescanForNewKeywords(oldKeywords: [String]) {
        // Identify keywords that were just added (case-insensitive comparison so we
        // don't rescan when only casing differs).
        let oldSet = Set(oldKeywords.map { $0.lowercased() })
        let added = watchedKeywords.filter { !oldSet.contains($0.lowercased()) }
        guard !added.isEmpty, !segments.isEmpty else { return }

        // Scan segments using only the newly-added keywords. We can't use
        // firstMatchingKeyword(in:) directly because it scans the full watched list,
        // and we want to credit the new keyword (not an old one that matched too).
        let lowerAdded = added.map { $0.lowercased() }
        for seg in segments {
            // Skip if already pinned (manual or auto from a prior keyword).
            if pinnedQuotes.contains(where: { $0.sourceSegmentID == seg.id }) { continue }
            let lower = seg.text.lowercased()
            guard let hitIdx = lowerAdded.firstIndex(where: { lower.contains($0) }) else {
                continue
            }
            let keyword = added[hitIdx].trimmingCharacters(in: .whitespaces)
            let quote = PinnedQuote(
                text: seg.text,
                speaker: seg.speaker,
                start: seg.start,
                end: seg.end,
                sourceSegmentID: seg.id,
                matchedKeyword: keyword
            )
            pinnedQuotes.append(quote)
            // Note: we deliberately do NOT post notifications for retroactive matches.
            // The user just typed a keyword; they don't need 30 toasts about the past.
        }
    }

    /// All distinct machine labels in the current transcript, in order of first
    /// appearance. Drives the speaker-naming UI. Recomputed from `segments` so
    /// it stays in sync as new chunks come in.
    var distinctMachineSpeakers: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for seg in segments {
            guard let label = seg.speaker, !seen.contains(label) else { continue }
            seen.insert(label)
            ordered.append(label)
        }
        return ordered
    }

    /// Resolve a machine label to its display name, falling back to the machine label.
    func displayName(for machineLabel: String?) -> String? {
        guard let label = machineLabel else { return nil }
        if let custom = speakerNames[label]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        return label
    }

    /// Total duration of the source audio in seconds, when known up-front. nil for
    /// live streams (where there is no end). Used to drive a progress bar.
    @Published private(set) var totalDurationSeconds: TimeInterval?

    /// Seconds of audio we've handed to the transcription backends so far. Combined
    /// with `totalDurationSeconds`, this gives us a 0..1 progress value.
    @Published private(set) var processedDurationSeconds: TimeInterval = 0

    /// Convenience: 0..1 progress for static sources, nil for live streams.
    var progressFraction: Double? {
        guard let total = totalDurationSeconds, total > 0 else { return nil }
        return min(1.0, processedDurationSeconds / total)
    }

    /// Eager-probe state for the URL the user is currently editing. Driven by
    /// `beginProbe(for:)` (called from the sidebar's `urlInput` onChange) so
    /// the sidebar can show "Auto (Static, 24:13)" before the user presses
    /// Start. Probe results are cached in `probedDuration` and reused at
    /// `start()` to avoid double-probing.
    ///
    /// Status semantics:
    ///   - `.idle`: no probe in flight; either nothing to probe (empty URL),
    ///     or a yt-dlp source we don't probe eagerly (those probe at start
    ///     to avoid hitting Keychain on every paste).
    ///   - `.probing`: ffmpeg or AVURLAsset is running. UI shows "Probing…".
    ///   - `.finite(seconds)`: probe completed; source has a known finite
    ///     duration. Triggers Static auto-resolution.
    ///   - `.live`: probe ran but couldn't determine a duration (HLS playlist
    ///     with no `#EXT-X-ENDLIST`, ffmpeg returned `N/A`). Stays Live.
    ///   - `.failed(reason)`: probe errored out. We fall back to Live mode
    ///     silently per the design call; the reason is logged but not
    ///     surfaced to the user.
    enum ProbeStatus: Equatable {
        case idle
        case probing
        case finite(TimeInterval)
        case live
        case failed(String)
    }

    @Published private(set) var probeStatus: ProbeStatus = .idle

    /// Most recent successfully-probed duration (seconds). Cached so
    /// `start()` doesn't re-probe what the sidebar already determined.
    /// Cleared when `urlInput` changes. nil = not yet probed / live / failed.
    @Published private(set) var probedDuration: TimeInterval?

    /// In-flight probe task. Captured so URL changes can cancel an
    /// outstanding probe before its result lands stale.
    private var probeTask: Task<Void, Never>?

    // MARK: - Internals

    private let extractor = AudioStreamExtractor()
    // Multi-pass live (Phase 3+) holds two transcription backends and two
    // diarization backends concurrently. The "raw" pair is the always-on
    // primary — for single-pass live mode and static mode it's the only pair
    // and behaves exactly as the pre-multi-pass `transcriber`/`diarizer`
    // properties did. The "refined" pair is allocated only when
    // `useMultiPassLive` is true; it sits ready and is invoked by the
    // refinement scheduler (Phase 4+) on a 30s rolling window. Outside
    // multi-pass live the refined pair stays nil and zero work is done for it.
    //
    // Renamed from `transcriber`/`diarizer` so the "this is the streaming/
    // per-chunk pipeline" role is explicit at every call site. The actual
    // backend instance type (WhisperKitBackend, etc.) hasn't changed.
    private var rawTranscriber: TranscriptionBackend?
    private var rawDiarizer: DiarizationBackend?
    private var refinedTranscriber: TranscriptionBackend?
    private var refinedDiarizer: DiarizationBackend?
    private var pipelineTask: Task<Void, Never>?

    /// Watchdog for the graceful-stop path. The graceful path (multi-pass
    /// live) doesn't cancel `pipelineTask` directly; it stops the extractor
    /// and trusts the audio frame loop to exit naturally → `.finalizing` →
    /// `awaitRefinementGrace(15s)` → `.idle`. If any link in that chain
    /// stalls (ffmpeg hung, AsyncStream not finishing, refinement task not
    /// honoring cancellation), the user is stuck with a session that "won't
    /// stop." The watchdog fires after a bounded budget, forces the cancel
    /// path, and logs whatever state things were left in for diagnosis.
    ///
    /// Cleared either by the natural-end branch reaching `.idle` (success
    /// path), or by the watchdog itself firing (forced path).
    private var stopWatchdogTask: Task<Void, Never>?

    /// Most recent watchdog timeout in seconds. Recorded when the watchdog
    /// is scheduled so `fireStopWatchdog` can log the actual budget that
    /// elapsed (which varies — 20s for multi-pass-only, 300s for
    /// post-finish re-diarization). Without this, the log hardcoded "after
    /// 20s" regardless of the real timeout, which masked long waits.
    private var stopWatchdogTimeoutSeconds: UInt64 = 0

    private var elapsedTimer: Timer?
    private var startWallClock: Date?

    // Audio chunking config — adaptive based on source type. See `currentChunkSeconds`
    // and `currentOverlapSeconds` below; the values used per session are decided in
    // `start()` based on whether we have a known total duration.
    //
    // Live mode currently uses the same 30s window as static mode. The original
    // intent was 5s for low latency, but small windows hurt Whisper accuracy
    // (out-of-distribution: trained on 30s clips, padded with silence below that)
    // AND hurt diarization (less voice context per cluster decision). Until live
    // accuracy is confirmed acceptable, we trade first-text latency (~30s instead
    // of ~6s) for transcription/diarization quality. When it's time to optimize
    // for real-time display, options include: separate live transcription vs
    // diarization windows, rolling re-diarization, or progressive token streaming.
    //
    // Live overlap is intentionally larger than static (5s vs 2s) because per-chunk
    // diarization in live mode benefits from shared boundary context — Sortformer
    // and SpeakerKit's chunk-stitching heuristics produce more stable speaker IDs
    // when consecutive chunks have meaningful overlap to align on. Static mode
    // bypasses this with whole-file diarization, so it doesn't need the extra
    // overlap. The shared word-level dedup (`trimmedAfterOverlap`) scales its
    // search depth from `overlapSeconds`, so larger overlap is handled automatically.
    private static let liveChunkSeconds: Double = 30.0
    private static let liveOverlapSeconds: Double = 5.0
    /// Whisper's native window is 30 seconds — the model was trained on 30s clips.
    /// Feeding shorter clips means Whisper pads with silence, which is out-of-distribution
    /// and causes more transcription errors near chunk boundaries. For static sources
    /// where latency doesn't matter, use 30s for max accuracy.
    private static let staticChunkSeconds: Double = 30.0
    private static let staticOverlapSeconds: Double = 2.0

    // Multi-pass live chunking (Phase 4+). When `useMultiPassLive` is true,
    // the raw pass runs on small chunks for low display latency — accuracy
    // on these short windows is fine because the refinement pass covers the
    // out-of-distribution issue by running the same audio through a 30s
    // window. Per design §3.5 defaults: 5s chunks with 1s overlap. These
    // values were the original "intent" for live mode that we couldn't ship
    // until we had a refinement pass to clean up the resulting accuracy loss.
    private static let multiPassRawChunkSeconds: Double = 5.0
    private static let multiPassRawOverlapSeconds: Double = 1.0

    // Single-pass live with Parakeet. Parakeet (NVIDIA's streaming ASR via MLX)
    // is trained on variable-length audio and designed for low-latency streaming,
    // so the OOD-on-short-windows problem that forces Whisper to 30s in single-
    // pass live does NOT apply here. Using 30s for Parakeet just throws away
    // its main advantage and pushes first-text latency to ~30s for no accuracy
    // benefit.
    //
    // Originally tried 5s (matching the multi-pass raw pass). That was too tight
    // in practice: any sentence longer than ~5s got split at the chunk boundary,
    // and the per-backend fuzzy dedup catches duplicated *words* but can't
    // reconstruct a sentence that was sliced mid-clause. 10s halves the boundary
    // frequency and lets most sentences complete within one window while still
    // delivering text well before Whisper's 30s. Overlap stays at 1s — that's
    // enough for the fuzzy aligner to anchor on without inflating per-chunk work.
    //
    // WhisperKit single-pass live still uses `liveChunkSeconds`/`liveOverlapSeconds`
    // (30s/5s) for the OOD reason above; the branch in start() selects on
    // `transcriptionEngine`. Multi-pass raw stays at 5s because the refinement
    // pass downstream rebuilds proper sentence boundaries from the 30s window.
    private static let parakeetSinglePassLiveChunkSeconds: Double = 10.0
    private static let parakeetSinglePassLiveOverlapSeconds: Double = 1.0

    /// The actual chunk size and overlap chosen for the current session. Set in start().
    private var chunkSeconds: Double = TranscriptionEngine.liveChunkSeconds
    private var overlapSeconds: Double = TranscriptionEngine.liveOverlapSeconds

    private var pcmBuffer: [Float] = []
    private var totalSamplesProcessed: Int = 0
    private let sampleRate: Double = 16_000

    private var allSpeakerTurns: [SpeakerTurn] = []

    /// In static mode we accumulate the entire audio stream so SpeakerKit can run
    /// whole-file diarization once at the end. This gives much better speaker
    /// attribution than the chunked path's per-window clustering. nil when not in
    /// static-diarization mode.
    private var fullPcmBuffer: [Float]?

    // MARK: Multi-pass refinement state (Phase 4)
    //
    // Independent rolling buffer for the refinement pass. The audio extractor
    // frame loop tees into this AND into `pcmBuffer`; the raw pipeline drains
    // `pcmBuffer` per chunk (5s by default in multi-pass), while the
    // refinement scheduler drains `refinePcmBuffer` per cadence (30s by
    // default). Separate buffers because their consumption rates differ —
    // raw is small and frequent, refine is large and rare. Allocated only
    // when `useMultiPassLive` is true; nil otherwise (no memory cost for
    // single-pass live or static).
    //
    // Memory bound: at most `refineWindowSeconds + refineCadenceSeconds`
    // worth of samples in flight at any time (one window being built, one
    // window's worth of newer audio behind it). 60s × 16kHz × 4B ≈ 3.8MB.
    private var refinePcmBuffer: [Float]?

    /// Audio timestamp (in stream-timeline seconds) of the next sample sitting
    /// at the front of `refinePcmBuffer`. Used to map buffer-relative segment
    /// timestamps from the refined backends back to stream-absolute times for
    /// `replaceSegments`. Advances by `refineCadenceSeconds` per pass.
    private var refineBufferStartTime: TimeInterval = 0

    /// Set to the most recent `Date()` whenever `appendTranscribedSegments`
    /// actually appended at least one segment. The refinement scheduler reads
    /// this to honor design §4: "Refinement pauses entirely when raw pass has
    /// not produced output for ≥10s (likely audio gap or stream stall)."
    private var lastRawProducedAt: Date?

    /// Long-running task that drives `runRefinementScheduler`. nil when
    /// refinement isn't running (single-pass live, static, or session
    /// stopped). Cancelled by `stop()` and on pipeline error.
    private var refinementTask: Task<Void, Never>?

    /// True when this session uses whole-file diarization (static sources, with a
    /// diarizer that's actually enabled). Decided at start() based on whether the
    /// source has a known duration.
    private var useStaticDiarization: Bool = false

    /// Captured at `start()` from `refinementEnabled` && `resolvedSessionMode == .live`.
    /// When true, segments produced in this session are stamped `.raw` (or later
    /// `.pending`/`.refined`) by the multi-pass pipeline; when false, every segment
    /// produced is `.refined` from the start, matching pre-multi-pass behavior.
    /// We capture this rather than read `refinementEnabled` live so a UI toggle
    /// mid-session can't half-flip a running pipeline's segment-state stamping.
    private var useMultiPassLive: Bool = false

    /// Captured at `start()` from `postFinishRediarizeEnabled` && live mode &&
    /// a diarizer is on. When true, the audio stream is teed into `fullPcmBuffer`
    /// for the entire session (same buffer static mode uses), and at end-of-
    /// session a fresh SpeakerKitBackend is spun up to re-diarize the whole
    /// audio. See the `postFinishRediarizeEnabled` property doc for rationale
    /// and memory cost. Captured the same way as `useMultiPassLive` — UI
    /// toggles mid-session can't half-flip a running pipeline's accumulation
    /// behavior; if the buffer wasn't being filled from the start, we have
    /// nothing to re-diarize at the end and we don't pretend otherwise.
    private var useLivePostFinishRediarize: Bool = false

    /// Set by `stop()` so the pipeline's teardown branch can distinguish
    /// a user-initiated stop (we want to finalize in-flight refinement
    /// before terminating) from a cancellation triggered by an error or
    /// app shutdown (we want to bail fast). Cleared at `start()` so the
    /// next session starts clean.
    ///
    /// When this is true AND multi-pass live is active AND a refinement
    /// task is alive, the natural-end branch in `runPipeline` shows the
    /// `.finalizing("Finalizing refinement…")` state and gives the
    /// in-flight pass up to 15s to complete before transitioning to
    /// `.idle`. Without multi-pass live (or without an active refinement
    /// task), teardown is instant.
    private var userInitiatedStop: Bool = false

    // Stats accumulators for realtime factor
    private var totalAudioProcessed: TimeInterval = 0
    private var totalProcessingTime: TimeInterval = 0

    // MARK: - Public control

    @MainActor
    func start(urlString: String) async {
        guard !state.isActive else { return }

        // Even though state is .idle, a previous session's `pipelineTask`
        // might still be unwinding (the watchdog sets state to .idle
        // immediately when force-cancelling, but the cancelled task's
        // continuations finish asynchronously). If we reset shared state
        // (`pcmBuffer`, `segments`, `totalSamplesProcessed`, etc.) while
        // the old task is still mid-await, the old task can resume and
        // mutate the new session's state — most visibly,
        // `drainBufferIfReady` would do `pcmBuffer.removeFirst(stride)`
        // on the just-cleared buffer and trap. Wait briefly for the old
        // task to complete (it's already cancelled; awaiting just lets
        // the unwind finish) before touching shared state.
        //
        // Bounded by a 10s ceiling — if the old task is genuinely stuck
        // (a backend inference call that doesn't honor cancellation, for
        // example), we orphan it rather than blocking the new session
        // indefinitely. Combined with `drainBufferIfReady`'s post-await
        // cancellation+size recheck, an orphaned task can still finish
        // its inference and try to mutate `pcmBuffer` without crashing —
        // it'll just see `Task.isCancelled` and return.
        if let previousTask = pipelineTask {
            previousTask.cancel()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await previousTask.value }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                }
                _ = await group.next()
                group.cancelAll()
            }
            pipelineTask = nil
        }

        // Clear any leftover stop intent from a prior session — fresh session,
        // fresh state. Without this, a hard error-then-restart sequence could
        // confuse the next teardown branch.
        userInitiatedStop = false

        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .error("Please enter a URL or file path")
            return
        }

        // Resolve input to a URL. Three accepted forms:
        //   1) Standard URL with scheme: https://…, file://…
        //   2) Absolute filesystem path: /Users/foo/video.mp4
        //   3) Tilde-expanded path: ~/Movies/video.mp4
        let url: URL
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            url = URL(fileURLWithPath: expanded)
        } else if let parsed = URL(string: trimmed), parsed.scheme != nil {
            url = parsed
        } else {
            state = .error("Could not parse URL or path")
            return
        }

        // For local files, sanity-check existence before kicking off the pipeline so
        // the error appears immediately rather than as a cryptic ffmpeg failure later.
        if url.isFileURL,
           !FileManager.default.fileExists(atPath: url.path) {
            state = .error("File not found: \(url.path)")
            return
        }

        let source = StreamSource.detect(from: url)
        detectedSource = source

        // Reset session
        segments = []
        pcmBuffer = []
        totalSamplesProcessed = 0
        allSpeakerTurns = []
        elapsedSeconds = 0
        detectedLanguage = nil
        processedDurationSeconds = 0
        speakerNames = [:]
        pinnedQuotes = []

        // Miniplayer reset: drop any URL from a previous transcription
        // and clear the media cache from disk so we never accidentally
        // play back stale audio against a fresh transcript. For local
        // files, set the playback URL immediately to the original file
        // path — the user can scrub through it the moment the
        // transcription starts. For live/URL sources, this stays nil
        // until the pipeline's natural-end branch confirms the cache
        // file is on disk.
        playbackMediaURL = nil
        MediaCacheManager.clearAll()
        if url.isFileURL {
            playbackMediaURL = url
        }

        // Probe duration. Synchronous portion only — async probes (yt-dlp,
        // wait-for-in-flight-eager-probe) happen below if we don't have a
        // cached value. Three local cases here:
        //  - Local file: synchronous AVURLAsset probe (cheap, no I/O surprises).
        //  - Eager-probe cache hit: reuse the value the sidebar already
        //    determined; nothing more needed.
        //  - Anything else: leave nil for now; async path below resolves.
        if source == .localFile {
            // Cache may also have it (sidebar eagerly probed local files),
            // but AVURLAsset is so fast we don't bother branching.
            totalDurationSeconds = TranscriptionEngine.probeDuration(of: url)
        } else if let cached = probedDuration {
            totalDurationSeconds = cached
            print("[Pipeline] Using cached eager-probe duration: \(String(format: "%.1f", cached))s")
        } else {
            totalDurationSeconds = nil
        }

        // Async fallback for remote sources that don't have a cached probe
        // result. Phase 8 + this revision: eager probes (via `beginProbe`)
        // cover all URL types now, so the common case is "cache hit" and
        // this entire block is skipped. The fallbacks here cover:
        //
        //   - User pasted and pressed Start before eager probe completed
        //     → wait briefly for in-flight probe (timeout differs by
        //     strategy: ffmpeg is fast, yt-dlp can be slow).
        //   - No eager probe ran (e.g. URL came from a path other than the
        //     sidebar's onChange — direct API call, programmatic Start) →
        //     probe synchronously now.
        //   - Eager probe already concluded `.live` → accept that and
        //     proceed with no finite duration.
        //
        // Skipped entirely when the user has explicitly chosen Live mode
        // (no need to probe if we're going Live regardless).
        if source != .localFile && totalDurationSeconds == nil && sessionMode != .live {
            // Show a "probing" state so the user knows why Start is taking
            // a moment. Replaced by the real preparing state once the
            // pipeline begins.
            state = .preparing("Checking source duration…")

            // Wait for any in-flight eager probe. Timeout depends on
            // strategy: yt-dlp probes can legitimately take 10+s, so
            // we give them up to 12s; ffmpeg probes finish in under a
            // second so 3s is plenty.
            if probeStatus == .probing {
                let timeout: TimeInterval = source.requiresYTDlp ? 12.0 : 3.0
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline, probeStatus == .probing {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                totalDurationSeconds = probedDuration
            }

            // After waiting, if still no duration AND the probe didn't
            // already conclude Live or failed, fire one ourselves. This is
            // the "no eager probe ran" path — typically only hit by
            // direct/programmatic Start calls; the sidebar's onChange
            // would have triggered one.
            if totalDurationSeconds == nil, probeStatus == .idle {
                if source.requiresYTDlp {
                    print("[Pipeline] Probing \(source.rawValue) duration via yt-dlp (start-time)…")
                    if let meta = await TranscriptionEngine.probeYTDlpMetadata(url: url) {
                        if let seconds = meta.duration {
                            totalDurationSeconds = seconds
                            print("[Pipeline] yt-dlp duration: \(String(format: "%.1f", seconds))s")
                        } else {
                            print("[Pipeline] yt-dlp duration: unknown (live or unsupported).")
                        }
                        // Backfill the title if the start-time probe found one
                        // and we didn't already have one from the eager probe.
                        if let title = meta.title, !title.isEmpty,
                           self.detectedTitle == nil {
                            self.detectedTitle = title
                        }
                    } else {
                        print("[Pipeline] yt-dlp duration: unknown (live or unsupported).")
                    }
                } else {
                    let result = await TranscriptionEngine.probeRemoteDurationViaFFmpeg(url: url)
                    if case .finite(let s) = result {
                        totalDurationSeconds = s
                        print("[Pipeline] ffmpeg probe: \(String(format: "%.1f", s))s")
                    }
                }
            }
        }

        // Resolve the effective session mode. The user's `sessionMode` is the
        // declared intent; we map it to a concrete static-vs-live choice for the
        // pipeline. `.auto` derives from duration: anything ≥10s with a known
        // duration → static (better diarization), everything else → live.
        // Explicit `.live`/`.static` skips that heuristic.
        //
        // The Static guard: for local files and direct URLs we hard-error
        // when the duration is unknown, because both have reliable probe
        // paths (AVURLAsset synchronous probe; ffmpeg header parse) — failing
        // to learn the duration means something is genuinely wrong with the
        // source. For yt-dlp sources we soften this to a warning-and-proceed:
        // yt-dlp's metadata is YouTube-version-dependent and former-livestream
        // archives in particular often return "NA" for duration despite
        // being playable VODs. The user is in a position to know (they
        // recognize the URL as a recorded video); blocking them with a hard
        // error means they can't transcribe a real VOD just because the
        // probe didn't know what to call it.
        //
        // The risk of relaxing this for yt-dlp sources is that the user
        // picks Static on a genuine live URL. In that case yt-dlp's download
        // never finishes (live segments keep coming), the temp file grows,
        // and the "Downloading audio (X%)…" status stays near 0%. The user
        // can cancel. This is a worse-than-error-message failure mode but
        // not OOM-level dangerous, and it's the price of letting the user
        // override a wrong probe verdict.
        let knownDurationOK = (totalDurationSeconds ?? 0) >= 10
        let effectiveMode: SessionMode
        switch sessionMode {
        case .auto:
            effectiveMode = knownDurationOK ? .static : .live
        case .live:
            effectiveMode = .live
        case .static:
            if !knownDurationOK {
                if source.requiresYTDlp {
                    // Soft path: warn-and-proceed. The fast-download flow
                    // will work for actual VODs and hang on actual live
                    // streams; the warning tells the user what to expect
                    // if they got the verdict wrong.
                    print("[Pipeline] User forced Static on yt-dlp source with no probed duration. Proceeding via fast-download path; cancel if the URL turns out to be a genuine live stream.")
                } else {
                    // Hard path preserved for local files / direct URLs.
                    state = .error("Static mode requires a source with a known duration (e.g. a local file or VOD). Switch to Live or Auto for streams.")
                    return
                }
            }
            effectiveMode = .static
        }
        // Publish the resolved mode so the sidebar can show it as the auto subtitle.
        resolvedSessionMode = effectiveMode

        // Use whole-file diarization when in static mode AND a diarizer is enabled.
        // This gives the diarizer global context and produces stable speaker IDs
        // without chunk-stitching heuristics. Live mode stays on the chunked path.
        useStaticDiarization = effectiveMode == .static && diarizationEngine != .off

        // Capture multi-pass live state for this session. Only meaningful in live
        // mode (static mode's diarization is already a "whole-file refinement"
        // pass of its own). Decided BEFORE chunk size below because the raw
        // pass's chunk size differs between single-pass and multi-pass live.
        useMultiPassLive = effectiveMode == .live && refinementEnabled
        if useMultiPassLive {
            print("[Pipeline] Multi-pass live mode enabled.")
        }

        // Capture live-mode post-finish re-diarization for this session. Only
        // meaningful in live mode (static mode already does whole-file
        // SpeakerKit) and only if a diarizer was selected (nothing to
        // re-diarize otherwise). The full-buffer tee below uses this flag in
        // an OR with useStaticDiarization.
        useLivePostFinishRediarize = effectiveMode == .live
            && postFinishRediarizeEnabled
            && diarizationEngine != .off
        if useLivePostFinishRediarize {
            print("[Pipeline] Live post-finish re-diarization with SpeakerKit enabled.")
        }

        // Chunk size and overlap. The `transcriptionEngine` property is the
        // *raw* engine — in multi-pass live, the refined slot may differ (see
        // `useSplitRefinedEngine`), but the refined pass uses 30s windows
        // chosen by the scheduler, not these knobs. So everything below is a
        // raw-path decision keyed on the raw engine.
        //
        // Four-way decision:
        //   - static mode: 30s / 2s (whole-file diarization compensates for
        //     the small overlap)
        //   - multi-pass live: 5s / 1s (small chunks for low display latency;
        //     refinement pass cleans up the OOD accuracy loss for Whisper-raw,
        //     and Parakeet-raw doesn't need it anyway)
        //   - single-pass live with Parakeet (raw): 10s / 1s. Parakeet is a
        //     streaming ASR trained on variable-length audio; 30s wastes its
        //     low-latency advantage with no accuracy upside. 10s (not 5s) so
        //     most sentences fit inside a single chunk — see comment near
        //     `parakeetSinglePassLiveChunkSeconds` for the split-sentence
        //     rationale.
        //   - single-pass live with Whisper (raw): 30s / 5s (today's behavior,
        //     kept unchanged — Whisper trades latency for accuracy on its
        //     native 30s window in this mode)
        if effectiveMode == .static {
            chunkSeconds = TranscriptionEngine.staticChunkSeconds
            overlapSeconds = TranscriptionEngine.staticOverlapSeconds
        } else if useMultiPassLive {
            chunkSeconds = TranscriptionEngine.multiPassRawChunkSeconds
            overlapSeconds = TranscriptionEngine.multiPassRawOverlapSeconds
        } else if transcriptionEngine == .parakeet {
            chunkSeconds = TranscriptionEngine.parakeetSinglePassLiveChunkSeconds
            overlapSeconds = TranscriptionEngine.parakeetSinglePassLiveOverlapSeconds
        } else {
            chunkSeconds = TranscriptionEngine.liveChunkSeconds
            overlapSeconds = TranscriptionEngine.liveOverlapSeconds
        }
        if useMultiPassLive && useSplitRefinedEngine && refinedTranscriptionEngine != transcriptionEngine {
            print("[Pipeline] Session mode: \(effectiveMode.displayName) (user=\(sessionMode.displayName)), engine=\(transcriptionEngine.rawValue) (raw) + \(refinedTranscriptionEngine.rawValue) (refined), chunks: \(chunkSeconds)s with \(overlapSeconds)s overlap")
        } else {
            print("[Pipeline] Session mode: \(effectiveMode.displayName) (user=\(sessionMode.displayName)), engine=\(transcriptionEngine.rawValue), chunks: \(chunkSeconds)s with \(overlapSeconds)s overlap")
        }

        // Initialize the refine buffer state for multi-pass live. Capacity
        // reservation matches the in-flight memory bound documented near
        // `refinePcmBuffer`'s declaration.
        if useMultiPassLive {
            let cadence = max(refineCadenceSeconds, refineWindowSeconds)
            let estimatedSamples = Int((refineWindowSeconds + cadence) * sampleRate)
            var buffer = [Float]()
            buffer.reserveCapacity(estimatedSamples)
            refinePcmBuffer = buffer
            refineBufferStartTime = 0
            lastRawProducedAt = nil
            // Phase 7: reset rolling stats and seed the active cadence from
            // the user's nominal slider value. Auto-adjust will only ever
            // raise this above its starting value; the user's setting is
            // the floor.
            refinementStats = RefinementStats()
            activeRefineCadence = max(refineCadenceSeconds, refineWindowSeconds)
        } else {
            refinePcmBuffer = nil
            refineBufferStartTime = 0
            lastRawProducedAt = nil
            refinementStats = RefinementStats()
            activeRefineCadence = refineCadenceSeconds
        }

        if useStaticDiarization || useLivePostFinishRediarize {
            // Pre-allocate enough capacity for the whole audio so we don't pay for
            // repeated [Float] reallocation as ffmpeg streams in. For live sessions
            // we don't know the duration up-front (it could be a 5-minute clip or
            // an 8-hour broadcast), so `totalDurationSeconds` will be nil and the
            // estimate falls back to the +16_000 floor; the buffer then grows
            // dynamically as audio arrives. The cost of growth on live is
            // amortized O(1) — Array doubles capacity — and dwarfed by the
            // per-frame work anyway.
            let estimatedSamples = Int((totalDurationSeconds ?? 0) * sampleRate) + 16_000
            var buffer = [Float]()
            buffer.reserveCapacity(estimatedSamples)
            fullPcmBuffer = buffer
            let mode = useStaticDiarization ? "whole-file" : "post-finish re-diarization"
            print("[Pipeline] Full-audio buffer enabled (\(mode), estimated \(estimatedSamples) samples).")
        } else {
            fullPcmBuffer = nil
        }

        startWallClock = Date()
        totalAudioProcessed = 0
        totalProcessingTime = 0
        realtimeFactor = 0
        startElapsedTimer()

        // Build backends per current selection. We rebuild every start so changing the
        // engine in the UI takes effect immediately on next run.
        rebuildBackends()

        // Set an initial preparing state synchronously so the user gets immediate visual
        // feedback. The pipeline will overwrite this with more specific messages as it runs.
        state = .preparing("Starting…")

        pipelineTask = Task { [weak self] in
            await self?.runPipeline(url: url, source: source)
        }
    }

    @MainActor
    func stop() {
        // Immediately mark "user wants to stop" so the UI can flip the
        // primary button to "Stopping…" even if the underlying state path
        // takes a while to reach `.idle`. Cleared at every `.idle`
        // transition in `runPipeline` and in `fireStopWatchdog`.
        isStopping = true

        // Two teardown modes:
        //
        // (1) Multi-pass live with an active pipeline → graceful. Set the
        //     flag, stop the extractor so the audio stream completes, and
        //     let `runPipeline`'s natural-end branch take over. It'll
        //     transition into `.finalizing("Finalizing refinement…")` and
        //     give an in-flight refinement up to 15s to complete before
        //     reaching `.idle`. We do NOT cancel `pipelineTask` here —
        //     that would throw CancellationError and skip the grace path.
        //
        // (1b) Live post-finish re-diarization → also graceful, for the
        //     same reason. We need the natural-end branch's section 6 to
        //     run so a fresh SpeakerKitBackend can chew on `fullPcmBuffer`
        //     and replace the streaming-diarizer's labels. Cancelling
        //     mid-flight would skip that and waste the buffered audio.
        //
        // (2) Anything else → instant. Today's behavior: cancel the
        //     pipeline task, kick the state machine to idle immediately.
        //     Covers single-pass live without rediarize, static mode, and
        //     the edge case of a Stop during the pre-pipeline probe phase
        //     (pipelineTask may be nil).
        //
        // The grace path needs `pipelineTask != nil` (a Stop during probe
        // has nothing to wait for) AND at least one finalization reason
        // (`useMultiPassLive` or `useLivePostFinishRediarize`). When both
        // are active they're handled sequentially in runPipeline (5b then
        // 6); a single graceful path covers both.
        let needsGracefulFinalization = useMultiPassLive || useLivePostFinishRediarize
        let graceful = needsGracefulFinalization && pipelineTask != nil && state.isActive
        userInitiatedStop = graceful

        Task { await extractor.stop() }

        if graceful {
            // Pipeline will drive the rest of the state machine through
            // natural-end teardown. We just record the intent. Stop button
            // stays visible but goes disabled via `isFinalizing` once the
            // pipeline transitions into the .finalizing state.
            print("[Pipeline] User stop with finalization work pending (multi-pass=\(useMultiPassLive), rediarize=\(useLivePostFinishRediarize)) — waiting.")

            // Watchdog: if the graceful path stalls (ffmpeg not exiting,
            // AsyncStream not finishing, refinement task ignoring cancel —
            // anything that breaks the natural-end chain), force termination
            // after a bounded budget.
            //
            // Budget depends on what work has to land:
            //   - multi-pass refinement only: 15s grace + 5s slack = 20s.
            //   - post-finish re-diarization: SpeakerKit's whole-file pass
            //     on a multi-hour buffer can run 30-60s on its own. Use a
            //     much larger ceiling (5 minutes) since the work is real
            //     and we'd rather wait than throw away the buffered audio
            //     and the user's setup. If both are active, take the max.
            //
            // The state check inside the task uses `state.isActive` which
            // covers `.streaming`, `.finishing`, `.finalizing(_)`,
            // `.preparing(_)` — any not-yet-idle state. We only force-cancel
            // if the pipeline is genuinely stuck, not if it's progressing
            // through teardown.
            let watchdogSeconds: UInt64
            if useLivePostFinishRediarize {
                watchdogSeconds = 300 // 5 minutes, covers long-stream SpeakerKit
            } else {
                watchdogSeconds = 20  // multi-pass refinement only
            }
            stopWatchdogTask?.cancel()
            stopWatchdogTimeoutSeconds = watchdogSeconds
            stopWatchdogTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: watchdogSeconds * 1_000_000_000)
                guard let self else { return }
                await self.fireStopWatchdog()
            }
        } else {
            pipelineTask?.cancel()
            stopElapsedTimer()
            if state.isActive {
                state = .idle
            }
            isStopping = false
        }
    }

    /// Force-cancel the pipeline if graceful stop didn't reach `.idle` in
    /// time. Runs on MainActor (Task's actor context inherited from the
    /// engine class — `state` is published and read from MainActor).
    ///
    /// Diagnostic intent: any time this fires, something is wrong with the
    /// natural-end chain. The log line dumps enough state to start
    /// debugging from the log alone.
    @MainActor
    private func fireStopWatchdog() {
        // If we already reached idle, the watchdog beat us to cancellation
        // via the natural-end branch. Nothing to do.
        guard state.isActive else {
            stopWatchdogTask = nil
            return
        }

        let stateDescription: String = {
            switch state {
            case .idle: return "idle"
            case .preparing(let s): return "preparing(\(s))"
            case .streaming: return "streaming"
            case .finishing: return "finishing"
            case .finalizing(let s): return "finalizing(\(s))"
            case .error(let s): return "error(\(s))"
            }
        }()
        let pipelineAlive = (pipelineTask != nil)
        let refinementAlive = (refinementTask != nil)
        print("[Pipeline] STOP WATCHDOG fired after \(stopWatchdogTimeoutSeconds)s — graceful path did not reach idle. state=\(stateDescription), pipelineTask=\(pipelineAlive ? "alive" : "nil"), refinementTask=\(refinementAlive ? "alive" : "nil"). Forcing cancel.")

        pipelineTask?.cancel()
        refinementTask?.cancel()
        stopElapsedTimer()
        state = .idle
        isStopping = false
        stopWatchdogTask = nil
    }

    // MARK: - Backend assembly

    /// The transcription engine kind that should drive the refined pass for
    /// the current configuration. Returns `transcriptionEngine` (mirrors raw)
    /// when the split toggle is off; otherwise returns `refinedTranscriptionEngine`.
    /// Read by `rebuildBackends` and by the session-start logging.
    ///
    /// MainActor-scoped because both `@Published` source properties are
    /// MainActor-only. Don't call from off the main actor.
    @MainActor
    private var effectiveRefinedEngine: TranscriptionEngineKind {
        useSplitRefinedEngine ? refinedTranscriptionEngine : transcriptionEngine
    }

    @MainActor
    private func rebuildBackends() {
        // Raw pair: the always-on primary. For single-pass live mode and
        // static mode this is the only pair, and the chunked pipeline drives
        // through it just like before multi-pass existed. Per the design
        // doc §3.5 the "existing single-engine pickers stay; when refinement
        // is off, those drive both passes" — so we read from
        // `transcriptionEngine` / `diarizationEngine` here regardless of
        // refinement state.
        rawTranscriber = makeTranscriber(kind: transcriptionEngine, role: "raw")
        rawDiarizer = makeDiarizer(kind: diarizationEngine)

        // Refined pair: a second, independent set of backend instances used
        // by the refinement scheduler on a 30s rolling window.
        //
        // Engine kind selection: `effectiveRefinedEngine` returns
        // `transcriptionEngine` (mirror raw) by default, or
        // `refinedTranscriptionEngine` if the user opted in to the split via
        // `useSplitRefinedEngine`. The canonical split is Parakeet-raw +
        // Whisper-refined: Parakeet's streaming-friendly low-latency
        // inference for display, Whisper's 30s-native accuracy for the
        // cleanup pass.
        //
        // Constructing two instances is correct even when both slots use the
        // same engine kind: each backend wraps internal state (Whisper's
        // transcription context, Sortformer's streaming state, etc.) that
        // must NOT be shared between passes — the refined pass needs a fresh
        // context per call (design §7.1). Two separate `Actor` instances
        // guarantee that isolation cheaply.
        if useMultiPassLive {
            let refinedKind = effectiveRefinedEngine
            refinedTranscriber = makeTranscriber(kind: refinedKind, role: "refined")
            refinedDiarizer = makeDiarizer(kind: diarizationEngine)
            if refinedKind == transcriptionEngine {
                print("[Pipeline] Multi-pass live: built refined pair (transcriber=\(refinedKind.rawValue), diarizer=\(diarizationEngine.rawValue)).")
            } else {
                print("[Pipeline] Multi-pass live: built split pair (raw transcriber=\(transcriptionEngine.rawValue), refined transcriber=\(refinedKind.rawValue), diarizer=\(diarizationEngine.rawValue)).")
            }
        } else {
            refinedTranscriber = nil
            refinedDiarizer = nil
        }
    }

    /// Factory for transcription backends. Pulled out of `rebuildBackends`
    /// so the raw and refined pair both build through the same construction
    /// path — keeping their configuration in lockstep is the whole point of
    /// "same engine both slots" for Phase 3.
    ///
    /// Phase 7: optionally takes a compute-units hint, plumbed through to
    /// WhisperKit (the only currently-applicable backend; see `ComputeUnits`
    /// docs for what each backend honors). The engine uses `.auto` for both
    /// raw and refined today — preserves pre-Phase-7 behavior. A future
    /// caller could pass `.cpuAndNeuralEngine` for raw and `.cpuAndGPU` for
    /// refined to spread CoreML load across compute units; the plumbing
    /// supports it.
    @MainActor
    private func makeTranscriber(kind: TranscriptionEngineKind,
                                 computeUnits: ComputeUnits = .auto,
                                 role: String = "") -> TranscriptionBackend {
        switch kind {
        case .whisperKit:
            return WhisperKitBackend(
                modelName: whisperModelName,
                languageCode: selectedLanguageCode,
                computeUnits: computeUnits,
                role: role
            )
        case .parakeet:
            return ParakeetBackend(
                modelRepo: parakeetModelName,
                chunkDuration: chunkSeconds
            )
        }
    }

    /// Factory for diarization backends. Same rationale as `makeTranscriber`.
    @MainActor
    private func makeDiarizer(kind: DiarizationEngineKind) -> DiarizationBackend {
        switch kind {
        case .off:
            return NoOpDiarizationBackend()
        case .speakerKit:
            return SpeakerKitBackend()
        case .sortformer:
            return SortformerBackend()
        }
    }

    /// Map the engine's selected transcription engine + model name onto a
    /// `ModelDownloadManager.ModelKey` so the pipeline can report status to
    /// the same indicator the sidebar's pre-download button drives. Returns
    /// nil for engine kinds we haven't wired into the manager — today every
    /// kind maps, but this keeps the call sites safe if a future engine is
    /// added before its manager support lands.
    @MainActor
    private func transcriberKey(kind: TranscriptionEngineKind) -> ModelDownloadManager.ModelKey? {
        switch kind {
        case .whisperKit: return .whisper(modelName: whisperModelName)
        case .parakeet:   return .parakeet(modelRepo: parakeetModelName)
        }
    }

    /// Diarizer equivalent of `transcriberKey`. The `.off` case returns nil
    /// because there's no model to track for the no-op diarizer.
    @MainActor
    private func diarizerKey(kind: DiarizationEngineKind) -> ModelDownloadManager.ModelKey? {
        switch kind {
        case .off:        return nil
        case .speakerKit: return .speakerKit
        case .sortformer: return .sortformer
        }
    }

    /// Run a backend `prepare()` while bracketing it with status updates to
    /// `ModelDownloadManager`. Keeps `runPipeline` legible — the status
    /// reporting is a strict overlay on top of the existing `try await
    /// backend.prepare()` calls, not a rewrite. Caller passes `key = nil` to
    /// skip reporting (e.g. for refined-pair prepares where the model is the
    /// same as the raw pass and we don't want to double-report status flips).
    private func preparingWithStatusReport(
        key: ModelDownloadManager.ModelKey?,
        prepare: () async throws -> Void
    ) async throws {
        if let key {
            // Don't downgrade .ready → .downloading on the second prepare of a
            // session: the model is already loaded. Only flip status when it's
            // actually a "first time this session" prepare. The manager doesn't
            // know that from outside, so we make the decision here.
            //
            // **Choice of label: downloading vs loading.** A `.cached` model
            // is already on disk — `prepare()` just loads the CoreML/MLX
            // weights into RAM, no network involved (typically 1-10s). A
            // `.notDownloaded` (or `.unknown`/`.error`) model needs to be
            // fetched from Hugging Face first (potentially minutes). Same
            // indeterminate-spinner UX in either case, but the LABEL
            // differs ("Loading…" vs "Downloading…") so users aren't
            // misled into thinking we're re-downloading a model that's
            // already on disk.
            let current = await MainActor.run { ModelDownloadManager.shared.status(key) }
            let shouldReport = current != .ready
            let isAlreadyCached: Bool = {
                if case .cached = current { return true }
                return false
            }()
            print("[Pipeline/Prepare] \(key.logTag): current status=\(current.label.isEmpty ? "unknown" : current.label), shouldReport=\(shouldReport), willLabel=\(isAlreadyCached ? "loading" : "downloading")")
            if shouldReport {
                if isAlreadyCached {
                    await MainActor.run { ModelDownloadManager.shared.markLoading(key) }
                } else {
                    await MainActor.run { ModelDownloadManager.shared.markDownloading(key) }
                }
            }
            // Start the elapsed-time ticker so the sidebar's status
            // label advances during the multi-second/multi-minute
            // prepare. Same ticker handles both .downloading and
            // .loading states. Same ticker used by the Download-button
            // path in `ModelDownloadManager.runDownload`, so the UI
            // experience is identical whether the user pre-fetched
            // explicitly or hit Start with an uncached model.
            let startedAt = Date()
            let ticker: Task<Void, Never>? = shouldReport
                ? ModelDownloadManager.shared.startElapsedTicker(key: key, startedAt: startedAt)
                : nil
            defer { ticker?.cancel() }
            do {
                try await prepare()
                ticker?.cancel()
                let total = Date().timeIntervalSince(startedAt)
                print(String(format: "[Pipeline/Prepare] %@: complete in %.2fs", key.logTag, total))
                if shouldReport {
                    await MainActor.run { ModelDownloadManager.shared.markReady(key) }
                }
            } catch {
                ticker?.cancel()
                await MainActor.run {
                    ModelDownloadManager.shared.markError(key, message: error.localizedDescription)
                }
                throw error
            }
        } else {
            try await prepare()
        }
    }

    // MARK: - Pipeline

    /// Snapshot of the engine state we capture once at the top of
    /// `runPipeline`. Bundling these into a struct rather than a 10-element
    /// tuple is purely a readability fix — large tuples produce cryptic
    /// compile errors when one field's type drifts, and naming the fields
    /// in a struct catches misuse at the call site with a clearer message.
    /// All fields are captured on MainActor in one hop, so once this is
    /// built the rest of the pipeline can read it without re-touching
    /// `@Published` state.
    private struct PipelineSnapshot {
        let rawTranscriber: TranscriptionBackend?
        let rawDiarizer: DiarizationBackend?
        let refinedTranscriber: TranscriptionBackend?
        let refinedDiarizer: DiarizationBackend?
        let diarizationEngine: DiarizationEngineKind
        let multiPass: Bool
        let rawTranscriberKey: ModelDownloadManager.ModelKey?
        let rawDiarizerKey: ModelDownloadManager.ModelKey?
        let refinedTranscriberKey: ModelDownloadManager.ModelKey?
        let refinedDiarizerKey: ModelDownloadManager.ModelKey?
    }

    /// IMPORTANT: not `@MainActor`. The pipeline runs long network/CPU work and would
    /// freeze the UI if it kept the main actor pinned. We hop to MainActor only when
    /// touching `@Published` state via the small helpers below.
    private func runPipeline(url: URL, source: StreamSource) async {
        do {
            print("[Pipeline] Start. url=\(url.absoluteString) source=\(source.rawValue)")
            // Capture the initial backends from main actor — they were just
            // rebuilt. The refined pair is nil unless `useMultiPassLive`.
            // Also capture the engine kinds so we can derive `ModelKey`s for
            // download-status reporting without round-tripping back to the
            // main actor inside each prepare-bracketing helper.
            let snap = await MainActor.run { () -> PipelineSnapshot in
                // Refined transcriber key follows `useSplitRefinedEngine`:
                // when true, the refined pass uses a different engine kind
                // (`refinedTranscriptionEngine`); when false, refined and
                // raw share the same model and report to the same key. The
                // diarizer is not split today — both passes share whatever
                // diarizer the user picked — so `refinedDiarizerKey` always
                // mirrors `rawDiarizerKey`.
                let refinedTKey: ModelDownloadManager.ModelKey? = self.useSplitRefinedEngine
                    ? self.transcriberKey(kind: self.refinedTranscriptionEngine)
                    : self.transcriberKey(kind: self.transcriptionEngine)
                return PipelineSnapshot(
                    rawTranscriber: self.rawTranscriber,
                    rawDiarizer: self.rawDiarizer,
                    refinedTranscriber: self.refinedTranscriber,
                    refinedDiarizer: self.refinedDiarizer,
                    diarizationEngine: self.diarizationEngine,
                    multiPass: self.useMultiPassLive,
                    rawTranscriberKey: self.transcriberKey(kind: self.transcriptionEngine),
                    rawDiarizerKey: self.diarizerKey(kind: self.diarizationEngine),
                    refinedTranscriberKey: refinedTKey,
                    refinedDiarizerKey: self.diarizerKey(kind: self.diarizationEngine)
                )
            }
            let rawTranscriber = snap.rawTranscriber
            let rawDiarizer = snap.rawDiarizer
            let refinedTranscriber = snap.refinedTranscriber
            let refinedDiarizer = snap.refinedDiarizer
            let diarizationEngine = snap.diarizationEngine
            let multiPass = snap.multiPass
            let rawTranscriberKey = snap.rawTranscriberKey
            let rawDiarizerKey = snap.rawDiarizerKey
            let refinedTranscriberKey = snap.refinedTranscriberKey
            let refinedDiarizerKey = snap.refinedDiarizerKey

            guard let rawTranscriber, let rawDiarizer else {
                await setState(.error("Engine not initialized"))
                return
            }

            // 1. Load STT model (raw). Bracketed with ModelDownloadManager
            // status updates so the sidebar's pre-download indicator
            // reflects this load too — important for the user who hits
            // Start without pre-downloading. Without this bracket the
            // sidebar would still say "Not downloaded" while the pipeline
            // silently fetched weights.
            let sttDesc = await rawTranscriber.loadingDescription()
            print("[Pipeline] \(sttDesc)")
            await setState(.preparing(sttDesc))
            try await preparingWithStatusReport(key: rawTranscriberKey) {
                try await rawTranscriber.prepare()
            }
            print("[Pipeline] STT model ready.")

            // 2. Load diarizer (raw, skipped for NoOp).
            if diarizationEngine != .off {
                let diarDesc = await rawDiarizer.loadingDescription()
                print("[Pipeline] \(diarDesc)")
                await setState(.preparing(diarDesc))
                try await preparingWithStatusReport(key: rawDiarizerKey) {
                    try await rawDiarizer.prepare()
                }
                print("[Pipeline] Diarizer ready.")
            }
            await rawDiarizer.reset()
            print("[Pipeline] Diarizer reset.")

            // 2b. Load refined pair and launch the refinement scheduler if
            // multi-pass live is active. We load both backends in parallel
            // before starting the scheduler, then keep them resident for the
            // entire session.
            //
            // Why eager: an earlier iteration tried lazy-loading per window
            // (load before each refinement, unload after) on the hypothesis
            // that idle Whisper in memory was causing Parakeet's raw inference
            // to slow down ~4×. That hypothesis was wrong — the actual slow-
            // down was YouTube's per-connection CDN throttling capping audio
            // delivery at ~0.5× realtime. Once the audio supply was fixed
            // (yt-dlp parallel-fragment fetch via `streamViaYTDlpPipe` /
            // `downloadViaYTDlp`), Parakeet's RTF stayed well under 1× even
            // with Whisper continuously loaded. So we're back to the simpler
            // architecture: load once, run many times. This also makes
            // graceful stop more reliable — there's no model-load work in
            // flight at stop time that could compete with the grace-period
            // teardown.
            //
            // The `unload()` protocol methods on the backends are kept (they
            // do real cleanup if called) but are no longer invoked from the
            // refinement path. They remain available if a future tuning
            // session wants to revisit this trade-off.
            if multiPass, let refinedTranscriber, let refinedDiarizer {
                await setState(.preparing("Loading refined pass…"))
                print("[Pipeline] Multi-pass live: loading refined pair.")

                // Sequenced (not parallel) prepares with explicit start/finish
                // markers around each step. The earlier parallel-async-let
                // version saved ~1-2 seconds on first load but had a hang
                // mode where the log went silent in the middle of "loading
                // refined pair in parallel" with no way to tell whether
                // Whisper or Sortformer was stuck. Sequencing makes the
                // failure point trivially visible: whichever "loading…" line
                // doesn't get a paired "loaded in N.NNs" line is the
                // culprit. Empirically the speed cost is small (refined
                // pair load happens once per session, not in the audio
                // critical path) and the diagnostic clarity is worth it.
                //
                // Load Whisper first (the bigger model, higher chance of
                // hanging on CoreML compile) so any Whisper hang fails fast
                // before Sortformer runs.
                let whisperLoadStart = Date()
                print("[Pipeline] Loading refined Whisper…")
                try await preparingWithStatusReport(key: refinedTranscriberKey) {
                    try await refinedTranscriber.prepare()
                }
                print(String(format: "[Pipeline] Refined Whisper loaded in %.2fs.",
                             Date().timeIntervalSince(whisperLoadStart)))

                if diarizationEngine != .off {
                    let sortLoadStart = Date()
                    print("[Pipeline] Loading refined diarizer…")
                    try await preparingWithStatusReport(key: refinedDiarizerKey) {
                        try await refinedDiarizer.prepare()
                    }
                    print(String(format: "[Pipeline] Refined diarizer loaded in %.2fs.",
                                 Date().timeIntervalSince(sortLoadStart)))
                }

                await refinedDiarizer.reset()
                print("[Pipeline] Refined pair ready.")

                // Launch the refinement scheduler. Runs alongside the audio
                // frame loop below; its loop polls `refinePcmBuffer` and fires
                // `performRefinementPass` once 30s of audio is available.
                // Captured on `self` so `stop()` can cancel and grace-await
                // it. The Task is detached from the pipeline task hierarchy
                // so cancellation of the parent pipeline doesn't auto-cancel
                // refinement — we want stop() to drive a controlled shutdown
                // via `awaitRefinementGrace`.
                await MainActor.run {
                    self.refinementTask = Task { [weak self] in
                        await self?.runRefinementScheduler()
                    }
                }
            }

            // 3. Open audio stream
            let openingVerb = (source == .localFile) ? "Opening" : "Connecting to"
            print("[Pipeline] \(openingVerb) \(source.rawValue)…")
            await setState(.preparing("\(openingVerb) \(source.rawValue)…"))

            // Fast-download path: yt-dlp sources in static mode download
            // the audio to a temp file with parallelism flags before ffmpeg
            // touches it. The streaming path is unchanged — direct URLs,
            // local files, and yt-dlp sources in live mode all use the
            // original yt-dlp-resolve-then-ffmpeg-stream flow.
            //
            // Why static-only: the speedup comes from parallel downloads
            // beating per-connection CDN throttling, which is most useful
            // when we want the audio as fast as possible. In live mode the
            // upper bound is realtime (segments don't exist before the
            // broadcaster publishes them), so there's nothing to download
            // in parallel.
            //
            // We read `resolvedSessionMode` (the @Published mirror of
            // start()'s local `effectiveMode`) rather than recomputing —
            // `runPipeline` is a separate function and `effectiveMode`
            // isn't in scope here. The property was assigned in `start()`
            // before this task was spawned.
            let useFastDownload = source.requiresYTDlp && resolvedSessionMode == .static

            // Progress callback for the download phase. Hops to MainActor to
            // update the preparing-state status text. The callback is invoked
            // from yt-dlp's stderr readability handler — off-actor — and
            // captures `self` weakly via the inner Task. We don't worry about
            // coalescing because yt-dlp's --newline mode emits at most a few
            // progress lines per second.
            //
            // Style note: Swift's type checker chokes on
            //   `let x: (@Sendable (Double, String) -> Void)? = cond ? { ... } : nil`
            // because the closure literal's inferred type has to be unified
            // with `nil` through the optional + @Sendable + arity. Binding
            // the closure to a typed local first sidesteps the ambiguity
            // entirely.
            let downloadProgress: @Sendable (Double, String) -> Void = { pct, _ in
                let pctInt = Int((pct * 100).rounded())
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.state = .preparing("Downloading audio (\(pctInt)%)…")
                }
            }
            let progressCb: (@Sendable (Double, String) -> Void)? = useFastDownload ? downloadProgress : nil

            // Read the user's "cache video alongside audio" preference once
            // at session start. Capturing here (instead of deeper in the
            // extractor) means a setting flip mid-transcription doesn't
            // change the in-flight run's behavior — the user gets what
            // they asked for when they hit Start. Default to true if the
            // key has never been written.
            let wantsVideo = UserDefaults.standard.object(forKey: mediaCacheIncludeVideoKey) as? Bool
                ?? mediaCacheIncludeVideoDefault

            let audioStream = try await extractor.start(
                url: url,
                source: source,
                useFastDownload: useFastDownload,
                progressCallback: progressCb,
                // Media cache for the miniplayer. For non-local sources
                // we pre-compute the cache path and pass it through; the
                // extractor adds a second output to its ffmpeg invocation
                // that writes an mp4 file there in parallel with PCM
                // going to transcription. Local files skip this — the
                // original file is already playable.
                cacheOutputPath: source != .localFile ? try? MediaCacheManager.prepareForRecording().path : nil,
                // Honor the user's video-or-audio-only preference for the
                // cache output. When false, yt-dlp downloads audio-only
                // (bandwidth/disk save) and ffmpeg writes an audio-only
                // mp4 — still plays in the miniplayer, just with no
                // video track.
                wantsVideoInCache: wantsVideo
            )
            print("[Pipeline] Audio stream open. Beginning to read frames. (cache video: \(wantsVideo))")

            await setState(.streaming)

            // 4. Consume audio frames, chunk, transcribe + diarize.
            // When static diarization is on OR live post-finish re-diarization
            // is on, also tee every frame into fullPcmBuffer so SpeakerKit can
            // analyze the whole audio at once after extraction completes.
            // When multi-pass live is active, also tee into refinePcmBuffer so the
            // refinement scheduler has its own audio stream to draw windows from.
            for await frames in audioStream {
                if Task.isCancelled { break }
                await MainActor.run {
                    self.pcmBuffer.append(contentsOf: frames)
                    if self.useStaticDiarization || self.useLivePostFinishRediarize {
                        self.fullPcmBuffer?.append(contentsOf: frames)
                    }
                    if self.useMultiPassLive {
                        self.refinePcmBuffer?.append(contentsOf: frames)
                    }
                }
                try await drainBufferIfReady()
            }

            // 5. Final flush of partial chunks
            await setState(.finishing)
            try await flushRemaining()

            // 5b. Multi-pass live: cancel the scheduler and give an in-flight
            // refinement a chance to land its final window before we tear
            // down. Two grace policies:
            //   - User-initiated stop (`userInitiatedStop` is true): up to
            //     15s. The user explicitly asked to wait for refinement;
            //     15s comfortably covers a typical pass's remaining time.
            //     Shows the `.finalizing` state with an explicit label so
            //     the user knows what they're waiting for.
            //   - Natural end (stream completed on its own): 1.5s. Design
            //     §4 original behavior — best-effort catch of the final
            //     partial window without making stream-end teardown drag.
            if useMultiPassLive {
                if userInitiatedStop {
                    await setState(.finalizing("Finalizing refinement…"))
                    print("[Pipeline] User stop: awaiting in-flight refinement (up to 15s).")
                    await awaitRefinementGrace(timeout: 15.0)
                } else {
                    await awaitRefinementGrace(timeout: 1.5)
                }
            }

            // 6. Whole-file diarization. Two paths converge here:
            //   - Static-mode (always): `rawDiarizer` is already the user's
            //     chosen diarizer for the session — which, for static-mode
            //     transcription, IS SpeakerKit (the per-chunk diarization
            //     was skipped via `useStaticDiarization` so allSpeakerTurns
            //     is empty here). Reuse the loaded model.
            //   - Live-mode with `postFinishRediarizeEnabled`: the session
            //     diarizer was probably Sortformer (streaming), and now we
            //     want a one-shot whole-file SpeakerKit pass to get more
            //     stable global speaker IDs. Spin up a fresh
            //     SpeakerKitBackend just for this — we do NOT touch
            //     `rawDiarizer` because that's the live one and may need
            //     to keep its state for any UI references. Prepare it,
            //     run, then drop it; the model's ~300MB footprint is
            //     released as soon as the local goes out of scope.
            if useStaticDiarization {
                await setState(.preparing("Identifying speakers…"))
                await runWholeFileDiarization(diarizer: rawDiarizer)
            } else if useLivePostFinishRediarize {
                // `runWholeFileDiarization` will no-op if `fullPcmBuffer` is
                // nil or empty (which shouldn't happen if the toggle was on
                // from the start, but the guard is cheap insurance for
                // edge cases like an immediate stop before any audio
                // arrived). The state label + SpeakerKit setup costs are
                // paid eagerly so the user sees feedback even on the
                // no-audio edge case.
                await setState(.preparing("Re-identifying speakers with SpeakerKit…"))
                print("[Pipeline] Post-finish re-diarization: spinning up SpeakerKit for whole-file pass.")
                let finalizer = SpeakerKitBackend()
                do {
                    // Even though this SpeakerKit instance is ephemeral, route
                    // its prepare() through the status helper so the sidebar's
                    // SpeakerKit indicator shows the download/load activity. A
                    // user who turned on rediarize without ever using
                    // SpeakerKit as the primary diarizer would otherwise see
                    // no indication that a model load was happening here.
                    try await preparingWithStatusReport(key: .speakerKit) {
                        try await finalizer.prepare()
                    }
                    await runWholeFileDiarization(diarizer: finalizer)
                } catch {
                    // Don't fail the whole session if SpeakerKit can't load
                    // post-hoc — the live transcript with its per-chunk
                    // diarizer labels is still useful. Log and move on.
                    print("[Pipeline] Post-finish SpeakerKit prepare failed: \(error.localizedDescription). Keeping live diarization labels.")
                }
            }

            // Confirm the media cache file (if we asked for one) is on
            // disk and publish its URL to playbackMediaURL so the
            // miniplayer can find it. The file was written by ffmpeg
            // as a side output during the transcription; ffmpeg
            // finalizes the mkv container when its stdin closes (live
            // pipe path) or its input EOF (download paths) — both
            // happen by the time we reach this point. Local-file
            // sources skipped the cache request and already have
            // playbackMediaURL set to the original file path.
            if source != .localFile {
                let cacheURL = MediaCacheManager.currentFileURL
                if FileManager.default.fileExists(atPath: cacheURL.path) {
                    await MainActor.run {
                        self.playbackMediaURL = cacheURL
                    }
                }
            }

            await setState(.idle)
            await MainActor.run {
                self.stopElapsedTimer()
                // Free the full-buffer allocation now that we're done with it.
                self.fullPcmBuffer = nil
                self.refinePcmBuffer = nil
                // Cancel any pending stop watchdog — graceful path
                // completed within budget.
                self.stopWatchdogTask?.cancel()
                self.stopWatchdogTask = nil
                // Clear isStopping — UI can switch back to "Start" now.
                self.isStopping = false
            }
        } catch is CancellationError {
            print("[Pipeline] Cancelled.")
            // Drop refinement fast; the user wants a stop, not a delay.
            // Any in-flight inference will continue running in the background
            // (see `awaitRefinementGrace` caveat) — we don't block here.
            refinementTask?.cancel()
            // Publish the media cache file if ffmpeg managed to finalize
            // it before being killed. ffmpeg's `terminate()` (SIGTERM)
            // gives mkv a chance to write its trailing index; a hard
            // SIGKILL would not, but our shutdown path uses terminate
            // first. If the file is partial or missing, miniplayer
            // simply stays disabled — better than crashing on a
            // malformed mkv.
            if source != .localFile {
                let cacheURL = MediaCacheManager.currentFileURL
                if FileManager.default.fileExists(atPath: cacheURL.path) {
                    await MainActor.run {
                        self.playbackMediaURL = cacheURL
                    }
                }
            }
            await setState(.idle)
            await MainActor.run {
                self.stopElapsedTimer()
                self.fullPcmBuffer = nil
                self.refinePcmBuffer = nil
                self.refinementTask = nil
                self.stopWatchdogTask?.cancel()
                self.stopWatchdogTask = nil
                self.isStopping = false
            }
        } catch {
            print("[Pipeline] FAILED: \(error)")
            refinementTask?.cancel()
            await setState(.error(error.localizedDescription))
            await MainActor.run {
                self.stopElapsedTimer()
                self.fullPcmBuffer = nil
                self.refinePcmBuffer = nil
                self.refinementTask = nil
                self.stopWatchdogTask?.cancel()
                self.stopWatchdogTask = nil
                self.isStopping = false
            }
        }
    }

    /// Run SpeakerKit on the entire accumulated audio buffer, then re-attribute every
    /// segment in `segments` based on the resulting speaker turns. Replaces the chunked
    /// `allSpeakerTurns` list entirely with the higher-quality whole-file result.
    private func runWholeFileDiarization(diarizer: DiarizationBackend) async {
        let buffer = await MainActor.run { self.fullPcmBuffer }
        guard let buffer, !buffer.isEmpty else {
            print("[Pipeline] Skipping whole-file diarization (no buffer).")
            return
        }
        print("[Pipeline] Running whole-file diarization on \(buffer.count) samples (\(Double(buffer.count) / sampleRate)s)…")

        let rawTurns = await diarizer.diarizeWholeBuffer(samples: buffer, bufferStartTime: 0)
        print("[Pipeline] Whole-file diarization produced \(rawTurns.count) turn(s).")

        // Sortformer (and most neural streaming diarizers) marks
        // speaker handoffs LATE — typically 0.5-2.5s after the new
        // speaker actually starts. The model has to "hear" enough of
        // the new voice for its embedding to cross the decision
        // threshold, and that takes audio. The lag is consistent
        // because it's structural (buffer length + context window),
        // not noisy.
        //
        // Snap each Sortformer boundary backward to the nearest
        // inter-word silence gap in Whisper's word timestamps. Real
        // speaker handoffs cross silence; Sortformer just doesn't see
        // the silence until it's already crossed the new voice. This
        // produces a boundary at the actual handoff moment rather
        // than at Sortformer's lagged decision point.
        //
        // Reads `segments` (main-actor-isolated) so it has to run on
        // the main actor; we hop, do the snap, and return the
        // corrected array out.
        let turns: [SpeakerTurn] = await MainActor.run {
            self.snapSortformerBoundariesToSilence(rawTurns, allSegments: self.segments)
        }

        // Replace allSpeakerTurns and re-attribute every segment.
        await MainActor.run {
            self.allSpeakerTurns = turns
            // Two-pass: first attribute every segment to its dominant
            // speaker via majority-overlap, then split any segments
            // whose time range straddles a speaker turn boundary.
            // Without the second pass, a Whisper segment that spans
            // a speaker handoff gets attributed wholly to whichever
            // speaker has more overlap, dropping the other speaker's
            // words into the wrong row. The splitter (originally
            // built for live multi-pass refinement) uses word-level
            // timestamps to cut at clean inter-word gaps and recurses
            // for 3+ speakers per segment.
            //
            // The split-then-reattribute order matters: the splitter
            // computes labels for each piece independently using
            // `dominantSpeakerLabel`, so initial `pickSpeaker` labels
            // aren't load-bearing — they exist only so the splitter
            // can compare "did the split actually change the label"
            // and bail out cheaply when it didn't.
            let attributed = self.segments.map { seg -> TranscriptSegment in
                var copy = seg
                copy.speaker = self.pickSpeaker(start: seg.start, end: seg.end)
                return copy
            }
            var splitOut: [TranscriptSegment] = []
            splitOut.reserveCapacity(attributed.count)
            for seg in attributed {
                let pieces = self.splitSegmentAtSpeakerBoundaries(
                    seg,
                    excludingRange: nil
                )
                splitOut.append(contentsOf: pieces)
            }
            // Post-split reabsorb pass. SpeakerKit's turn boundaries
            // reflect *when the new speaker became dominant in the
            // audio*, not when the previous speaker actually stopped
            // talking — natural conversational overlap means the
            // previous speaker often finishes a word or short phrase
            // AFTER the diarizer has nominally crossed over. The
            // splitter cuts at the diarizer's boundary, which puts
            // those trailing words on the new speaker's side. Two
            // shapes show up:
            //
            //   Bracket: ...Speaker 3 → "the red tape." Speaker 2 →
            //   Speaker 3 resumes... — the lone short Speaker 2
            //   fragment is leakage from Speaker 3's actual sentence.
            //
            //   Continuation: ...Speaker 4 → "delivers consumer
            //   value." Speaker 5 → Speaker 5 continues... — Speaker
            //   4's last words got attributed to Speaker 5, opening
            //   their segment with a short fragment before their
            //   real content.
            //
            // `reabsorbTinyTrailingFragments` handles both by folding
            // B's text into A and dropping B. See the docstring for
            // the safety thresholds (word count, terminal punctuation,
            // time gap) that prevent folding real short utterances.
            self.segments = self.reabsorbTinyTrailingFragments(splitOut)
            // De-shout pass. Whisper occasionally emits long runs of
            // ALL-CAPS text — an artifact of its training on broadcast/
            // SDH caption data, which is frequently uppercase. It tends
            // to trigger on loud or broadcast-style audio and usually
            // coincides with a low-quality patch (misspellings, dropped
            // words). We can't repair the misspellings, but we can
            // recase the shouting back to sentence case so it reads
            // normally. See `deshoutRunawayCaps` for the detection
            // threshold and proper-noun preservation strategy.
            self.segments = self.deshoutRunawayCaps(self.segments)
            // Pins captured during static-mode transcription snapshotted speaker=nil
            // (because diarization runs after extraction). Now that we have real
            // speaker turns, re-resolve each pin's speaker label using its time range.
            // Manual pins from before this call would already have a speaker if the
            // user pinned during a prior session — but for a single static run the
            // common case is keyword auto-pins added before this point, all of which
            // need speaker assignment.
            self.pinnedQuotes = self.pinnedQuotes.map { quote in
                var copy = quote
                copy.speaker = self.pickSpeaker(start: quote.start, end: quote.end)
                return copy
            }
        }
    }

    /// Hop to MainActor and set state. The shorthand we use throughout the pipeline.
    private func setState(_ newState: EngineState) async {
        await MainActor.run { self.state = newState }
    }

    /// While the buffer has at least one full chunk, pull a chunk off, transcribe + diarize, advance.
    @MainActor
    private func drainBufferIfReady() async throws {
        let chunkSize = Int(chunkSeconds * sampleRate)
        let overlapSize = Int(overlapSeconds * sampleRate)
        let stride = chunkSize - overlapSize

        while pcmBuffer.count >= chunkSize {
            if Task.isCancelled { return }
            let chunk = Array(pcmBuffer.prefix(chunkSize))
            let chunkStartTime = Double(totalSamplesProcessed) / sampleRate

            try await processChunk(chunk: chunk, chunkStartTime: chunkStartTime,
                                   chunkAudioSeconds: chunkSeconds)

            // Recheck cancellation and buffer state after the await.
            // Background: `processChunk` releases the MainActor while
            // awaiting backend inference. Two things can happen during
            // that window that invalidate the post-await state:
            //   1. The watchdog force-cancels this task. `Task.isCancelled`
            //      becomes true and we should bail before mutating
            //      `pcmBuffer` or `totalSamplesProcessed`.
            //   2. A new session is started (user hits Start after the
            //      cancel). `start()` resets `pcmBuffer = []` on MainActor;
            //      our continuation then resumes and would call
            //      `pcmBuffer.removeFirst(stride)` on the empty buffer,
            //      crashing with "Can't remove more items from a collection
            //      than it has." The buffer-size guard below handles both
            //      a fresh empty buffer and a buffer that has been
            //      truncated by other concurrent activity.
            if Task.isCancelled { return }
            guard pcmBuffer.count >= stride else { return }

            pcmBuffer.removeFirst(stride)
            totalSamplesProcessed += stride
        }
    }

    @MainActor
    private func flushRemaining() async throws {
        guard !pcmBuffer.isEmpty else { return }
        let minSamples = Int(sampleRate)
        var tail = pcmBuffer
        if tail.count < minSamples {
            tail.append(contentsOf: [Float](repeating: 0, count: minSamples - tail.count))
        }
        let chunkStartTime = Double(totalSamplesProcessed) / sampleRate
        let durationSeconds = Double(tail.count) / sampleRate
        try await processChunk(chunk: tail, chunkStartTime: chunkStartTime,
                               chunkAudioSeconds: durationSeconds)
        pcmBuffer.removeAll()
    }

    @MainActor
    private func processChunk(chunk: [Float], chunkStartTime: TimeInterval,
                              chunkAudioSeconds: TimeInterval) async throws {
        // The per-chunk pipeline always uses the raw pair. The refined pair
        // (when present in multi-pass live) is driven by a separate scheduler
        // — Phase 4 wires that up; here we leave it alone.
        guard let transcriber = rawTranscriber, let diarizer = rawDiarizer else { return }

        let processingStart = Date()

        // In static-diarization mode we'll run SpeakerKit on the whole audio after
        // extraction completes — skip the per-chunk diarization to save time and to
        // avoid populating allSpeakerTurns with noisy chunk-local cluster IDs.
        if useStaticDiarization {
            let result = try await transcriber.transcribe(
                samples: chunk, chunkStartTime: chunkStartTime
            )
            let processingTime = Date().timeIntervalSince(processingStart)
            totalAudioProcessed += chunkAudioSeconds
            totalProcessingTime += processingTime
            if totalProcessingTime > 0 {
                realtimeFactor = totalAudioProcessed / totalProcessingTime
            }
            processedDurationSeconds = chunkStartTime + chunkAudioSeconds

            if detectedLanguage == nil, let lang = result.detectedLanguage {
                detectedLanguage = lang
            }

            // Append transcribed segments with no speaker label yet — they'll be
            // attributed when whole-file diarization runs at the end.
            try await appendTranscribedSegments(result.segments)
            return
        }

        // Live mode: transcribe + diarize concurrently per chunk. Both legs
        // are awaited before we proceed — the slower one gates the whole
        // pipeline. The diarizer kind is user-selectable; SpeakerKit is the
        // pyannote-based offline-style backend (heavy, designed for whole-
        // file static mode) while Sortformer is the streaming MLX backend
        // (fast, designed for live). Using SpeakerKit in live mode is a
        // misuse; the per-chunk timing logs below make that visible if it
        // happens.
        let chunkStarted = Date()
        async let transcriptionTask = transcriber.transcribe(
            samples: chunk, chunkStartTime: chunkStartTime
        )
        async let speakerTurnsTask = diarizer.diarize(
            samples: chunk, chunkStartTime: chunkStartTime
        )

        let result = try await transcriptionTask
        let transcribeElapsed = Date().timeIntervalSince(chunkStarted)
        let turns = await speakerTurnsTask
        let totalElapsed = Date().timeIntervalSince(chunkStarted)
        let diarizeAdditional = totalElapsed - transcribeElapsed

        // If diarize finished AFTER transcribe, the gap is how much extra
        // wall-clock the diarizer added on top of transcription. If it
        // finished BEFORE (negative or near-zero), transcription was the
        // bottleneck and diarize ran fully behind it. Either way, the log
        // makes the order and the relative cost explicit so the
        // "raw is slow" debugging stops being guesswork.
        if diarizeAdditional > 0.05 {
            print(String(format: "[ChunkTiming] live chunk [%.2fs..%.2fs]: transcribe=%.2fs, diarize added %.2fs after (diarize was the bottleneck)",
                         chunkStartTime, chunkStartTime + chunkAudioSeconds,
                         transcribeElapsed, diarizeAdditional))
        } else {
            print(String(format: "[ChunkTiming] live chunk [%.2fs..%.2fs]: transcribe=%.2fs, diarize finished within transcribe window",
                         chunkStartTime, chunkStartTime + chunkAudioSeconds,
                         transcribeElapsed))
        }

        let processingTime = Date().timeIntervalSince(processingStart)

        // Update realtime factor (how many seconds of audio we processed per second of wall time)
        totalAudioProcessed += chunkAudioSeconds
        totalProcessingTime += processingTime
        if totalProcessingTime > 0 {
            realtimeFactor = totalAudioProcessed / totalProcessingTime
        }
        // Position in the source audio. For static sources this drives the progress bar.
        processedDurationSeconds = chunkStartTime + chunkAudioSeconds

        if detectedLanguage == nil, let lang = result.detectedLanguage {
            detectedLanguage = lang
        }

        if !turns.isEmpty {
            allSpeakerTurns.append(contentsOf: turns)
        }

        try await appendTranscribedSegments(result.segments)
    }

    /// Diagnostic: fire the raw and refined backend pairs concurrently against
    /// a single chunk and log how long each pass takes. Proves that holding
    /// and dispatching to two transcription + two diarization backends in
    /// parallel actually works on the current hardware — particularly the
    /// open question (design Q5) of whether two CoreML models can share the
    /// ANE without one degrading. Does NOT consume the refined output for
    /// anything; the engine's segment store and pin layer aren't touched.
    /// Phase 4 wires the refined output into `replaceSegments`.
    ///
    /// Previously gated by `#if DEBUG` so release builds wouldn't carry the
    /// dead code; the Debug menu was DEBUG-only too. With the user-opt-in
    /// Debug menu (Settings → Advanced → "Show Debug menu"), this method
    /// has to be available in release builds because the menu item that
    /// calls it can be enabled by users at runtime.
    ///
    /// Audio source: whatever is currently sitting in `pcmBuffer` at the
    /// moment of the call. The buffer is what's been received from the
    /// extractor but not yet drained into a chunk, so its contents vary —
    /// usually it's at most a few seconds, never close to a full 30s window.
    /// Pads to a 1s minimum with silence if shorter. This is Phase 3's
    /// concurrency proof, not Phase 4's refinement quality test; we don't
    /// need the audio to be ideal, just real.
    @MainActor
    func _debugRunConcurrentBackends() async {
        guard let rawTr = rawTranscriber, let rawDi = rawDiarizer,
              let refTr = refinedTranscriber, let refDi = refinedDiarizer else {
            print("[Debug] Concurrent test: refined backends not constructed. Start a live session with refinementEnabled=true first.")
            return
        }

        // Under the eager-load model, the refined backends are loaded once
        // at the start of the multi-pass-live session in `runPipeline` and
        // remain resident for the whole session. So when this debug method
        // is invoked from an active session, prepare() is already done.
        //
        // If somehow the backends are constructed but not prepared (the
        // session never reached the load step, or the user invoked this
        // outside a live session via a debug menu), the transcribe/diarize
        // calls below will throw and the catch path will surface that.
        // We deliberately do NOT call prepare()/unload() here — doing so
        // would tear down models the live session needs and break the
        // multi-pass pipeline for the duration of the test.

        // Snapshot whatever audio is in flight. Copy out so the buffer can
        // continue filling while the test runs — we don't want to block the
        // real pipeline behind a debug call.
        var sample = pcmBuffer
        let minSamples = Int(sampleRate)
        if sample.count < minSamples {
            sample.append(contentsOf: [Float](repeating: 0, count: minSamples - sample.count))
        }
        let chunkStart = Double(totalSamplesProcessed) / sampleRate
        let chunkDuration = Double(sample.count) / sampleRate
        print("[Debug] Concurrent test: \(String(format: "%.2f", chunkDuration))s of audio at t=\(String(format: "%.2f", chunkStart))s. Firing 4 backends in parallel…")

        let startTime = Date()

        // Fire all four concurrently. `async let` here means the four tasks
        // start immediately and we await them all. Each backend is an Actor
        // so within itself it serializes, but two different actors run in
        // parallel — that's the property under test.
        async let rawTranscriptionResult = rawTr.transcribe(samples: sample, chunkStartTime: chunkStart)
        async let rawDiarizationResult = rawDi.diarize(samples: sample, chunkStartTime: chunkStart)
        async let refinedTranscriptionResult = refTr.transcribe(samples: sample, chunkStartTime: chunkStart)
        async let refinedDiarizationResult = refDi.diarize(samples: sample, chunkStartTime: chunkStart)

        // Collect results; report each independently so a partial failure is
        // visible. We catch transcription errors per-pass since the protocol
        // throws; diarization doesn't throw.
        var rawSttSummary = "<error>"
        var refSttSummary = "<error>"
        var rawSttCount = -1
        var refSttCount = -1
        do {
            let r = try await rawTranscriptionResult
            rawSttCount = r.segments.count
            rawSttSummary = "\(r.segments.count) seg(s), lang=\(r.detectedLanguage ?? "?")"
        } catch {
            print("[Debug] Raw STT failed: \(error)")
        }
        do {
            let r = try await refinedTranscriptionResult
            refSttCount = r.segments.count
            refSttSummary = "\(r.segments.count) seg(s), lang=\(r.detectedLanguage ?? "?")"
        } catch {
            print("[Debug] Refined STT failed: \(error)")
        }
        let rawTurns = await rawDiarizationResult
        let refTurns = await refinedDiarizationResult

        let elapsed = Date().timeIntervalSince(startTime)
        print("[Debug] Concurrent test complete in \(String(format: "%.2f", elapsed))s:")
        print("[Debug]   raw  STT: \(rawSttSummary)")
        print("[Debug]   ref  STT: \(refSttSummary)")
        print("[Debug]   raw  DIA: \(rawTurns.count) turn(s)")
        print("[Debug]   ref  DIA: \(refTurns.count) turn(s)")

        // Sanity check: if both passes saw the same audio and used the same
        // engine kinds (Phase 3 spec), the output counts should match. They
        // won't be identical down to byte level because of CoreML non-
        // determinism and Sortformer's per-instance streaming state, but the
        // shapes should align. Flag if they're wildly off — that would
        // suggest one backend ran on degraded compute (ANE contention?).
        if rawSttCount > 0, refSttCount > 0 {
            let ratio = Double(min(rawSttCount, refSttCount)) / Double(max(rawSttCount, refSttCount))
            if ratio < 0.5 {
                print("[Debug] WARNING: STT segment counts differ by >2x (\(rawSttCount) vs \(refSttCount)). Possible compute-unit contention.")
            }
        }

        // No unload here — under the eager-load model the refined pair is
        // owned by the active live session (or unloaded already if no
        // session is running). The harness is a read-only test that
        // shouldn't mutate the engine's resource lifecycle.
    }

    /// Apply boundary-overlap dedup and speaker attribution to incoming segments,
    /// then append them to the live transcript. Used by both live and static paths.
    @MainActor
    private func appendTranscribedSegments(_ incoming: [TranscriptSegment]) async throws {
        let maxOverlapWords = max(8, Int(overlapSeconds * 6.0) + 6)

        // Multi-pass live stamps each new segment `.raw` — it'll transition to
        // `.refined` (and the segment object itself will be replaced) when the
        // 30s refinement window covering it lands. Every other path emits
        // `.refined` directly: static mode's whole-file diarization at the end
        // is effectively the refinement, and single-pass live mode has no
        // second pass coming. The default on the model is `.refined`, so we
        // only need to overwrite when the multi-pass pipeline is active.
        let stampAsRaw = useMultiPassLive

        for var seg in incoming {
            // Trim any leading words that overlap with the tail of the previous segment.
            // Whisper transcribes our overlap window twice (once at the end of chunk N,
            // again at the start of chunk N+1), producing duplicated phrases like
            // "Now I work with Now I work with Spirit of America". We detect the largest
            // matching prefix↔suffix pair (case- and punctuation-insensitive, word-level)
            // and remove it from the new segment.
            //
            // **Wide prev-tail.** The duplication can span multiple segment
            // boundaries in the prior chunk's output (a chunk that emitted
            // 6 short segments may end with the overlap-region text
            // distributed across the last 2-3 of them). Joining a wider
            // window of recent segments — at least the overlap duration plus
            // a small margin — lets the suffix↔prefix match find duplications
            // the single-`last.text` lookback misses.
            //
            // **Inner-substring fallback.** Whisper sometimes "speculatively
            // continues" past a chunk's actual audio end, emitting text the
            // speaker hadn't yet said. The next chunk then transcribes the
            // ACTUAL speech, which starts with the same words but continues
            // beyond. The suffix↔prefix algorithm misses this because the
            // new text's prefix and the prev tail's suffix don't perfectly
            // align (the new text starts at a word that's earlier than the
            // overlap point). The inner-substring fallback handles it.
            let prevContext = recentSegmentTailJoined(
                segments: segments,
                minSeconds: max(overlapSeconds + 1.0, 3.0)
            )
            if !prevContext.isEmpty {
                if let trimmed = Self.trimmedAfterOverlap(
                    prevTail: prevContext,
                    newText: seg.text,
                    maxOverlapWords: maxOverlapWords
                ) {
                    seg.text = trimmed
                } else if let trimmed = Self.trimmedAfterInnerSubstring(
                    prevTail: prevContext,
                    newText: seg.text,
                    maxOverlapWords: maxOverlapWords
                ) {
                    seg.text = trimmed
                }
            }
            // Skip if the entire new segment was an exact duplicate of the previous one.
            if seg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if let last = segments.last, last.text == seg.text,
               abs(last.start - seg.start) < 0.5 {
                continue
            }

            // pickSpeaker uses allSpeakerTurns. In static mode this is empty until the
            // post-extraction whole-file pass — segments get attributed then.
            seg.speaker = pickSpeaker(start: seg.start, end: seg.end)
            if stampAsRaw {
                seg.refinementState = .raw
            }
            segments.append(seg)

            // Multi-pass: stamp wall-clock "raw pass produced output" so the
            // refinement scheduler can honor design §4's "pause if raw hasn't
            // produced for ≥10s." We update on every append rather than only
            // the first per chunk because long quiet stretches between
            // appends inside one chunk should also count as activity.
            if stampAsRaw {
                lastRawProducedAt = Date()
            }

            // Keyword watcher: auto-pin if this segment matches anything the user is
            // watching. Done inside the loop so each appended segment gets exactly
            // one check, and so we use the speaker label we just assigned. In static
            // mode the speaker will be nil here and get re-attributed at end of run;
            // that's fine — pin's `speaker` resolves through engine.displayName(for:)
            // at render time anyway, but the snapshot stored on the pin will lag
            // until the whole-file pass also rewrites pins. (See note in
            // runWholeFileDiarization.)
            checkKeywordsAndAutoPin(segment: seg)
        }
    }

    // MARK: - Refinement scheduler (Phase 4, multi-pass live)

    /// Drives the refined pass. Runs as a single long-lived `Task` for the
    /// session's lifetime, polls the refine buffer, and fires
    /// `performRefinementPass(...)` whenever a full `refineCadenceSeconds`
    /// of new audio has accumulated. Serial: one refinement pass at a time.
    ///
    /// Per design §4:
    ///   - Skip windows rather than queue them up if we fall behind. We
    ///     enforce this implicitly by virtue of being serial: the loop
    ///     only fires a new pass when the previous one has returned. If
    ///     the buffer has grown past one cadence while a pass was running,
    ///     we consume one cadence's worth on the next iteration and the
    ///     remainder waits — but if it has grown past two cadences, the
    ///     intermediate window's audio has been overwritten by trimming.
    ///     "Skip" here means "miss the intermediate window."
    ///   - Pause when raw pass has been silent for ≥10s. We re-check on
    ///     each loop iteration so a resumed stream resumes refinement on
    ///     the next cadence boundary.
    ///   - Stopping the session cancels this task. The current in-flight
    ///     refinement is given a short grace period to complete (see
    ///     `awaitRefinementGrace(timeout:)`) so the user doesn't see a
    ///     half-refined transcript on a clean stop.
    ///
    /// Not in scope (Phase 4):
    ///   - Hard timeout on Whisper inference. Design Q1 calls for "skip
    ///     window if not done in 2× cadence." Because CoreML inference
    ///     isn't cancellable mid-call, the closest we can do is run the
    ///     pass off-thread and check elapsed time on return — which the
    ///     serial-by-construction property already gives us. A truly slow
    ///     pass just delays the next one; it doesn't queue work. If this
    ///     proves insufficient in practice we'll revisit in Phase 7.
    private func runRefinementScheduler() async {
        print("[Refinement] Scheduler started.")
        // Local cache of the engine config we read once per iteration. We
        // re-read on every iteration rather than capturing once, so changes
        // to `@Published var refineWindowSeconds` etc. take effect at the
        // next cadence boundary (Phase 6 will surface these to the user).
        while !Task.isCancelled {
            // Read all the inputs in one hop to MainActor to avoid TOCTOU
            // between checks.
            let (bufferSize, windowSize, cadenceSize, bufferStart, lastRawAge) = await MainActor.run { () -> (Int, Int, Int, TimeInterval, TimeInterval) in
                let bufSize = self.refinePcmBuffer?.count ?? 0
                let win = Int(self.refineWindowSeconds * self.sampleRate)
                // Phase 7: read `activeRefineCadence` (the auto-adjusted
                // value), not the user's raw `refineCadenceSeconds` slider.
                // When the cadence has been bumped up by the adaptive logic,
                // this drains larger chunks per pass to let the refine pass
                // catch up.
                let cad = Int(max(self.activeRefineCadence, self.refineWindowSeconds) * self.sampleRate)
                let bufStart = self.refineBufferStartTime
                let age: TimeInterval
                if let last = self.lastRawProducedAt {
                    age = Date().timeIntervalSince(last)
                } else {
                    age = .infinity  // never produced — treat as "stalled"
                }
                return (bufSize, win, cad, bufStart, age)
            }

            // Pause if raw pass is silent (likely stream stall or audio gap).
            // Design §4: "no point refining silence." 10s threshold from spec.
            // `lastRawAge == .infinity` covers session start before any raw
            // segment has arrived; we don't refine in that early window either.
            if lastRawAge >= 10 {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                continue
            }

            // Wait for enough buffered audio to cover one window.
            if bufferSize < windowSize {
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                continue
            }

            // Phase 7: if the buffer has grown past 2× cadence while we
            // were busy, count the intermediate window(s) we're about to
            // skip past. Each `cadenceSize` worth of audio that gets
            // trimmed without firing inference is a "dropped" window.
            // We only count drops AFTER the first cadence (which is the
            // window we're about to refine, not a drop).
            if bufferSize > windowSize + cadenceSize {
                let extraCadences = (bufferSize - windowSize) / cadenceSize
                if extraCadences > 0 {
                    await MainActor.run {
                        self.refinementStats.windowsDropped += extraCadences
                    }
                    print("[Refinement] Buffer overflow: \(extraCadences) window(s) dropped without refinement (buffer=\(bufferSize / Int(self.sampleRate))s, cadence=\(Int(self.activeRefineCadence))s).")
                }
            }

            // We have a full window. Fire it.
            let windowStartTime = bufferStart
            let windowEndTime = bufferStart + Double(windowSize) / sampleRate
            await performRefinementPass(
                bufferStartTime: windowStartTime,
                windowEndTime: windowEndTime,
                windowSamples: windowSize
            )

            // Advance buffer: drop `cadenceSize` samples off the front. When
            // cadence == window this is "consume the window," which is the
            // common case. When cadence > window we'd skip audio — not
            // currently allowed; we clamp `cadence >= window` above so this
            // collapses to the consume-window case.
            await MainActor.run {
                guard var buf = self.refinePcmBuffer else { return }
                let drop = min(cadenceSize, buf.count)
                buf.removeFirst(drop)
                self.refinePcmBuffer = buf
                self.refineBufferStartTime += Double(drop) / self.sampleRate
            }
        }
        print("[Refinement] Scheduler stopped.")
    }

    /// Phase 7: adaptive cadence policy. Called after every successful
    /// refinement pass (with fresh latency data). Two directions of motion:
    ///
    ///   - **Raise cadence** when refinement is consistently too slow:
    ///     p95 latency over the rolling window exceeds the current active
    ///     cadence, AND we have at least 5 data points (avoid acting on
    ///     noisy startup signals). New cadence = `min(ceiling, p95 * 1.5)`.
    ///     The 1.5× multiplier gives headroom — if p95 is 35s, we go to
    ///     ~52s, not exactly 35s, so a slightly slower next-pass doesn't
    ///     immediately overflow the buffer again.
    ///
    ///   - **Lower cadence** back toward the user's nominal setting when
    ///     p95 has been comfortably below the current cadence (<60%) for
    ///     5+ passes. Decay step is `(active - nominal) / 4`, so we approach
    ///     the floor over several windows rather than snapping back and
    ///     potentially oscillating.
    ///
    /// Ceiling of 240s (4 minutes). Beyond that, refinement is so rare it's
    /// effectively off — the user's better off either disabling refinement
    /// or accepting that the model pair is too slow for their hardware.
    ///
    /// Logs every adjustment so the Debug "Show Stats" snapshot reflects
    /// what actually happened across the session, not just the final value.
    @MainActor
    private func adjustActiveCadenceIfNeeded() {
        let nominal = max(refineCadenceSeconds, refineWindowSeconds)
        let p95 = refinementStats.p95
        let count = refinementStats.latencies.count

        // Need enough samples to make a confident decision. The rolling
        // window caps at 10; we wait for at least 5 before acting.
        guard count >= 5 else { return }

        // Raise: p95 > current cadence means we're consistently missing.
        if p95 > activeRefineCadence {
            let target = min(240.0, p95 * 1.5)
            // Snap to 5s boundaries for log readability — matches the
            // slider's step size in the sidebar.
            let snapped = (target / 5.0).rounded() * 5.0
            if snapped > activeRefineCadence {
                print("[Refinement] Adaptive: raising cadence \(Int(activeRefineCadence))s → \(Int(snapped))s (p95=\(String(format: "%.1f", p95))s).")
                activeRefineCadence = snapped
            }
            return
        }

        // Lower: only when current is above the nominal AND p95 has plenty
        // of headroom. The 0.6 threshold means we don't drift down until
        // the actual latency is well under control — avoids ping-ponging
        // around a marginally-feasible cadence.
        if activeRefineCadence > nominal, p95 < activeRefineCadence * 0.6 {
            let step = (activeRefineCadence - nominal) / 4.0
            let candidate = max(nominal, activeRefineCadence - step)
            let snapped = (candidate / 5.0).rounded() * 5.0
            if snapped < activeRefineCadence {
                print("[Refinement] Adaptive: lowering cadence \(Int(activeRefineCadence))s → \(Int(snapped))s (p95=\(String(format: "%.1f", p95))s, nominal=\(Int(nominal))s).")
                activeRefineCadence = snapped
            }
        }
    }

    /// Execute one refinement pass over the audio in `refinePcmBuffer`
    /// starting at `bufferStartTime`, of length `windowSamples`. Marks
    /// covered raw segments `.pending`, runs refined transcription +
    /// diarization concurrently, builds refined segments with speaker
    /// labels from `dominantSpeakerLabel(start:end:)` (Phase 5 — the
    /// time-weighted Sortformer-as-source-of-truth vote), and applies
    /// block replacement.
    ///
    /// Buffer mutation: this function only *reads* `refinePcmBuffer`. The
    /// scheduler trims the buffer after this returns. We snapshot the window
    /// at the start so a long-running inference call doesn't race against
    /// the audio extractor still appending to the buffer.
    private func performRefinementPass(
        bufferStartTime: TimeInterval,
        windowEndTime: TimeInterval,
        windowSamples: Int
    ) async {
        let passStartedAt = Date()

        // Snapshot the window audio and the refined backends in one MainActor
        // hop. The backend references are stable for the session (built in
        // `rebuildBackends`), but reading them from MainActor matches the
        // pattern used elsewhere and avoids any subtle ordering question.
        let (sampleWindow, refinedTr, refinedDi, diarKind) = await MainActor.run { () -> ([Float], TranscriptionBackend?, DiarizationBackend?, DiarizationEngineKind) in
            let win: [Float]
            if let buf = self.refinePcmBuffer, buf.count >= windowSamples {
                win = Array(buf.prefix(windowSamples))
            } else {
                win = []
            }
            return (win, self.refinedTranscriber, self.refinedDiarizer, self.diarizationEngine)
        }

        guard !sampleWindow.isEmpty, let refinedTr, let refinedDi else {
            print("[Refinement] Skipping window [\(String(format: "%.1f", bufferStartTime))s..\(String(format: "%.1f", windowEndTime))s]: backends missing or buffer short.")
            return
        }

        // Refined pair is loaded once at session start in `runPipeline` and
        // remains resident for the whole session. We used to lazy-load it
        // here, run inference, then `unload()` at the end of this function,
        // on the hypothesis that idle Whisper in memory was slowing Parakeet
        // raw inference 4×. That hypothesis was wrong — the actual slowdown
        // was upstream audio supply throttling, fixed by `streamViaYTDlpPipe`
        // / `downloadViaYTDlp`. With audio arriving fast enough, Parakeet
        // stays comfortably under 1× RTF even with Whisper continuously
        // loaded. Eager-load + keep-resident is simpler, avoids per-window
        // CoreML compile cost, and means there's no model-load work in
        // flight at stop time competing with graceful teardown. The
        // `unload()` methods on the backends are kept for protocol symmetry
        // but no longer called from this path.

        // Mark covered raw segments as .pending so the UI pulses while the
        // refinement runs. Done before kicking off inference so the user
        // sees the transition immediately rather than only at completion.
        // Phase 6: animate this same as `replaceSegments` (150ms easeInOut)
        // so the raw → pending visual change is smooth — the dot starts
        // pulsing rather than abruptly flipping from steady to pulsing.
        // Same `userIsFollowingTranscript` gate so scrolled-away users
        // don't pay for offscreen animation.
        await MainActor.run {
            let mutate = {
                for i in 0..<self.segments.count {
                    let s = self.segments[i]
                    if s.start < windowEndTime && s.end > bufferStartTime,
                       self.segments[i].refinementState == .raw {
                        self.segments[i].refinementState = .pending
                    }
                }
            }
            if self.userIsFollowingTranscript {
                withAnimation(.easeInOut(duration: 0.15)) { mutate() }
            } else {
                mutate()
            }
        }

        // Fire refined transcription + diarization in parallel. Same shape as
        // the Phase 3 concurrent test — refined backends are independent
        // Actor instances, so they run on separate executors and don't
        // serialize against each other. They DO share ANE if both opted into
        // it (design Q5); we accept that and let Phase 7 tune compute units.
        async let refinedTranscriptionResult = refinedTr.transcribe(
            samples: sampleWindow, chunkStartTime: bufferStartTime
        )
        async let refinedDiarizationResult: [SpeakerTurn] = (diarKind != .off
            ? refinedDi.diarize(samples: sampleWindow, chunkStartTime: bufferStartTime)
            : [])

        let refinedSegments: [TranscriptSegment]
        let refinedTurns: [SpeakerTurn]
        do {
            let trResult = try await refinedTranscriptionResult
            refinedTurns = await refinedDiarizationResult
            // Speaker labels (Phase 5 — Sortformer-as-source-of-truth identity,
            // design §7.3.B): each refined segment gets its label from the
            // raw pass's accumulated Sortformer turns via a time-weighted
            // vote (`dominantSpeakerLabel(start:end:)`), not from the refined
            // pass's own diarizer. Rationale: Sortformer maintains streaming
            // state across the whole session, so its labels are
            // identity-stable across windows; refined SpeakerKit's per-window
            // clustering would produce different cluster IDs every 30s, which
            // looks like new speakers appearing.
            //
            // `refinedTurns` (refined SpeakerKit's output) is still computed
            // — kept for the optional boundary-splitting path the design
            // calls for. The current splitter (`splitSegmentAtSpeakerBoundaries`,
            // below) uses Sortformer's accumulated turns instead, since
            // Sortformer's labels are stable across windows where refined
            // SpeakerKit's per-window clustering produces fresh cluster IDs.
            // The refined SpeakerKit output is logged-then-discarded today;
            // a future revision could merge its evidence with Sortformer's.
            //
            // The refinement window range is passed as `excludingRange` so
            // that `dominantSpeakerLabel`'s neighbor-context tiebreaker
            // won't read stale raw labels from within this window when
            // resolving end-of-window UNKNOWNs. Without this, Sortformer's
            // sparse coverage near window edges would let weak raw labels
            // contaminate the neighbor inference and break the "neighbors
            // agree" check that should have rescued continuous-speaker
            // segments from UNKNOWN.
            let refinementWindow = bufferStartTime...windowEndTime
            refinedSegments = await MainActor.run { () -> [TranscriptSegment] in
                // First pass: assign each Whisper segment a dominant speaker
                // label as before. This is the historical behavior.
                let labeled: [TranscriptSegment] = trResult.segments.map { seg in
                    var copy = seg
                    copy.speaker = self.dominantSpeakerLabel(
                        start: seg.start, end: seg.end,
                        excludingRange: refinementWindow
                    )
                    copy.refinementState = .refined
                    return copy
                }

                // Second pass: for any segment whose time range crosses a
                // Sortformer turn boundary (a point where the dominant
                // speaker changes), use word-level timestamps to split the
                // segment at the inter-word gap that brackets the boundary.
                // Each resulting sub-segment then gets its own dominant
                // label, so the half on each side of the handoff is
                // attributed correctly.
                //
                // This is the canonical fix for §7.3.B in MULTI_PASS_DESIGN —
                // previously the dominant-label vote averaged over a mixed-
                // speaker segment and produced the wrong attribution for the
                // minority-speaker portion (typically a brief handoff like
                // "Thank you, Mr. Chairman" tacked onto the previous
                // speaker's longer monologue).
                //
                // The split is skipped (segment is left as the dominant-
                // labeled whole) when:
                //   - The segment has no word timestamps (Whisper sometimes
                //     omits them on short segments)
                //   - No Sortformer boundary falls strictly inside the
                //     segment's time range
                //   - The straddling Sortformer turns are very brief
                //     (<500ms) — likely diarizer noise rather than a real
                //     handoff
                //   - No inter-word gap brackets the boundary cleanly (the
                //     boundary lands in the middle of a word, suggesting
                //     Sortformer's timing is off)
                var out: [TranscriptSegment] = []
                out.reserveCapacity(labeled.count)
                for seg in labeled {
                    let pieces = self.splitSegmentAtSpeakerBoundaries(
                        seg,
                        excludingRange: refinementWindow
                    )
                    out.append(contentsOf: pieces)
                }
                return out
            }
        } catch {
            print("[Refinement] Window [\(String(format: "%.1f", bufferStartTime))s..\(String(format: "%.1f", windowEndTime))s] failed: \(error). Reverting pending segments to raw.")
            // Restore .pending → .raw so the UI stops pulsing. We don't have
            // a "refinement failed" state today; if a window can't be refined
            // we just leave the raw transcript as-is until the next window.
            // Same animation treatment as the raw → pending mutation above
            // so the dot's transition back to steady is smooth.
            await MainActor.run {
                let mutate = {
                    for i in 0..<self.segments.count {
                        if self.segments[i].refinementState == .pending,
                           self.segments[i].start < windowEndTime,
                           self.segments[i].end > bufferStartTime {
                            self.segments[i].refinementState = .raw
                        }
                    }
                }
                if self.userIsFollowingTranscript {
                    withAnimation(.easeInOut(duration: 0.15)) { mutate() }
                } else {
                    mutate()
                }
                // Phase 7: count this in stats. We don't record a latency
                // for failures — the elapsed time is partial (we threw
                // somewhere inside inference) and would skew the rolling
                // window's adaptive decisions.
                self.refinementStats.windowsFailed += 1
            }
            return
        }

        let elapsed = Date().timeIntervalSince(passStartedAt)
        print("[Refinement] Window [\(String(format: "%.1f", bufferStartTime))s..\(String(format: "%.1f", windowEndTime))s] refined in \(String(format: "%.2f", elapsed))s: \(refinedSegments.count) refined seg(s), \(refinedTurns.count) refined turn(s).")

        // Phase 7: record this pass's latency, bump the success counter,
        // and let the adaptive-cadence policy reconsider. All three live
        // on the MainActor since they touch `@Published` state.
        await MainActor.run {
            self.refinementStats.windowsRefined += 1
            self.refinementStats.record(latency: elapsed)
            self.adjustActiveCadenceIfNeeded()
        }

        // Apply block replacement. The Phase 2 primitive already handles
        // segment removal, pin re-anchoring, and keyword re-pinning.
        await MainActor.run {
            self.replaceSegments(in: bufferStartTime...windowEndTime, with: refinedSegments)
        }

        // Refined pair stays loaded for subsequent windows — no per-pass
        // unload. The session-end teardown happens implicitly when the actor
        // instances go out of scope, plus any explicit cleanup we wire into
        // `runPipeline`'s end-of-session path. See the rationale comment near
        // the eager-load block in `runPipeline` for why we landed here.
    }

    /// Cancel the scheduler and give any in-flight refinement a brief grace
    /// period to land its window before we tear down the session. Design §4
    /// cancellation rule: "In-flight refinement pass is allowed to finish if
    /// <2s remaining, otherwise dropped." We can't know inference's remaining
    /// time, so the heuristic is "give it 1.5s, then move on." Bounded
    /// user-visible delay on Stop, while usually catching the final window.
    ///
    /// Caveat: the inner `performRefinementPass` call may still be running
    /// inside an Actor when this returns. CoreML inference is not
    /// cancellable, and our backends don't honor `Task.isCancelled`. So a
    /// truly slow pass will finish in the background after Stop — its
    /// `replaceSegments` call will still land, mutating `segments` on the
    /// MainActor. That's acceptable for now: the user sees a final UI tweak
    /// shortly after Stop, which is honest.
    private func awaitRefinementGrace(timeout: TimeInterval) async {
        guard let task = refinementTask else { return }
        task.cancel()
        // Race the task's completion against the timeout. `await task.value`
        // resolves when the scheduler loop's `while !Task.isCancelled` check
        // exits — typically near-instant once cancelled, unless the loop is
        // currently inside `performRefinementPass`. The bounded sleep keeps
        // Stop responsive even when inference is still grinding.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            }
            // Take whichever finishes first; cancel the loser.
            _ = await group.next()
            group.cancelAll()
        }
        refinementTask = nil
    }

    // MARK: - Block replacement (multi-pass live refinement)

    /// Atomically replace all segments whose time range overlaps `[range.lowerBound,
    /// range.upperBound]` with `refined`. The block-replacement primitive that the
    /// multi-pass refinement scheduler (Phase 4+) calls into when a 30s refinement
    /// window completes. Per `MULTI_PASS_DESIGN.md` §3.4 / §6, this is "option D":
    /// wholesale swap rather than per-segment merge, with pin/keyword stability
    /// handled by a time-range re-anchoring layer (option 6.A).
    ///
    /// Behavior:
    ///   - Segment removal: anything with nonzero temporal overlap with `range`
    ///     (i.e. `seg.start < range.upperBound && seg.end > range.lowerBound`)
    ///     is removed. Strict-containment would leave straddler segments alone
    ///     and produce duplicates with the refined output.
    ///   - Insertion: `refined` segments are inserted (sorted by `start`) at the
    ///     position previously occupied by the removed range, preserving the
    ///     overall time-ordering of `segments`.
    ///   - Pin re-anchor: for each pin whose own time range overlaps the
    ///     replacement range, find the new segment (if any) that now covers
    ///     `pin.start` and update `pin.sourceSegmentID` so clicking the pin
    ///     still scrolls to the right place. If the new segment's text differs
    ///     from the pin's snapshot, update `pin.text` too — users pin meaning,
    ///     not wording (§5.3). Pins with no covering segment after replacement
    ///     keep their snapshotted text and their old (now-orphan) source id;
    ///     they still render in the pin panel, they just can't be scrolled to.
    ///   - Keyword auto-pin: run the existing keyword-watch against each new
    ///     segment. `checkKeywordsAndAutoPin` already guards against
    ///     double-pinning the same source segment, so this won't create
    ///     duplicates for content that was already pinned in raw form.
    ///
    /// Not in scope here:
    ///   - `allSpeakerTurns` is not modified. Cross-pass speaker continuity is
    ///     Phase 5 (§7.3 — Sortformer-label-vote). Refinement output's
    ///     `seg.speaker` is whatever the caller provides.
    ///   - Animation: Phase 6 added a 150ms easeInOut cross-fade wrapping
    ///     the mutation, gated on `userIsFollowingTranscript` so scrolled-
    ///     away users don't pay for offscreen animation work.
    @MainActor
    func replaceSegments(in range: ClosedRange<TimeInterval>,
                         with refined: [TranscriptSegment]) {
        // Phase 6: animate the replacement when the user is following the
        // transcript live; skip the animation when they've scrolled away
        // (design §5.2 "no animation runs — they're not looking at it").
        // 150ms cross-fade from §5.2. The animation transaction wraps every
        // mutation in this method so that SwiftUI batches segment, pin, and
        // keyword changes into one visible swap.
        //
        // Helper that runs `body` inside `withAnimation` when following,
        // bare otherwise. Pulled out so the actual replacement logic
        // doesn't get an extra indent level just to thread the flag.
        let animateIfFollowing: (() -> Void) -> Void = { [following = self.userIsFollowingTranscript] body in
            if following {
                withAnimation(.easeInOut(duration: 0.15)) { body() }
            } else {
                body()
            }
        }

        animateIfFollowing {
            self.replaceSegmentsBody(range: range, refined: refined)
        }
    }

    /// The non-animated mutation core of `replaceSegments`. Exists as a
    /// separate method so the public entry can choose whether to wrap it in
    /// `withAnimation` based on scroll position. Don't call directly — the
    /// public `replaceSegments` is the contract; this is its implementation.
    @MainActor
    private func replaceSegmentsBody(range: ClosedRange<TimeInterval>,
                                     refined: [TranscriptSegment]) {
        let lo = range.lowerBound
        let hi = range.upperBound

        // 1. Identify and remove overlapping segments, recording the insertion
        //    point so the new segments slot in at the right place (preserving
        //    time order, which is the array's load-bearing invariant).
        let overlapping: (TranscriptSegment) -> Bool = { seg in
            seg.start < hi && seg.end > lo
        }
        let removedIDs = Set(segments.filter(overlapping).map(\.id))
        let insertionIndex = segments.firstIndex(where: overlapping)
            ?? segments.firstIndex(where: { $0.start >= lo })
            ?? segments.endIndex

        segments.removeAll(where: { removedIDs.contains($0.id) })

        // 2. Insert refined segments (sorted by start) at the insertion point.
        let sortedRefined = refined.sorted { $0.start < $1.start }
        segments.insert(contentsOf: sortedRefined, at: insertionIndex)

        // 3. Re-anchor pins via time-range mapping (option 6.A). Pins that
        //    didn't overlap the replacement range are completely untouched.
        if !pinnedQuotes.isEmpty {
            pinnedQuotes = pinnedQuotes.map { pin in
                guard pin.start < hi && pin.end > lo else { return pin }
                // Find the new segment that covers the pin's start time. We
                // anchor by start rather than midpoint or end because that's
                // where scroll-to-pin lands the viewport — the user expects
                // the pin to reveal the line that begins what they pinned.
                let covering = sortedRefined.first { $0.start <= pin.start && $0.end > pin.start }
                    ?? sortedRefined.first { $0.start >= pin.start }
                var updated = pin
                if let covering {
                    updated.sourceSegmentID = covering.id
                    // Only rewrite the pin's text when there's exactly one
                    // covering segment AND its content differs. If multiple
                    // refined segments overlap the pin's range, we'd be
                    // arbitrarily picking one — that's a fidelity loss, so we
                    // leave the original text alone.
                    let coveringPinRange = sortedRefined.filter {
                        $0.start < pin.end && $0.end > pin.start
                    }
                    if coveringPinRange.count == 1,
                       coveringPinRange[0].text != pin.text {
                        updated.text = coveringPinRange[0].text
                    }
                }
                return updated
            }
        }

        // 4. Re-run keyword auto-pin against the new segments. The existing
        //    guard in checkKeywordsAndAutoPin (`pinnedQuotes.contains(where:
        //    sourceSegmentID == segment.id)`) prevents double-pinning, and
        //    since the refined segments have fresh ids any prior pin against
        //    the old (now-removed) raw segment won't block matching.
        for seg in sortedRefined {
            checkKeywordsAndAutoPin(segment: seg)
        }

        print("[Refinement] Replaced \(removedIDs.count) segment(s) in [\(String(format: "%.2f", lo))s..\(String(format: "%.2f", hi))s] with \(sortedRefined.count) refined segment(s).")
    }

    // MARK: - Manual speaker reassignment

    /// Manually override the speaker label on a set of segments. Driven by the
    /// transcript pane's right-click context menu when the user wants to fix
    /// a misattributed paragraph (e.g. an UNKNOWN segment that should be
    /// Speaker 1, or a span the diarizer split when it shouldn't have).
    ///
    /// Semantics:
    ///   - `newLabel == nil` clears the segment's speaker (renders without a
    ///     header — equivalent to no-diarizer behavior for those segments).
    ///   - Pass `"UNKNOWN"` or any machine-label string to set it explicitly.
    ///   - The change is local to `segments` and to any matching
    ///     `pinnedQuotes`. We deliberately do NOT touch `allSpeakerTurns`:
    ///     that's Sortformer's ground truth, used as input to future
    ///     refinement-pass label votes. Mutating it from a manual override
    ///     would let one user correction subtly bias subsequent automatic
    ///     decisions, which is surprising. Local override beats retraining.
    ///   - Animated with the same 150ms cross-fade we use for refinement
    ///     swaps. Unlike refinement, we don't gate on
    ///     `userIsFollowingTranscript`: the user just invoked this from a
    ///     context menu, so they're definitionally looking at the result.
    ///
    /// Effect on grouping: `visibleGroups` is computed from `segments` by
    /// `groupedBySpeaker()`. Reassigning the middle of a Speaker-1 group to
    /// Speaker 2 produces three groups out of what was one, automatically —
    /// no extra plumbing needed here.
    ///
    /// No-ops cleanly when `segmentIDs` is empty or every targeted segment
    /// already has the requested label.
    @MainActor
    func reassignSpeaker(segmentIDs: Set<UUID>, to newLabel: String?) {
        guard !segmentIDs.isEmpty else { return }

        // Pre-check whether anything would actually change. Lets the caller
        // bind menu items that re-set the existing label without animating
        // a no-op or logging spurious "reassigned 0 segments" lines.
        let needsChange = segments.contains { seg in
            segmentIDs.contains(seg.id) && seg.speaker != newLabel
        }
        guard needsChange else { return }

        let mutate = {
            var changedCount = 0
            for i in 0..<self.segments.count where segmentIDs.contains(self.segments[i].id) {
                if self.segments[i].speaker != newLabel {
                    self.segments[i].speaker = newLabel
                    changedCount += 1
                }
            }

            // Mirror to pins. Each pin's `sourceSegmentID` is the segment it
            // was anchored to at pin time; if that segment was reassigned,
            // update the pin's `speaker` snapshot to match. The pin's
            // display in the pin panel reads from this field, so without
            // this mirror the panel would show the stale label. Note that
            // `sourceSegmentID` is optional — pins can be source-less (e.g.
            // orphaned after refinement removed their source segment); we
            // only sync when there's an actual link.
            if !self.pinnedQuotes.isEmpty {
                self.pinnedQuotes = self.pinnedQuotes.map { pin in
                    guard let sid = pin.sourceSegmentID, segmentIDs.contains(sid) else { return pin }
                    var updated = pin
                    updated.speaker = newLabel
                    return updated
                }
            }

            let displayLabel = newLabel.map { self.displayName(for: $0) ?? $0 } ?? "(no speaker)"
            print("[Reassign] Set \(changedCount) segment(s) to \(displayLabel).")
        }

        withAnimation(.easeInOut(duration: 0.15)) {
            mutate()
        }
    }

    /// Diagnostic: mark the most recent N segments as `.raw` so the
    /// `RefinementIndicator` UI treatment can be eyeballed without the
    /// refinement pipeline being wired up yet (Phase 4+). Paired with the
    /// "Refine Last 30s (Test)" Debug menu item — call this first to see
    /// the raw treatment appear, then call that to see the swap to refined.
    ///
    /// Previously `#if DEBUG`-only; now available in release because the
    /// Debug menu is opt-in for users via Settings → Advanced.
    @MainActor
    func _debugMarkLastSegmentsAsRaw(count: Int) {
        let cut = max(0, segments.count - count)
        for i in cut..<segments.count {
            segments[i].refinementState = .raw
        }
    }

    // MARK: - Boundary overlap trimming

    /// If `newText` begins with words that match the tail of `prevTail`, return
    /// `newText` with that overlapping prefix removed. Returns `nil` if no overlap is
    /// found, leaving the segment untouched.
    ///
    /// Matching is case-insensitive and ignores punctuation, but preserves whichever
    /// punctuation/casing appears in `newText` for the surviving portion (it tends to
    /// be more correct because it's followed by more context).
    static func trimmedAfterOverlap(prevTail: String, newText: String, maxOverlapWords: Int) -> String? {
        let prevWords = tokenize(prevTail)
        let newWords = tokenize(newText)
        guard !prevWords.isEmpty, !newWords.isEmpty else { return nil }

        // Try the longest possible overlap first, walk down to 1 word.
        let maxK = min(maxOverlapWords, prevWords.count, newWords.count)
        var bestK = 0
        for k in stride(from: maxK, through: 1, by: -1) {
            let prevSuffix = prevWords.suffix(k).map { $0.normalized }
            let newPrefix = newWords.prefix(k).map { $0.normalized }
            if prevSuffix == newPrefix {
                bestK = k
                break
            }
        }
        guard bestK > 0 else { return nil }

        // Drop the first `bestK` tokens from newText, preserving the remainder
        // verbatim (with original casing/punctuation).
        let dropToCharIndex = newWords[bestK - 1].rangeInOriginal.upperBound
        var remainder = String(newText[dropToCharIndex...])
        remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        // If the remainder starts with punctuation orphaned by the trim, strip it.
        while let first = remainder.first, ".,;:!?".contains(first) {
            remainder.removeFirst()
            remainder = remainder.trimmingCharacters(in: .whitespaces)
        }
        return remainder
    }

    /// Concatenate text from the trailing segments covering at least
    /// `minSeconds` of audio time. Used to give the dedup logic a wider
    /// view of recent transcript text so it can catch duplications that
    /// span more than just the last segment.
    ///
    /// The walk is end-to-start: include the last segment unconditionally,
    /// then keep prepending earlier segments until the accumulated time
    /// span (last.end − first.start) hits `minSeconds`. Caller passes a
    /// value sized to the chunk overlap plus a margin (typically
    /// `overlapSeconds + 1.0` with a floor of 3s).
    ///
    /// Joins with single spaces. Order is forward-in-time so the resulting
    /// string reads as it would appear in the transcript, which means
    /// suffix-matching in `trimmedAfterOverlap` still finds the most-recent
    /// duplicated phrase.
    private func recentSegmentTailJoined(segments: [TranscriptSegment],
                                         minSeconds: TimeInterval) -> String {
        guard let last = segments.last else { return "" }
        var collected: [String] = []
        var includedStart = last.end
        for seg in segments.reversed() {
            collected.append(seg.text)
            includedStart = seg.start
            if (last.end - includedStart) >= minSeconds {
                break
            }
        }
        // collected is end→start order; reverse so the joined string
        // reads forward in time.
        return collected.reversed().joined(separator: " ")
    }

    /// Inner-substring dedup. Whisper sometimes hallucinates ahead at the
    /// end of a chunk, emitting words the speaker hasn't said yet. The
    /// next chunk's transcription then contains the ACTUAL utterance,
    /// which begins with those same words but continues correctly. Result:
    /// duplicated phrases where `trimmedAfterOverlap` misses because the
    /// new text's prefix isn't a *suffix* of the previous tail — it's a
    /// substring that appears partway through.
    ///
    /// Detection: take the first K words of newText (for K from a sensible
    /// max down to 4 — fewer than 4 is too short to be a confident match,
    /// and we'd false-positive on common phrases like "I think the"). For
    /// each K, look for an occurrence of those K words inside prevTail's
    /// recent text. If found, drop those K words from newText.
    ///
    /// The 4-word floor prevents trimming legitimate continuations like
    /// "the committee" or "yield back" that happen to appear earlier in
    /// the transcript. 4+ consecutive matching words within the overlap
    /// window is well outside the noise floor for natural conversation.
    static func trimmedAfterInnerSubstring(prevTail: String, newText: String,
                                            maxOverlapWords: Int) -> String? {
        let prevWords = tokenize(prevTail)
        let newWords = tokenize(newText)
        guard !prevWords.isEmpty, !newWords.isEmpty else { return nil }

        let minMatchWords = 4
        let maxK = min(maxOverlapWords, newWords.count, prevWords.count)
        guard maxK >= minMatchWords else { return nil }

        // Pre-normalize prevTail words for fast comparison.
        let prevNormalized = prevWords.map { $0.normalized }

        // Walk K from longest plausible match down to the floor. Return
        // on the first K that matches — longer is better because it
        // removes more duplicated text. (Walking up from the floor would
        // find a short match first and miss the longer overlap.)
        for k in stride(from: maxK, through: minMatchWords, by: -1) {
            let prefix = newWords.prefix(k).map { $0.normalized }
            // Slide the K-word window across prevNormalized looking for a match.
            // i ranges so that the K-word window fits: i + k - 1 < prevNormalized.count.
            if prevNormalized.count < k { continue }
            for i in 0...(prevNormalized.count - k) {
                var matched = true
                for j in 0..<k {
                    if prevNormalized[i + j] != prefix[j] {
                        matched = false
                        break
                    }
                }
                if matched {
                    // Found a K-word occurrence of newText's prefix
                    // somewhere in prevTail. Drop the first K tokens
                    // from newText, preserving the remainder verbatim.
                    let dropToCharIndex = newWords[k - 1].rangeInOriginal.upperBound
                    var remainder = String(newText[dropToCharIndex...])
                    remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
                    while let first = remainder.first, ".,;:!?".contains(first) {
                        remainder.removeFirst()
                        remainder = remainder.trimmingCharacters(in: .whitespaces)
                    }
                    return remainder.isEmpty ? nil : remainder
                }
            }
        }
        return nil
    }

    /// A word token plus its position in the original string, so we can slice the
    /// original back out without losing its punctuation/casing.
    private struct WordToken {
        let normalized: String                          // lowercased, stripped of punctuation
        let rangeInOriginal: Range<String.Index>
    }

    /// Word-tokenize a string. We split on whitespace and strip leading/trailing
    /// punctuation per token. Empty tokens (pure punctuation) are dropped.
    private static func tokenize(_ s: String) -> [WordToken] {
        var tokens: [WordToken] = []
        var i = s.startIndex
        while i < s.endIndex {
            // Skip whitespace
            while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
            guard i < s.endIndex else { break }
            let wordStart = i
            while i < s.endIndex, !s[i].isWhitespace { i = s.index(after: i) }
            let wordEnd = i
            let raw = String(s[wordStart..<wordEnd])
            let normalized = raw
                .lowercased()
                .trimmingCharacters(in: CharacterSet.punctuationCharacters)
            if !normalized.isEmpty {
                tokens.append(WordToken(
                    normalized: normalized,
                    rangeInOriginal: wordStart..<wordEnd
                ))
            }
        }
        return tokens
    }

    /// Choose the speaker with the largest temporal overlap for this text segment.
    @MainActor
    private func pickSpeaker(start: TimeInterval, end: TimeInterval) -> String? {
        guard diarizationEngine != .off, !allSpeakerTurns.isEmpty else { return nil }
        var best: (label: String, overlap: TimeInterval)?
        for t in allSpeakerTurns {
            let ov = t.overlaps(start, end)
            if ov > 0, ov > (best?.overlap ?? 0) {
                best = (t.speaker, ov)
            }
        }
        return best?.label
    }

    /// Phase 5: refined-segment label assignment via time-weighted vote across
    /// the raw pass's accumulated Sortformer turns. Differs from `pickSpeaker`
    /// in three ways that matter for refined segments:
    ///
    ///   1. **Aggregates overlap by label**, rather than picking the single
    ///      turn with maximum overlap. If a segment contains three turns
    ///      A(0–3s) B(3–4s) A(7–10s), `pickSpeaker` picks A by tiebreaker
    ///      (first 3s overlap wins); this method sums A=6s vs B=1s and
    ///      returns A unambiguously. The difference grows when a speaker
    ///      appears in many short turns versus a runner-up's one long turn.
    ///   2. **Near-tie fallback.** Per design §7.3 edge cases, if the
    ///      runner-up's aggregate is within 10% of the winner (i.e. winner's
    ///      lead is small), the label is ambiguous. Originally 20% in
    ///      Phase 5 — tightened to 10% after live-mode testing showed too
    ///      many genuine majority cases were being written off as UNKNOWN
    ///      when Sortformer's per-chunk labels briefly disagreed.
    ///   3. **Empty-overlap fallback.** If no Sortformer turn overlaps the
    ///      segment at all, Phase 5 returned "UNKNOWN" unconditionally. In
    ///      practice this fires often: Sortformer's VAD sometimes misses
    ///      short utterances ("yeah," "right") that Whisper picks up,
    ///      leaving the refined segment with no Sortformer coverage. Phase
    ///      5.5 (this revision) adds a **neighbor-context tiebreaker**
    ///      before falling back to UNKNOWN — when the segment is sandwiched
    ///      between two segments with the same non-UNKNOWN speaker, we
    ///      adopt that speaker. The design's "Sortformer-as-source-of-
    ///      truth" principle still holds; we're just extending it across
    ///      the gap via continuity inference rather than ignoring it.
    ///
    /// `excludingRange` lets refinement-time callers tell the neighbor
    /// inference to ignore segments inside the current refinement window
    /// — those segments are about to be replaced and may carry stale or
    /// briefly-mislabeled speakers from the raw pass. Without this,
    /// neighbor inference reads weak raw labels (e.g. a segment that won
    /// with 0.2s of overlap to a one-off Sortformer cluster ID) as
    /// authoritative, "neighbors disagree," and falls to UNKNOWN. Pass
    /// `nil` from non-refinement paths to preserve the old behavior.
    ///
    /// Telemetry: with DEBUG, logs the full candidate ranking, winner,
    /// runner-up margin, fallback reason, and tiebreaker outcomes. Grep
    /// `[Refinement/Labels]`. Keep this method @MainActor-isolated so it
    /// can read `allSpeakerTurns` and `segments` without a hop.
    @MainActor
    private func dominantSpeakerLabel(start: TimeInterval, end: TimeInterval,
                                      excludingRange: ClosedRange<TimeInterval>? = nil) -> String? {
        // If the user disabled diarization entirely, refined segments don't
        // get labels — same as raw segments. Refined segments lacking a
        // label render as "no speaker" in the UI, matching today's
        // no-diarizer behavior.
        guard diarizationEngine != .off else { return nil }

        // Aggregate overlap per label. Dictionary keys are Sortformer
        // labels ("SPEAKER_00", etc.); values are the total time (seconds)
        // that label dominated within [start, end].
        var byLabel: [String: TimeInterval] = [:]
        for t in allSpeakerTurns {
            let ov = t.overlaps(start, end)
            if ov > 0 {
                byLabel[t.speaker, default: 0] += ov
            }
        }

        // No Sortformer overlap → segment lives in a region where Sortformer
        // produced no turn data. Most common cause in practice: Sortformer's
        // VAD missed a short utterance that Whisper picked up. Try the
        // neighbor-context tiebreaker before giving up.
        guard !byLabel.isEmpty else {
            if let inherited = neighborContextLabel(start: start, end: end, excluding: excludingRange) {
                #if DEBUG
                print("[Refinement/Labels] segment [\(fmt(start))..\(fmt(end))]: no Sortformer overlap → inherited \(inherited) from neighbor context")
                #endif
                return inherited
            }
            #if DEBUG
            print("[Refinement/Labels] segment [\(fmt(start))..\(fmt(end))]: no Sortformer overlap, no usable neighbor context → UNKNOWN")
            #endif
            return "UNKNOWN"
        }

        // Sort labels by aggregate overlap, descending.
        let ranked = byLabel.sorted { $0.value > $1.value }
        let winner = ranked[0]

        // Near-tie detection: if runner-up exists and is within 10% of
        // winner's overlap, the label is ambiguous. Ratio check is
        // `runnerUp / winner > 0.9` — i.e. runner-up has ≥90% of winner's
        // overlap, so winner's lead is <10%. Tightened from Phase 5's
        // original 20% after live-mode testing showed too many false
        // positives. As with empty-overlap, try neighbor context before
        // giving up to UNKNOWN.
        if ranked.count >= 2 {
            let runnerUp = ranked[1]
            let ratio = runnerUp.value / winner.value
            if ratio > 0.9 {
                if let inherited = neighborContextLabel(start: start, end: end, excluding: excludingRange) {
                    #if DEBUG
                    let ranking = ranked.map { "\($0.key)=\(fmt($0.value))s" }.joined(separator: " ")
                    print("[Refinement/Labels] segment [\(fmt(start))..\(fmt(end))]: near-tie (margin \(String(format: "%.0f", (1.0 - ratio) * 100))% < 10%) → inherited \(inherited) from neighbor context; ranking: \(ranking)")
                    #endif
                    return inherited
                }
                #if DEBUG
                let ranking = ranked.map { "\($0.key)=\(fmt($0.value))s" }.joined(separator: " ")
                print("[Refinement/Labels] segment [\(fmt(start))..\(fmt(end))]: near-tie (margin \(String(format: "%.0f", (1.0 - ratio) * 100))% < 10%), no usable neighbor context → UNKNOWN; ranking: \(ranking)")
                #endif
                return "UNKNOWN"
            }
        }

        #if DEBUG
        let ranking = ranked.map { "\($0.key)=\(fmt($0.value))s" }.joined(separator: " ")
        let margin: String
        if ranked.count >= 2 {
            let pct = (1.0 - ranked[1].value / winner.value) * 100
            margin = "margin \(String(format: "%.0f", pct))%"
        } else {
            margin = "uncontested"
        }
        print("[Refinement/Labels] segment [\(fmt(start))..\(fmt(end))]: \(winner.key) wins (\(margin)); ranking: \(ranking)")
        #endif

        return winner.key
    }

    /// Phase 5.5: look at the existing transcript's segments immediately
    /// before and after `[start, end]`, and return a speaker label inferred
    /// from continuity. Three cases:
    ///   - Both `before` and `after` exist and agree → that label.
    ///   - Only `before` exists (no informative `after` yet) → `before`.
    ///     This is the common end-of-refinement-window case during
    ///     streaming: refinement fires the moment 30s of audio has
    ///     accumulated, so segments past the window-end don't exist in
    ///     `segments` yet. Accepting `before` alone here is a deliberate
    ///     bias toward "the past is settled, the future is incomplete" —
    ///     better to inherit from the segment immediately before than to
    ///     fall through to UNKNOWN. The risk: if the audio past the
    ///     window-end is actually a different speaker (genuine turn change
    ///     coinciding with the window boundary), we misattribute the
    ///     last 1–5 seconds. Acceptable trade-off vs. UNKNOWN's certain
    ///     wrongness, especially for monologue content.
    ///   - Both exist and disagree → nil. We can't tell which to trust.
    ///   - No `before` → nil. No evidence at all.
    ///
    /// "Immediately before" = the closest segment whose `end <= start`.
    /// "Immediately after" = the closest segment whose `start >= end`.
    /// Segments that overlap `[start, end]` (e.g. older `.raw` segments in
    /// the same refinement window) are deliberately skipped — they're
    /// about to be replaced and shouldn't influence the new label.
    ///
    /// `excluding` extends that "skip overlapping" idea to the *whole
    /// refinement window* rather than just this specific segment. Without
    /// it, neighbor inference can land on a stale raw segment from elsewhere
    /// in the same window whose speaker was set via raw's `pickSpeaker`
    /// against weak Sortformer data (e.g. a 0.2s overlap on a 1.4s segment
    /// near a window edge). Those weak labels are about to be replaced and
    /// shouldn't anchor decisions about their successors. Pass `nil` from
    /// non-refinement paths to keep today's behavior.
    ///
    /// Earlier revisions required *unanimous* before+after agreement before
    /// returning a label. That correctly handled mid-stream speaker-change
    /// boundaries but failed at end-of-window during streaming: the after
    /// segments simply hadn't been transcribed yet, so the unanimous check
    /// fell through and refined segments at window edges with weak Sortformer
    /// coverage all came out UNKNOWN. The diagnosis (via the `[Refinement/
    /// Neighbors]` log telemetry below) made the timing clear: refinement
    /// keeps up with real-time audio, so "audio past window-end" doesn't
    /// exist in `segments` when neighbor inference runs.
    @MainActor
    private func neighborContextLabel(start: TimeInterval, end: TimeInterval,
                                      excluding: ClosedRange<TimeInterval>? = nil) -> String? {
        // Helper: does this segment overlap the excluded window? Returns
        // false when `excluding` is nil (no window to skip), so the
        // raw-path callers and tests behave identically to before this
        // parameter was added.
        let inExcluded: (TranscriptSegment) -> Bool = { seg in
            guard let r = excluding else { return false }
            return seg.start < r.upperBound && seg.end > r.lowerBound
        }

        // Find the nearest segment strictly before `start` whose speaker is
        // an actual label (not nil, not UNKNOWN, not inside the excluded
        // window). Scan in reverse since segments is time-ordered.
        var before: String?
        for seg in segments.reversed() {
            guard seg.end <= start else { continue }
            if inExcluded(seg) { continue }
            if let label = seg.speaker, label != "UNKNOWN" {
                before = label
                break
            }
            // Hit a segment with no label or UNKNOWN — keep looking past
            // it. We want the nearest *informative* neighbor, not just the
            // nearest neighbor.
        }
        guard let before else {
            #if DEBUG
            print("[Refinement/Neighbors] [\(fmt(start))..\(fmt(end))]: no informative `before` neighbor")
            #endif
            return nil
        }

        // Same logic for the segment after.
        var after: String?
        for seg in segments {
            guard seg.start >= end else { continue }
            if inExcluded(seg) { continue }
            if let label = seg.speaker, label != "UNKNOWN" {
                after = label
                break
            }
        }
        guard let after else {
            // Option X (after diagnosis confirmed the timing race): no
            // informative after-neighbor is the *common* end-of-window
            // case during real-time streaming, not an error condition.
            // Refinement fires the moment 30s of audio accumulates; no
            // segments past the window end exist yet. Accept `before`
            // alone rather than fall through to UNKNOWN.
            #if DEBUG
            print("[Refinement/Neighbors] [\(fmt(start))..\(fmt(end))]: before=\(before), no `after` → inheriting from `before`")
            #endif
            return before
        }

        if before != after {
            #if DEBUG
            print("[Refinement/Neighbors] [\(fmt(start))..\(fmt(end))]: before=\(before), after=\(after) — disagree")
            #endif
            return nil
        }
        return before
    }

    // MARK: - Sortformer boundary correction (snap to silence)

    /// Snap Sortformer/SpeakerKit turn boundaries backward to the
    /// nearest inter-word silence gap.
    ///
    /// **The problem.** Neural streaming diarizers (Sortformer,
    /// pyannote streaming variants, etc.) are systematically LATE at
    /// marking speaker handoffs — typically by 0.5-2.5 seconds. This
    /// is structural to streaming architectures: the model has to
    /// "hear" enough of the new voice for its embedding to cross the
    /// decision threshold, which takes audio. The lag is remarkably
    /// consistent because it's bounded by buffer length + context
    /// window, not by acoustic noise.
    ///
    /// **The fix.** Real conversational handoffs happen across
    /// silence — even fast back-and-forth has a brief gap between
    /// speakers, and longer handoffs have clear pauses. Whisper's
    /// word-level timestamps reveal these silences as gaps between
    /// `word[i].end` and `word[i+1].start`. For each Sortformer
    /// boundary, search backwards through the words for the largest
    /// gap inside a `lookbackWindow`, and if it's at least
    /// `minGapForSnap` long, set the boundary to the midpoint of
    /// that gap.
    ///
    /// **Why snap-to-silence beats a constant offset.** The lag
    /// varies with handoff length: a short interjection lags ~0.3s,
    /// a long monologue ~2s. A global shift over-corrects some and
    /// under-corrects others. Snapping to the actual silence the
    /// speakers produced removes that variance — wherever Sortformer
    /// placed the boundary, we walk back to where the audio shows
    /// the real handoff.
    ///
    /// **Safety properties.**
    /// - Boundaries are processed left-to-right and tracked as
    ///   `prevBoundary` — a snap can never push the current boundary
    ///   before the previous one.
    /// - Each turn is guaranteed to stay at least `minTurnDuration`
    ///   long (both sides of the boundary). Pathological cases
    ///   degrade to "no snap" rather than producing zero-length
    ///   turns.
    /// - If no qualifying gap exists in the lookback window, the
    ///   boundary stays where Sortformer put it. We don't fabricate.
    /// - Only handoff boundaries (turn[i].speaker != turn[i+1].speaker)
    ///   are considered; same-speaker turn endpoints (Sortformer
    ///   sometimes emits these as a single speaker's contiguous
    ///   stretch broken into chunks) are left untouched.
    ///
    /// **Logged as `[Refinement/SnapBoundary]`** so adjustments are
    /// auditable. Each log line includes the original time, snapped
    /// time, and delta — useful when tuning thresholds against a
    /// specific transcript.
    @MainActor
    private func snapSortformerBoundariesToSilence(
        _ turns: [SpeakerTurn],
        allSegments: [TranscriptSegment]
    ) -> [SpeakerTurn] {
        guard turns.count >= 2 else { return turns }

        // Tunable thresholds. Defaults chosen from observed behavior
        // on broadcast/podcast/legislative-hearing audio:
        //
        //   lookbackWindow: 2.5s covers Sortformer's typical worst-
        //     case delay. Going longer risks snapping to silence
        //     that's BEFORE the actual handoff (a within-speaker
        //     pause earlier in their utterance).
        //
        //   minGapForSnap: 180ms. Real silences in conversation are
        //     200-400ms+; intra-word gaps in fluent speech are
        //     50-150ms. 180ms is a clean separator.
        //
        //   minTurnDuration: 300ms. Below this, a "turn" is more
        //     likely a Sortformer artifact than a real utterance.
        let lookbackWindow: TimeInterval = 2.5
        let minGapForSnap: TimeInterval = 0.18
        let minTurnDuration: TimeInterval = 0.3

        // Build a chronologically sorted list of inter-word silence
        // gaps from all segments' word timestamps. Each gap is
        // represented by its midpoint (the time we'd snap to) and its
        // size (used to pick the LARGEST gap in a contested window,
        // since larger gaps are more confidently real handoffs).
        struct Gap {
            let mid: TimeInterval
            let size: TimeInterval
        }
        var gaps: [Gap] = []
        var lastWordEnd: TimeInterval? = nil
        // Sort segments by start time to ensure word stream is
        // chronological. Segments are normally already in order, but
        // a re-attribute pass can disturb this.
        for seg in allSegments.sorted(by: { $0.start < $1.start }) {
            guard let words = seg.words else { continue }
            for w in words {
                if let prev = lastWordEnd {
                    let gapSize = w.start - prev
                    if gapSize >= minGapForSnap {
                        gaps.append(Gap(mid: (prev + w.start) / 2.0,
                                        size: gapSize))
                    }
                }
                lastWordEnd = w.end
            }
        }
        guard !gaps.isEmpty else {
            print("[Refinement/SnapBoundary] no qualifying gaps in word timestamps; skipping snap pass")
            return turns
        }

        var result = turns
        var prevBoundary: TimeInterval = -.infinity
        var snapCount = 0

        for i in 0..<(result.count - 1) {
            // Only snap real handoffs. Same-speaker adjacent turns
            // (Sortformer occasionally emits these as chunked output)
            // don't need correction — their boundary isn't a handoff.
            guard result[i].speaker != result[i + 1].speaker else {
                prevBoundary = max(prevBoundary, result[i].end)
                continue
            }

            let origBoundary = result[i].end

            // Window to search for a snap target. Lower bound is the
            // later of (boundary - lookbackWindow) and (prevBoundary
            // + minTurnDuration) so we never cross into the previous
            // turn.
            let windowStart = max(origBoundary - lookbackWindow,
                                  prevBoundary + minTurnDuration)
            guard windowStart < origBoundary else {
                prevBoundary = origBoundary
                continue
            }

            // Pick the LARGEST gap in [windowStart, origBoundary].
            // Largest gap, not nearest — larger silences are more
            // confidently real handoffs. Two candidates of similar
            // size are uncommon; if it happens, the later one wins
            // via the natural ordering of the array.
            var best: Gap? = nil
            for g in gaps {
                guard g.mid >= windowStart, g.mid <= origBoundary else { continue }
                if best == nil || g.size > best!.size {
                    best = g
                }
            }
            guard let bestGap = best else {
                prevBoundary = origBoundary
                continue
            }

            // Clamp the snap so neither turn shrinks below
            // minTurnDuration. The current turn's start is
            // result[i].start; the next turn's end is result[i+1].end.
            // The snapped boundary must sit at least minTurnDuration
            // inside both.
            let minSnap = max(prevBoundary + minTurnDuration,
                              result[i].start + minTurnDuration)
            let maxSnap = result[i + 1].end - minTurnDuration
            let clamped = max(minSnap, min(bestGap.mid, maxSnap))

            // Only apply the snap if it meaningfully moves the
            // boundary earlier. 50ms threshold avoids logging noise
            // when the existing boundary already happens to coincide
            // with a silence gap.
            if clamped < origBoundary - 0.05 {
                let delta = origBoundary - clamped
                print(String(format: "[Refinement/SnapBoundary] %@ → %@: %.2fs → %.2fs (back %.2fs, gap %.2fs)",
                             result[i].speaker, result[i + 1].speaker,
                             origBoundary, clamped, delta, bestGap.size))
                result[i] = SpeakerTurn(speaker: result[i].speaker,
                                        start: result[i].start,
                                        end: clamped)
                result[i + 1] = SpeakerTurn(speaker: result[i + 1].speaker,
                                            start: clamped,
                                            end: result[i + 1].end)
                prevBoundary = clamped
                snapCount += 1
            } else {
                prevBoundary = origBoundary
            }
        }

        if snapCount > 0 {
            print("[Refinement/SnapBoundary] snapped \(snapCount)/\(result.count - 1) boundaries to inter-word silence")
        }
        return result
    }

    /// Tiny formatter for the telemetry strings above. Pulled out so the log
    /// lines stay readable. One decimal place is plenty for human reading.
    private func fmt(_ t: TimeInterval) -> String {
        String(format: "%.1f", t)
    }

    /// Phase 5b: split a refined segment at internal Sortformer speaker
    /// boundaries so a single Whisper segment that straddles a handoff
    /// doesn't get its trailing portion mislabeled with the leading
    /// speaker's identity.
    ///
    /// The historical behavior (kept as a fallback below) was
    /// `dominantSpeakerLabel` — winner of a time-weighted vote across the
    /// segment's range. When the segment range covers two speakers'
    /// utterances ("...the rest of my time. Thank you, Mr. Chairman.") the
    /// vote averages over both and picks the majority. The minority
    /// portion's text reads as the majority's speech. This is the bug
    /// we've been seeing at Senate hearing handoffs.
    ///
    /// The fix: when WhisperKit gave us word-level timestamps AND a
    /// Sortformer boundary falls strictly inside the segment, find the
    /// inter-word gap that brackets the boundary and split the segment
    /// there. Each resulting sub-segment gets its own dominant label via
    /// `dominantSpeakerLabel`, which over a shorter range will correctly
    /// identify the dominant speaker for that piece alone.
    ///
    /// Returns 1+ segments. Returns `[seg]` unchanged when:
    ///   - The segment lacks word timestamps (Whisper didn't emit them
    ///     for this segment — common on short segments at chunk edges).
    ///   - No Sortformer boundary falls strictly inside `(seg.start, seg.end)`.
    ///   - All candidate boundaries land in turns shorter than 500ms
    ///     (likely Sortformer noise rather than real handoffs).
    ///   - No inter-word gap brackets a candidate boundary (the boundary
    ///     would fall in the middle of a word — Sortformer's timing is
    ///     ahead/behind of Whisper's, can't split cleanly).
    ///
    /// Recursive: after splitting once, each piece is rechecked for
    /// additional boundaries. Capped at 4 recursion levels (5 speakers in
    /// a 30-second segment is already pathological; deeper would be
    /// runaway).
    ///
    /// `excludingRange` is forwarded to `dominantSpeakerLabel` so the
    /// neighbor-context tiebreaker continues to ignore stale raw labels
    /// inside the current refinement window.
    @MainActor
    private func splitSegmentAtSpeakerBoundaries(
        _ seg: TranscriptSegment,
        excludingRange: ClosedRange<TimeInterval>?,
        depth: Int = 0
    ) -> [TranscriptSegment] {
        // Depth bound. 4 splits = 5 segments max from one Whisper segment.
        // Beyond that we're chasing noise rather than real speakers.
        guard depth < 4 else { return [seg] }

        // Need word timestamps to choose a clean cut point. Without them
        // we can't pick a sensible textual cut — splitting time-
        // proportionally would slice through words and produce gibberish
        // sub-segment text.
        //
        // Require at least TWO words. The splitter cuts *between* words,
        // so a single-word segment has no internal boundary to cut at —
        // there's no way to produce a non-empty left and right side.
        // (A lone long word can occasionally overlap a speaker-boundary
        // candidate; without this floor the fallback loop below evaluates
        // `1..<(words.count - 1)` == `1..<0`, an invalid Range that traps
        // at runtime.) Bailing keeps the segment's existing attribution,
        // which is the only sane outcome for an unsplittable single word.
        guard let words = seg.words, words.count >= 2 else { return [seg] }

        // Find Sortformer boundaries strictly inside the segment. A
        // boundary exists between `turns[i]` and `turns[i+1]` when their
        // speakers differ; its time is the endpoint of `turns[i]` (= start
        // of `turns[i+1]`). We require both turns to be ≥0.5s; shorter
        // turns are typically Sortformer artifacts (one-frame label
        // flickers) rather than genuine speaker changes worth splitting on.
        struct Candidate {
            let time: TimeInterval
            let leftDuration: TimeInterval
            let rightDuration: TimeInterval
        }
        let minTurnSeconds: TimeInterval = 0.5

        var candidates: [Candidate] = []
        if !allSpeakerTurns.isEmpty {
            // Sort defensively — `allSpeakerTurns` is accumulated chunk by
            // chunk and is generally already ordered, but a refined-pass
            // re-attribution pass may have re-inserted out of order in
            // edge cases.
            let turns = allSpeakerTurns.sorted { $0.start < $1.start }
            for i in 0..<(turns.count - 1) {
                let a = turns[i]
                let b = turns[i + 1]
                guard a.speaker != b.speaker else { continue }
                let boundary = a.end
                // Strictly inside the segment.
                guard boundary > seg.start, boundary < seg.end else { continue }
                let aDur = a.end - a.start
                let bDur = b.end - b.start
                guard aDur >= minTurnSeconds, bDur >= minTurnSeconds else { continue }
                candidates.append(Candidate(time: boundary,
                                            leftDuration: aDur,
                                            rightDuration: bDur))
            }
        }

        guard !candidates.isEmpty else { return [seg] }

        // Pick the boundary closest to the midpoint of the segment — when
        // multiple candidates exist, we want the one most likely to be a
        // "real" handoff rather than a transient label flicker near the
        // edges of the segment. Subsequent recursion handles the others.
        let segMid = (seg.start + seg.end) / 2.0
        let best = candidates.min { abs($0.time - segMid) < abs($1.time - segMid) }!

        // Find the inter-word gap that brackets the boundary time. A "gap"
        // is the interval between word[i].end and word[i+1].start. We pick
        // the gap whose midpoint is closest to the boundary, requiring the
        // boundary to actually fall within the gap (boundary >= word[i].end
        // AND boundary <= word[i+1].start). When no gap brackets the
        // boundary cleanly (i.e., the boundary is in the middle of a word
        // — Sortformer and Whisper timing disagree), we fall back to "cut
        // after the word whose end is closest to the boundary."
        var cutAfterIndex: Int? = nil
        for i in 0..<(words.count - 1) {
            let wEnd = words[i].end
            let nextStart = words[i + 1].start
            if best.time >= wEnd, best.time <= nextStart {
                cutAfterIndex = i
                break
            }
        }
        // Fallback: closest word-end. Implemented via Range.min(by:)
        // rather than a hand-rolled `for i in 1..<(words.count - 1)`
        // loop. The hand-rolled version is a known Swift footgun: when
        // words.count == 1, the bound becomes `1..<0`, an invalid Range
        // that traps with "Range requires lowerBound <= upperBound".
        // The guard above already prevents that, but having the loop
        // be inherently safe means a future edit that weakens the
        // guard can't reintroduce the crash. Range.min returns nil on
        // an empty range; cutAfterIndex stays nil and the subsequent
        // bounds-check guard returns [seg] cleanly.
        if cutAfterIndex == nil {
            cutAfterIndex = (0..<(words.count - 1)).min(by: {
                abs(words[$0].end - best.time) < abs(words[$1].end - best.time)
            })
        }

        guard let idx = cutAfterIndex,
              idx >= 0, idx < words.count - 1 else {
            return [seg]
        }

        // Build the two pieces. Use the actual word boundaries as the
        // split-time; segment-level start/end stay anchored to Whisper's
        // original boundaries on the outer edges so we don't move the
        // segment relative to the timeline.
        let leftWords = Array(words[0...idx])
        let rightWords = Array(words[(idx + 1)...])
        guard !leftWords.isEmpty, !rightWords.isEmpty else { return [seg] }

        let leftEnd = leftWords.last!.end
        let rightStart = rightWords.first!.start

        let leftText = leftWords.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rightText = rightWords.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Don't emit empty-text pieces — that can happen if the entire
        // left or right side is whitespace-only after trimming (rare, but
        // possible with model artifact tokens). Fall back to the original.
        guard !leftText.isEmpty, !rightText.isEmpty else { return [seg] }

        var left = TranscriptSegment(
            text: leftText,
            start: seg.start,
            end: leftEnd,
            speaker: nil,
            isFinalized: seg.isFinalized,
            refinementState: .refined,
            words: leftWords
        )
        var right = TranscriptSegment(
            text: rightText,
            start: rightStart,
            end: seg.end,
            speaker: nil,
            isFinalized: seg.isFinalized,
            refinementState: .refined,
            words: rightWords
        )

        // Recompute dominant labels for each piece independently. Over the
        // shorter range, the vote will favor the actual speaker for that
        // piece rather than the majority-of-both.
        left.speaker = dominantSpeakerLabel(start: left.start, end: left.end,
                                            excludingRange: excludingRange)
        right.speaker = dominantSpeakerLabel(start: right.start, end: right.end,
                                             excludingRange: excludingRange)

        // If the split didn't change anything (both pieces got the same
        // label as the original, OR labels couldn't be assigned), the
        // split was wasted work. Return the original to avoid producing
        // segment boundaries that don't correspond to a real change.
        if left.speaker == seg.speaker && right.speaker == seg.speaker {
            return [seg]
        }

        print("[Refinement/Split] segment [\(fmt(seg.start))..\(fmt(seg.end))] '\(seg.speaker ?? "nil")' → split at \(fmt(leftEnd))s/\(fmt(rightStart))s → '\(left.speaker ?? "nil")' + '\(right.speaker ?? "nil")'")

        // Recurse on each piece — a 30s segment with three speakers should
        // split into three pieces, which means the right half of the first
        // split itself contains a boundary to split.
        let leftPieces = splitSegmentAtSpeakerBoundaries(
            left, excludingRange: excludingRange, depth: depth + 1
        )
        let rightPieces = splitSegmentAtSpeakerBoundaries(
            right, excludingRange: excludingRange, depth: depth + 1
        )
        return leftPieces + rightPieces
    }

    /// Post-split reabsorb: re-merge short trailing fragments where the
    /// splitter (or diarizer) put the previous speaker's tail-end words
    /// onto the next speaker's segment.
    ///
    /// **The pattern.** SpeakerKit/Sortformer turn boundaries mark
    /// *when the new speaker dominated the audio*, not when the previous
    /// speaker physically stopped. In natural conversation those two
    /// moments don't align — the previous speaker often finishes a
    /// word or short phrase (~200-500ms) AFTER the diarizer has
    /// crossed over to the new speaker. Our splitter cuts at the
    /// diarizer's boundary, so the trailing word ends up on the wrong
    /// side. Two shapes are common:
    ///
    /// *Bracket:* Speaker 3 → Speaker 2 ("the red tape.") → Speaker 3.
    /// Speaker 2 "interjects" for one short fragment, then Speaker 3
    /// resumes. The bracket itself is strong evidence of leakage.
    ///
    /// *Continuation:* Speaker 4 → Speaker 5 ("delivers consumer
    /// value.") → Speaker 5. Speaker 4's last words got attributed to
    /// Speaker 5, appearing as a short fragment before Speaker 5's
    /// real content. No bracket — but the time-adjacency and
    /// sentence-completion shape still flag it.
    ///
    /// Both shapes are handled in `shouldReabsorbFragment`, which
    /// also applies tighter constraints for the riskier continuation
    /// pattern. When matched, B's text folds into A and B is dropped.
    ///
    /// The continuation pattern can technically fold real short turns
    /// (Speaker 3 "Yes." followed by Speaker 3 continuing). In
    /// practice this is rare because a real speaker rarely pauses
    /// after a one-word answer and immediately continues — the
    /// natural rhythm includes a longer beat. The 0.5s gap cap on
    /// continuation matches catches this.
    ///
    /// Logs each reabsorb under `[Refinement/Reabsorb]` so the
    /// behavior is auditable when diagnosing later issues.
    @MainActor
    private func reabsorbTinyTrailingFragments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard segments.count >= 3 else { return segments }

        // Build the result by walking once and merging where either
        // pattern (bracket or continuation) holds. Use index-based
        // iteration so we can skip the absorbed middle segment cleanly.
        var out: [TranscriptSegment] = []
        out.reserveCapacity(segments.count)

        var i = 0
        while i < segments.count {
            // Need three segments to check the bracket pattern.
            if i + 2 < segments.count {
                let a = segments[i]
                let b = segments[i + 1]
                let c = segments[i + 2]

                if shouldReabsorbFragment(previous: a, fragment: b, following: c) {
                    // Merge B's text into A, keep A's speaker and timing
                    // (extended to include B's end so the timeline stays
                    // contiguous; A's text now spans up through B's
                    // trailing punctuation). Drop B. Continue with C as
                    // the next candidate-previous on the next iteration.
                    var merged = a
                    merged.text = mergedTextWithFragment(previous: a.text, fragment: b.text)
                    merged.end = b.end
                    print("[Refinement/Reabsorb] folding [\(fmt(b.start))..\(fmt(b.end))] '\(b.speaker ?? "nil")' \"\(b.text)\" into [\(fmt(a.start))..\(fmt(a.end))] '\(a.speaker ?? "nil")'")
                    out.append(merged)
                    // Skip B (already absorbed). C becomes the new
                    // "previous" candidate for the NEXT iteration's
                    // triple-check — handled implicitly by jumping
                    // to i+2 so the next iteration considers (C, D, E).
                    i += 2
                    continue
                }
            }
            out.append(segments[i])
            i += 1
        }

        return out
    }

    /// Predicate for `reabsorbTinyTrailingFragments`. Pulled out so the
    /// merge loop reads cleanly and the heuristic thresholds are easy
    /// to find when tuning.
    ///
    /// Two distinct patterns fold a fragment B back into the previous
    /// segment A:
    ///
    /// **Bracket pattern: A.speaker == C.speaker, B.speaker differs.**
    /// Looks like: Speaker 3 → Speaker 2 ("the red tape.") → Speaker 3.
    /// Speaker 2 "interjects" for one short fragment ending in a
    /// period, then Speaker 3 resumes. Almost certainly leakage — a
    /// real interjection from Speaker 2 would normally launch a
    /// sustained turn, not vanish in four words while Speaker 3 picks
    /// up mid-thought.
    ///
    /// **Continuation pattern: B.speaker == C.speaker, A.speaker differs.**
    /// Looks like: Speaker 4 → Speaker 5 ("delivers consumer value.") →
    /// Speaker 5 ("Mr. Peeler?..."). The diarizer crossed over from
    /// Speaker 4 a bit early, so Speaker 4's last words were attributed
    /// to Speaker 5, where they appear as a short fragment that
    /// reads as Speaker 4's sentence completion. This pattern is more
    /// permissive than the bracket case — it needs a tighter A→B
    /// time gap (≤0.5s) and a small max length to avoid folding real
    /// short turns that get echoed by the next speaker (e.g., "Yes."
    /// followed by Speaker 2 continuing — Speaker 2 wouldn't normally
    /// pause and immediately continue after their own "Yes.").
    ///
    /// Both patterns require the same fragment-shape filters: short,
    /// ends in terminal punctuation, time-adjacent to A.
    private func shouldReabsorbFragment(
        previous a: TranscriptSegment,
        fragment b: TranscriptSegment,
        following c: TranscriptSegment
    ) -> Bool {
        // Speaker labels must all be present. Without them, neither
        // pattern can be verified.
        guard let aSpeaker = a.speaker,
              let bSpeaker = b.speaker,
              let cSpeaker = c.speaker else { return false }

        // B must be different from A — if they already match, the
        // splitter didn't separate them and there's no leakage to
        // reabsorb (or the speaker was already corrected upstream).
        guard bSpeaker != aSpeaker else { return false }

        // Decide which pattern (if any) applies. Both patterns share
        // the fragment-shape constraints below, but the time-gap
        // tolerance differs because the continuation pattern is
        // more aggressive and needs tighter time-adjacency to be safe.
        let isBracket = aSpeaker == cSpeaker  // A=C=Speaker X, B=Speaker Y
        let isContinuation = bSpeaker == cSpeaker  // A=Speaker X, B=C=Speaker Y
        guard isBracket || isContinuation else { return false }

        // Fragment shape (shared between patterns):
        //   - Short: leakage is typically 1-4 words ("the red tape.",
        //     "delivers consumer value.", "well."). Cap at 4 words
        //     OR 20 chars (covers "well." and similar short trailers
        //     that might be a single longer word).
        let trimmed = b.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        guard wordCount <= 4 || trimmed.count <= 20 else { return false }

        //   - Sentence-completion signal: ends with terminal
        //     punctuation. Whisper's punctuation reliably marks the
        //     end of a phrase, and a fragment that ends mid-thought
        //     (no terminal punctuation) is more likely to be a real
        //     start of a turn rather than a trailing-word leak.
        guard let lastChar = trimmed.last else { return false }
        let terminalPunctuation: Set<Character> = [".", "?", "!"]
        let endsWithTerminal = terminalPunctuation.contains(lastChar)
            || trimmed.hasSuffix("…")
            || trimmed.hasSuffix("...")
        guard endsWithTerminal else { return false }

        //   - Time gap A→B: B must be immediately after A. A large
        //     gap means there was silence or other speech between
        //     them; whatever B is, it's not A's tail.
        let gapAtoB = b.start - a.end
        // The bracket pattern is the safer one (the bracket itself
        // is strong evidence of leakage), so it gets a more forgiving
        // 1.0s tolerance. The continuation pattern is more aggressive
        // and could fold real short turns if the gap is anything but
        // immediate; require ≤0.5s.
        let maxGap = isBracket ? 1.0 : 0.5
        guard gapAtoB <= maxGap else { return false }

        return true
    }

    /// Combine the previous segment's text with the trailing fragment,
    /// handling whitespace and orphaned punctuation cleanly.
    ///
    /// The previous segment's text may end with a trailing space, no
    /// space, or even a punctuation mark we want to demote (a comma
    /// where the speaker's actual end-of-sentence period now follows).
    /// We strip any trailing whitespace from A, then if A doesn't end
    /// in a space, insert one before B's text. Drop A's trailing
    /// punctuation only if B starts with terminal punctuation —
    /// otherwise we'd lose a meaningful pause inside the merged line.
    private func mergedTextWithFragment(previous: String, fragment: String) -> String {
        var left = previous
        while let last = left.last, last.isWhitespace {
            left.removeLast()
        }
        let right = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !right.isEmpty else { return left }
        guard !left.isEmpty else { return right }
        return "\(left) \(right)"
    }

    // MARK: - De-shout (runaway ALL-CAPS recasing)

    /// Token classification for the de-shout pass.
    private enum CapsClass {
        /// 2+ letters, uppercase letters ≥ lowercase letters. The
        /// runaway-caps signal. "WEEKEND", "OMAN", and degraded mixed
        /// tokens like "BEen" (2 upper, 2 lower → upper ≥ lower) count.
        case caps
        /// Contains a lowercase letter and is not `.caps`. Normal words:
        /// "John", "the", "iPhone", "McDonald". These BREAK a caps run.
        case lower
        /// Exactly one letter ("I", "A", "X") or no letters at all
        /// (punctuation, numbers). Single uppercase letters are
        /// legitimately uppercase, so they neither count toward a run
        /// nor break it — they're transparent.
        case neutral
    }

    /// Classify a whitespace-delimited token for runaway-caps detection.
    /// Operates on the token's letters only; surrounding punctuation is
    /// ignored for classification (but preserved when recasing).
    private func classifyCaps(_ token: String) -> CapsClass {
        let letters = token.filter { $0.isLetter }
        if letters.count <= 1 { return .neutral }
        let upper = letters.filter { $0.isUppercase }.count
        let lower = letters.count - upper
        if upper >= 2 && upper >= lower { return .caps }
        return lower > 0 ? .lower : .neutral
    }

    /// True for a token whose letter-core is exactly one uppercase
    /// letter ("A", "I", "X"). Used to demote stray single capitals
    /// inside a runaway run while leaving punctuation-only tokens alone.
    private func isSingleUppercaseLetter(_ token: String) -> Bool {
        let letters = token.filter { $0.isLetter }
        return letters.count == 1 && (letters.first?.isUppercase ?? false)
    }

    /// Recase runaway ALL-CAPS stretches back to sentence case.
    ///
    /// **Detection.** A "runaway run" is a maximal sequence of tokens
    /// that are `.caps` or `.neutral` (lowercase words break it),
    /// containing at least `minCapsInRun` `.caps` tokens. The threshold
    /// is the safeguard: legitimate uppercase clusters in speech (an
    /// acronym or two — "FBI", "U.S.") never reach five-in-a-row, while
    /// Whisper's caption-mode drift produces dozens. Tokens outside any
    /// qualifying run are left byte-for-byte untouched, so normal
    /// transcripts are completely unaffected.
    ///
    /// **Recasing.** Within a run, each `.caps` token is lowercased and
    /// then re-capitalized by three rules, in priority order:
    ///   1. Sentence start (first token of the run, or following a token
    ///      that ended in `.`/`?`/`!`/`…`) → capitalize first letter.
    ///   2. "i" / "i'm" / "i've" / "i'll" / "i'd" → capital I.
    ///   3. Known proper noun → restore canonical capitalization.
    /// (Proper-noun and sentence-start rules can both apply; the proper
    /// noun's own capitalization already covers the first letter.)
    ///
    /// **Proper-noun preservation.** Lowercasing a shout would turn
    /// "IRAN" into "iran". To avoid that, we first harvest canonical
    /// capitalizations from the *normally-cased* parts of the same
    /// transcript — any token that appears Title-cased (first letter
    /// upper, at least one lowercase, not itself all-caps) like "Iran",
    /// "Israel", "America". Inside a shout, a lowercased token whose
    /// spelling matches a harvested proper noun gets the canonical form
    /// back. The limitation: a proper noun that appears *only* inside a
    /// shout (never in normal text) can't be harvested and will come
    /// back lowercased. Shipping a global proper-noun dictionary would
    /// fix that but isn't worth the size/maintenance; the transcript's
    /// own normal text covers the common case (a name said once in caps
    /// is almost always said elsewhere in normal case too).
    @MainActor
    private func deshoutRunawayCaps(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !segments.isEmpty else { return segments }

        let minCapsInRun = 5

        // --- Harvest proper nouns from normally-cased text. ---
        // lowercased spelling → canonical capitalization. We only trust
        // Title-case words that appear MID-SENTENCE: a word capitalized
        // in the middle of a sentence ("...tumor of Israel are...") is
        // almost certainly a proper noun, whereas a word capitalized at
        // a sentence start ("They want...") is usually just a common
        // word and would pollute the map (causing "THEY" in a shout to
        // wrongly become "They"). Real proper nouns reliably appear
        // mid-sentence somewhere in a transcript, so this filter keeps
        // Iran/Israel/America while dropping They/All/We. First spelling
        // seen wins (stable, and proper nouns are cased consistently).
        // Sentence state carries across segments in time order.
        var properNouns: [String: String] = [:]
        var harvestPrevEnded = true
        for seg in segments {
            for raw in seg.text.split(whereSeparator: { $0.isWhitespace }) {
                let token = String(raw)
                defer {
                    if let last = token.last(where: { !$0.isWhitespace }) {
                        harvestPrevEnded = ".?!…".contains(last)
                    }
                }
                guard !harvestPrevEnded else { continue }       // mid-sentence only
                guard classifyCaps(token) == .lower else { continue }
                // Strip surrounding non-letters; keep interior
                // apostrophes/hyphens ("O'Brien", "Smith-Jones").
                let core = token.trimmingCharacters(
                    in: CharacterSet.letters.inverted
                )
                guard let first = core.first, first.isUppercase else { continue }
                // Title-case shape: at least one lowercase letter after
                // the first (already guaranteed `.lower`, so this holds,
                // but check explicitly for clarity/safety).
                guard core.dropFirst().contains(where: { $0.isLowercase }) else { continue }
                let key = core.lowercased()
                if properNouns[key] == nil {
                    properNouns[key] = core
                }
            }
        }

        // --- Flatten tokens across all segments, tracking origin. ---
        struct Tok {
            let segIndex: Int
            let text: String
            let klass: CapsClass
        }
        var flat: [Tok] = []
        var perSegTokens: [[String]] = Array(repeating: [], count: segments.count)
        for (si, seg) in segments.enumerated() {
            let tokens = seg.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            perSegTokens[si] = tokens
            for t in tokens {
                flat.append(Tok(segIndex: si, text: t, klass: classifyCaps(t)))
            }
        }
        guard !flat.isEmpty else { return segments }

        // --- Find runaway runs; mark flat-indices to recase. ---
        var marked = Set<Int>()
        var i = 0
        while i < flat.count {
            guard flat[i].klass != .lower else { i += 1; continue }
            // Extend a candidate run over caps/neutral tokens.
            var j = i
            var capsCount = 0
            while j < flat.count, flat[j].klass != .lower {
                if flat[j].klass == .caps { capsCount += 1 }
                j += 1
            }
            if capsCount >= minCapsInRun {
                // Mark caps tokens AND single uppercase letters in the
                // run. Caps tokens get sentence-cased; single letters
                // get demoted ("A" → "a") unless they're "I" (protected
                // by the recase rules). True single-letter neutrals that
                // should stay (none, really, inside a shout) and
                // punctuation-only tokens are not marked.
                for k in i..<j where flat[k].klass == .caps || isSingleUppercaseLetter(flat[k].text) {
                    marked.insert(k)
                }
            }
            i = j == i ? i + 1 : j
        }
        guard !marked.isEmpty else { return segments }

        // --- Recase, tracking sentence boundaries across the stream. ---
        let iContractions: Set<String> = ["i", "i'm", "i've", "i'll", "i'd"]
        // Re-walk every token (marked or not) to maintain an accurate
        // "did the previous token end a sentence?" flag. Unmarked tokens
        // inform sentence state but are never rewritten.
        var prevEndedSentence = true  // start-of-transcript = sentence start
        // Bucket rewritten tokens back per segment. Start with originals;
        // overwrite only the marked positions.
        var rewritten = perSegTokens
        // Map each flat index to its (segIndex, indexWithinSeg).
        var cursorPerSeg = Array(repeating: 0, count: segments.count)
        for (idx, tok) in flat.enumerated() {
            let within = cursorPerSeg[tok.segIndex]
            cursorPerSeg[tok.segIndex] += 1

            if marked.contains(idx) {
                rewritten[tok.segIndex][within] = recaseToken(
                    tok.text,
                    isSentenceStart: prevEndedSentence,
                    iContractions: iContractions,
                    properNouns: properNouns
                )
            }
            // Update sentence state from the (original) token's trailing
            // punctuation — case doesn't affect this.
            if let last = tok.text.last(where: { !$0.isWhitespace }) {
                prevEndedSentence = ".?!…".contains(last)
            }
        }

        // --- Reassemble; only rewrite segments that actually changed. ---
        var touched = Set<Int>()
        for idx in marked { touched.insert(flat[idx].segIndex) }
        var out = segments
        for si in touched {
            out[si].text = rewritten[si].joined(separator: " ")
        }
        if !touched.isEmpty {
            print("[Refinement/Deshout] recased \(marked.count) word(s) across \(touched.count) segment(s)")
        }
        return out
    }

    /// Recase a single token that's been flagged as part of a runaway
    /// caps run. Preserves leading/trailing punctuation; lowercases the
    /// letter core, then applies proper-noun / sentence-start / "I"
    /// capitalization.
    private func recaseToken(
        _ token: String,
        isSentenceStart: Bool,
        iContractions: Set<String>,
        properNouns: [String: String]
    ) -> String {
        // Split into leading punct + core + trailing punct so "OMAN,"
        // and "(WAR." recase the core only.
        let letterSet = CharacterSet.letters
        let chars = Array(token)
        var lead = 0
        while lead < chars.count,
              String(chars[lead]).rangeOfCharacter(from: letterSet) == nil {
            lead += 1
        }
        var trail = chars.count - 1
        while trail >= lead,
              String(chars[trail]).rangeOfCharacter(from: letterSet) == nil {
            trail -= 1
        }
        guard lead <= trail else { return token } // no letters; leave as-is

        let leading = String(chars[0..<lead])
        let core = String(chars[lead...trail])
        let trailing = String(chars[(trail + 1)...])

        let lower = core.lowercased()
        let cased: String

        if let canonical = properNouns[lower] {
            // If this is also a sentence start, canonical already begins
            // with an uppercase letter, so it's correct either way.
            cased = canonical
        } else if iContractions.contains(lower) {
            cased = "I" + lower.dropFirst()
        } else if isSentenceStart {
            cased = lower.prefix(1).uppercased() + lower.dropFirst()
        } else {
            cased = lower
        }

        return leading + cased + trailing
    }

    // MARK: - Elapsed timer

    @MainActor
    private func startElapsedTimer() {
        stopElapsedTimer()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startWallClock else { return }
                self.elapsedSeconds = Date().timeIntervalSince(start)
            }
        }
    }

    @MainActor
    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: - Duration probe

    /// Read total audio duration from a local file using AVFoundation. Returns nil if
    /// the file can't be parsed (which would also mean ffmpeg won't be able to read it,
    /// so the error will surface again later in a clearer way).
    static func probeDuration(of url: URL) -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        let duration = asset.duration
        guard duration.isValid, !duration.isIndefinite else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// Eager probe entry point — called from the sidebar's `urlInput` onChange.
    /// Cancels any in-flight probe, classifies the URL, kicks off the right
    /// kind of probe in the background. Updates `probeStatus` and
    /// `probedDuration` as the result lands.
    ///
    /// Design call: yt-dlp sources (YouTube, Twitter, podcasts, SoundCloud)
    /// are NOT probed eagerly here because yt-dlp invocations can:
    ///   - hit macOS Keychain (cookies-from-browser); per-paste prompts are
    ///     hostile UX
    ///   - take 3–10s
    ///   - cost the user network bandwidth on URLs they may immediately
    ///     discard
    ///
    /// They probe at `start()` instead, paying the cost once per session. The
    /// sidebar will show "Auto (Live)" for those URLs until Start, which is
    /// a minor inconsistency we accept in exchange for not surprising users.
    /// HLS, direct audio, and local files all probe quickly and cheaply, so
    /// they get the eager treatment.
    @MainActor
    func beginProbe(for rawInput: String) {
        // Cancel any outstanding probe first; URL just changed, prior result
        // is now stale.
        probeTask?.cancel()
        probeTask = nil
        probedDuration = nil
        // Clear the previously-displayed title too — it belonged to the
        // prior URL. The new probe (or local-file fallback) will populate
        // it again before the user hits Start.
        detectedTitle = nil

        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            probeStatus = .idle
            return
        }

        // Local file: synchronous AVURLAsset probe. Resolve as a file path
        // (the sidebar accepts both `file://` URLs from NSOpenPanel and bare
        // paths from drag-and-drop or manual entry).
        let fileURL = Self.localFileURL(from: trimmed)
        if let fileURL {
            probeStatus = .probing
            // Title for local files is just the filename minus extension —
            // there's no metadata source to query (and embedded tags vary
            // wildly by format). The filename is what the user named it,
            // so it's the most useful label anyway.
            detectedTitle = fileURL.deletingPathExtension().lastPathComponent
            if let seconds = Self.probeDuration(of: fileURL) {
                probedDuration = seconds
                probeStatus = .finite(seconds)
            } else {
                probeStatus = .failed("Couldn't read \(fileURL.lastPathComponent)")
            }
            return
        }

        // Remote URL. Classify to decide probe strategy.
        guard let url = URL(string: trimmed), url.scheme != nil else {
            probeStatus = .idle  // not a probable URL yet — user mid-typing
            return
        }
        let source = StreamSource.detect(from: url)

        // Two probe paths:
        //   - yt-dlp sources (YouTube, Twitter, Apple Podcasts, SoundCloud,
        //     and now `.unknown` HTML pages handled by yt-dlp's generic
        //     extractor): use `probeYTDlpMetadata`. Slower (3-10s typical;
        //     up to 15s with timeout) and may trigger a macOS Keychain
        //     prompt the first time cookies-from-browser is invoked, but
        //     once approved subsequent invocations within the same app
        //     launch are silent. Also returns the title field.
        //   - HLS / direct audio: use `probeRemoteDurationViaFFmpeg`. Fast
        //     (sub-second usually) since ffmpeg just reads the manifest
        //     header, no auth involved. No title source — HLS manifests
        //     don't carry titles in any standardized way.
        //
        // Both paths populate probeStatus and probedDuration the same way
        // so the rest of the engine (sidebar display, start() reuse) is
        // agnostic about which probe path ran. The title field is
        // populated by the yt-dlp path only; for HLS/direct audio it
        // remains nil and the UI just shows the source kind.
        probeStatus = .probing
        probeTask = Task { [weak self] in
            // Run the appropriate probe off the MainActor. The chosen
            // strategy is captured by `source` — it's stable for the task's
            // lifetime since urlString changes cancel the task before
            // assigning a new one.
            let probeResult: ProbeOutcome
            let probedTitle: String?
            if source.requiresYTDlp {
                if let meta = await Self.probeYTDlpMetadata(url: url) {
                    probedTitle = meta.title
                    if let seconds = meta.duration {
                        probeResult = .finite(seconds)
                    } else {
                        probeResult = .live
                    }
                } else {
                    // probeYTDlpMetadata returned nil → probe failed
                    // outright. Common causes:
                    //   - macOS Keychain prompt for cookies-from-browser
                    //     was dismissed or denied → yt-dlp can't read
                    //     cookies → YouTube returns 403 on age/login-gated
                    //     content
                    //   - Network blocked (corporate firewall, captive
                    //     portal, VPN flap)
                    //   - yt-dlp binary missing, wrong path, or version
                    //     incompatible with the site's current page layout
                    //   - URL is malformed or for a site yt-dlp doesn't
                    //     support
                    //
                    // Previously we silently fell back to .live so the
                    // user could still attempt to Start, but that hid
                    // the failure and made the Retry button (which keys
                    // off `probeStatus == .failed`) dead code. Surface
                    // the failure explicitly so the sidebar shows the
                    // Retry button and the user can iterate (grant
                    // Keychain access, fix the URL, etc.) without
                    // having to retype the URL.
                    probedTitle = nil
                    probeResult = .failed("yt-dlp probe failed — check URL, cookies, or network")
                }
            } else {
                let ff = await Self.probeRemoteDurationViaFFmpeg(url: url)
                probedTitle = nil  // HLS/direct audio: no title source
                switch ff {
                case .finite(let s): probeResult = .finite(s)
                case .live:          probeResult = .live
                case .failed:        probeResult = .live  // silent fallback
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                // Confirm the URL hasn't changed under us — if `beginProbe`
                // was called again with a different URL while we were
                // running, our result is stale and the newer call has
                // already updated `probeStatus`.
                guard case .probing = self.probeStatus else { return }
                // Set the title regardless of duration outcome — a
                // livestream still has a name worth showing.
                if let probedTitle, !probedTitle.isEmpty {
                    self.detectedTitle = probedTitle
                }
                switch probeResult {
                case .finite(let seconds):
                    self.probedDuration = seconds
                    self.probeStatus = .finite(seconds)
                    print("[Probe] \(source.rawValue): \(String(format: "%.1f", seconds))s → Static.")
                case .live:
                    self.probedDuration = nil
                    self.probeStatus = .live
                    print("[Probe] \(source.rawValue): no finite duration → Live.")
                case .failed(let reason):
                    self.probedDuration = nil
                    self.probeStatus = .failed(reason)
                    print("[Probe] \(source.rawValue): probe failed — \(reason)")
                }
            }
        }
    }

    /// Result of an eager probe, unified across the yt-dlp and ffmpeg
    /// paths so the closure in `beginProbe` doesn't need to switch on the
    /// strategy when applying the result.
    private enum ProbeOutcome {
        case finite(TimeInterval)
        case live
        case failed(String)
    }

    /// Coerce a sidebar-pasted string into a file:// URL when it looks like
    /// a local path. Returns nil if the string isn't pointing at the local
    /// filesystem. Mirrors the same logic the sidebar uses for display.
    private static func localFileURL(from raw: String) -> URL? {
        if raw.hasPrefix("file://") {
            return URL(string: raw)
        }
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            let expanded = (raw as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return nil
    }

    /// Result envelope for an ffmpeg-based duration probe.
    private enum FFmpegProbeResult {
        case finite(TimeInterval)
        case live
        case failed(String)
    }

    /// Probe duration by running ffmpeg with the URL as input and parsing
    /// the `Duration: HH:MM:SS.ms` line from stderr. ffmpeg without any
    /// output flag still does a header read on the input and writes input
    /// metadata to stderr before failing with "At least one output file
    /// must be specified" — which is fine, we want the metadata, not output.
    ///
    /// Specifically uses `-t 0 -f null -` to make ffmpeg do header parsing
    /// then immediately stop, since the "output required" error path adds
    /// a small delay and noise. The `-t 0` means "read 0 seconds" and `-f
    /// null -` is "write to nowhere." Together they make ffmpeg exit
    /// cleanly after parsing the input.
    ///
    /// Timeout: 8 seconds. HLS manifests are small; if ffmpeg hasn't
    /// finished a header read in 8 seconds the stream is either dead or
    /// hung. Falling back to Live is safe.
    private static func probeRemoteDurationViaFFmpeg(url: URL) async -> FFmpegProbeResult {
        // Resolve ffmpeg path. If it's not available, we can't probe.
        guard let ffmpegPath = await MainActor.run(body: { ToolManager.shared.ffmpegPath }),
              FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
            return .failed("ffmpeg not available")
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<FFmpegProbeResult, Never>) in
            let process = Process()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            // -hide_banner: suppresses ffmpeg's version banner, makes stderr easier to parse.
            // -i <url>: input.
            // -t 0 -f null -: do header parse then exit. Avoids the "output required"
            //                  error path and its noise.
            process.arguments = [
                "-hide_banner",
                "-i", url.absoluteString,
                "-t", "0",
                "-f", "null", "-"
            ]
            // We discard stdout. stderr carries all the diagnostic lines.
            process.standardOutput = Pipe()
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                cont.resume(returning: .failed("Couldn't start ffmpeg: \(error.localizedDescription)"))
                return
            }

            // 8-second timeout. If ffmpeg hasn't finished, kill it.
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if process.isRunning {
                    process.terminate()
                }
            }

            // Wait synchronously on a background thread (we're inside the
            // continuation, so the surrounding async context has yielded to
            // us; using `waitUntilExit()` directly here is fine).
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                timeoutTask.cancel()

                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                cont.resume(returning: parseFFmpegDuration(from: text))
            }
        }
    }

    /// Extract a duration from ffmpeg's stderr. Looks for a line of the form
    /// `  Duration: HH:MM:SS.ss, start: ..., bitrate: ...`. Returns
    /// `.finite(seconds)` if found and numeric, `.live` if found but `N/A`
    /// (live streams) or absent (some HLS edge cases), `.failed` if stderr
    /// doesn't contain anything resembling a Duration line and ffmpeg
    /// presumably errored out before opening the input.
    ///
    /// Static so it doesn't need an instance — the parsing rules are
    /// independent of process management. Private because its result type
    /// (`FFmpegProbeResult`) is private; if we ever want to unit-test this,
    /// promote both to `internal`.
    private static func parseFFmpegDuration(from stderr: String) -> FFmpegProbeResult {
        // Find the first Duration: line. ffmpeg emits one per input; we only
        // probe one input so the first match is the right one.
        guard let durationLine = stderr.split(separator: "\n").first(where: { $0.contains("Duration:") }) else {
            // No Duration line at all. Could be a hard ffmpeg error (bad URL,
            // unsupported codec, network unreachable) or a live stream with
            // a particularly weird manifest. Treat as "couldn't determine."
            return .failed("no Duration line in ffmpeg output")
        }

        // Look for "Duration: N/A" — explicit live-stream marker.
        if durationLine.contains("Duration: N/A") {
            return .live
        }

        // Extract HH:MM:SS.ms. Regex: digits, colon, digits, colon, digits, dot, digits.
        // (?:...) is a non-capturing group; we capture the whole thing as one match.
        let pattern = #"Duration:\s*(\d{2,}):(\d{2}):(\d{2}(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return .failed("regex compile failed")
        }
        let line = String(durationLine)
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges >= 4 else {
            return .live  // line present but unparseable — treat as indeterminate
        }
        let h = Double((line as NSString).substring(with: match.range(at: 1))) ?? 0
        let m = Double((line as NSString).substring(with: match.range(at: 2))) ?? 0
        let s = Double((line as NSString).substring(with: match.range(at: 3))) ?? 0
        let total = h * 3600 + m * 60 + s
        // Sanity: ffmpeg occasionally reports 0:00:00 for live streams whose
        // manifest happens to include a #EXTINF but no #EXT-X-ENDLIST.
        return total > 0 ? .finite(total) : .live
    }

    /// Probe a yt-dlp-supported URL for its duration and live-stream status.
    /// Uses `yt-dlp --print` for three fields in priority order:
    ///
    ///   1. `%(live_status)s` — yt-dlp's canonical live-vs-VOD signal.
    ///      Values: `is_live`, `is_upcoming`, `was_live`, `post_live`,
    ///      `not_live`. Only the first two are genuinely live; everything
    ///      else means VOD-treatable (including `was_live` for archived
    ///      livestreams that are now playback-on-demand).
    ///   2. `%(duration)s` — number of seconds (or "NA").
    ///   3. `%(is_live)s` — older yt-dlp boolean. Used as a fallback only
    ///      when `live_status` is "NA".
    ///
    /// Why not `-J`: `yt-dlp -J` triggers full extraction, which on YouTube
    /// invokes the n-param JS challenge, which requires Deno. We tried this
    /// path and it failed in ~270ms — yt-dlp exited before any meaningful
    /// metadata could come back because the probe didn't pass --js-runtimes.
    /// Adding Deno setup to the probe is technically possible but slow
    /// (3-10s for the full extractor) and triggers a Keychain prompt when
    /// cookies-from-browser is wired up. `--print` runs the fast extractor
    /// path, which returns pageinfo-level metadata (including `live_status`)
    /// without needing Deno — much more conservative and reliable.
    ///
    /// The previous version only fetched `duration` + `is_live`. Some YouTube
    /// VODs (notably former-livestream archives — `live_status: was_live`)
    /// return "NA" for `duration` in the fast path because the page metadata
    /// hasn't been fully populated, but `live_status` is reliably emitted
    /// because it's part of the basic pageinfo blob. This wider field set
    /// catches those without needing the slow full-extraction path.
    ///
    /// Result of a yt-dlp probe. Duration is nil for genuine livestreams and
    /// for unparseable cases; title is whatever yt-dlp's `%(title)s` field
    /// returned (typically video/podcast/Spaces title), nil if absent.
    /// Duration is decoupled from title — a live stream still has a title,
    /// and we want to display it even when duration is unknown.
    struct YTDlpProbeResult {
        let duration: TimeInterval?
        let title: String?
        /// Whether yt-dlp returned an authoritative live/upcoming signal
        /// — i.e. `live_status` was `is_live` / `is_upcoming`, or fell
        /// through to `is_live=true`. False means duration is nil because
        /// no signal was available (either the extractor doesn't populate
        /// the field for this URL shape, or the inner manifest wasn't
        /// parsed). Used to distinguish "genuinely live, don't fall back"
        /// from "uncertain, try resolving the URL one level deeper" in
        /// `probeYTDlpMetadata`'s second-stage fallback.
        let liveSignalConfirmed: Bool
    }

    /// Probe a remote URL via yt-dlp for duration AND title.
    ///
    /// Returns YTDlpProbeResult with both fields possibly nil. The function
    /// itself returns nil only when yt-dlp couldn't be invoked at all
    /// (binary missing, process spawn failed, or yt-dlp errored out
    /// completely). For genuine livestreams the result is populated with
    /// `duration: nil` and the actual title — callers should not treat a
    /// returned-but-nil-duration as a failure.
    ///
    /// Returns nil when:
    ///   - yt-dlp isn't available
    ///   - yt-dlp errored out (probe-failure path)
    ///
    /// **Two-stage probe with URL-resolution fallback.** Some site
    /// extractors (notably senate.gov's ISVP wrapper, civicclerk, and
    /// other "page that embeds a player" extractors) populate page-level
    /// metadata correctly but DON'T compute duration — duration only
    /// becomes known after the inner HLS manifest is fetched, which
    /// `--print` doesn't trigger for nested extractors. The page-level
    /// `--print %(duration)s` returns `NA`, both `live_status` and
    /// `is_live` come back `NA` / not-true, and we'd previously
    /// default-to-Live and put the user into the wrong session mode.
    ///
    /// When `allowFallback` is true (the default for external callers)
    /// and the primary probe returned "no signal" (nil duration AND
    /// `liveSignalConfirmed == false`), we re-probe one level deeper:
    /// run `yt-dlp -g` to resolve the URL to its underlying media URL
    /// (typically an `.m3u8`), then call `probeYTDlpMetadata` recursively
    /// on that URL with `allowFallback: false`. yt-dlp's generic HLS
    /// extractor parses the m3u8 manifest fully and reports duration
    /// correctly. A finite duration there means VOD; still-nil means
    /// the manifest itself doesn't define one (genuinely live).
    ///
    /// Merge semantics on successful fallback: take the duration AND
    /// `liveSignalConfirmed` from the inner result (more authoritative
    /// about the stream itself), but keep the outer probe's title if it
    /// had one (page titles are typically more descriptive than the bare
    /// filename a generic HLS extractor would produce — e.g. "Help
    /// Committee Hearing 06-17-2026" beats "master.m3u8").
    ///
    /// Timeout: 15 seconds per stage. `--print` is fast (typically 3-5s)
    /// but YouTube's occasional bot-check delays can push it to 10s. 15s
    /// covers normal cases with margin; beyond that we'd rather fall back
    /// to Live than block Start indefinitely. The two-stage probe can
    /// total up to ~30s in the worst case (rare; normally well under 10s).
    static func probeYTDlpMetadata(url: URL, allowFallback: Bool = true) async -> YTDlpProbeResult? {
        let primary = await runYTDlpPrintProbe(url: url)

        // Only attempt fallback when (a) the caller hasn't already disabled
        // it (recursion guard), (b) we got a result at all, (c) duration is
        // nil, and (d) the nil duration wasn't an authoritative live signal.
        guard allowFallback,
              let primaryResult = primary,
              primaryResult.duration == nil,
              !primaryResult.liveSignalConfirmed else {
            return primary
        }

        // Resolve underlying media URL. `-g` returns the direct stream URL
        // (m3u8 / mp4 / similar) for the selected format. May return
        // multiple lines for multi-format streams; we take the first.
        guard let resolvedURL = await resolveStreamURLViaYTDlp(originalURL: url),
              resolvedURL != url else {
            print("[Probe] URL-resolution fallback: yt-dlp -g returned no resolvable URL — staying with Live default.")
            return primary
        }

        print("[Probe] URL-resolution fallback: re-probing resolved media URL for duration.")
        guard let fallback = await probeYTDlpMetadata(url: resolvedURL, allowFallback: false) else {
            print("[Probe] URL-resolution fallback: deeper probe failed — staying with Live default.")
            return primary
        }

        // If the deeper probe still couldn't determine duration, this is
        // genuinely live (or live-like). Return the primary result rather
        // than the inner — preserves the original title.
        guard fallback.duration != nil else {
            print("[Probe] URL-resolution fallback: deeper probe also returned no duration — treating as Live.")
            return primary
        }

        let mergedDuration = fallback.duration!
        let mergedTitle = primaryResult.title ?? fallback.title
        print("[Probe] URL-resolution fallback: deeper probe found duration=\(mergedDuration)s → Static.")
        return YTDlpProbeResult(
            duration: mergedDuration,
            title: mergedTitle,
            liveSignalConfirmed: fallback.liveSignalConfirmed
        )
    }

    /// Resolve a wrapper-page URL to its underlying media URL via
    /// `yt-dlp -g` (= `--get-url`). Returns the first line of yt-dlp's
    /// output as a URL, or nil on any failure. Used by the two-stage
    /// probe fallback to drill one extractor level deeper when the
    /// page-level probe returns no duration signal.
    ///
    /// 15s timeout matches the print-probe timeout — `yt-dlp -g` does
    /// the same info-extraction work, just emits the URL instead of
    /// the metadata fields, so it has similar latency characteristics.
    static func resolveStreamURLViaYTDlp(originalURL url: URL) async -> URL? {
        let ytDlpPath = await MainActor.run { ToolManager.shared.effectiveYTDlpPath }
        // Match the print-probe's environment + TLS handling. The
        // resolve step does the same info-extraction work that
        // `--print` does, so it has the same SSL-cert requirements
        // on networks with TLS interception (e.g. user's corporate
        // Netskope MITM).
        let skipTLS = await MainActor.run { ToolManager.shared.disableTLSCheck }
        let childEnv = await MainActor.run { ToolManager.shared.ytDlpChildEnvironment() }

        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: ytDlpPath)
            if let env = childEnv {
                process.environment = env
            }

            var args: [String] = []
            if skipTLS {
                args.append("--no-check-certificate")
            }
            let probeSource = StreamSource.detect(from: url)
            if probeSource.benefitsFromImpersonation {
                args.append(contentsOf: ["--impersonate", "chrome"])
            }
            args.append(contentsOf: [
                "--quiet",
                "--no-warnings",
                "-g",
                url.absoluteString,
            ])
            process.arguments = args
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                print("[Probe] yt-dlp -g failed to start: \(error.localizedDescription)")
                cont.resume(returning: nil)
                return
            }

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if process.isRunning {
                    print("[Probe] yt-dlp -g timed out at 15s; terminating.")
                    process.terminate()
                }
            }

            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                timeoutTask.cancel()

                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                guard process.terminationStatus == 0,
                      let text = String(data: data, encoding: .utf8) else {
                    cont.resume(returning: nil)
                    return
                }
                // Take the first non-empty line. `-g` may emit multiple URLs
                // for separate video/audio streams; the first is typically
                // the primary muxed source (or the video stream we'd care
                // about for duration purposes — both streams in a DASH
                // split have the same duration so either works).
                let firstLine = text.split(separator: "\n")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .first(where: { !$0.isEmpty })
                guard let resolved = firstLine, let resolvedURL = URL(string: resolved) else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: resolvedURL)
            }
        }
    }

    /// Internal: run a single `yt-dlp --print` probe pass against `url`
    /// and return the parsed result. Extracted from the previously-
    /// monolithic `probeYTDlpMetadata` so the public function can
    /// orchestrate the two-stage probe (primary + URL-resolution
    /// fallback) without recursion into the heavy continuation block.
    private static func runYTDlpPrintProbe(url: URL) async -> YTDlpProbeResult? {
        let ytDlpPath: String? = await {
            do { return try await ToolManager.shared.ensureYTDlpAvailable() } catch { return nil }
        }()
        guard let ytDlpPath, FileManager.default.isExecutableFile(atPath: ytDlpPath) else {
            return nil
        }

        // Read the user's TLS-skip preference here in the outer async
        // scope (where MainActor.run can await) so the sync
        // continuation closure below can use it without further
        // awaits. Same rationale as the download/live-pipe paths —
        // corporate TLS interception with a private root certificate
        // not in the system trust store.
        let skipTLS = await MainActor.run { ToolManager.shared.disableTLSCheck }
        // Likewise read the SSL_CERT_FILE override into a local
        // before entering the sync continuation.
        let childEnv = await MainActor.run { ToolManager.shared.ytDlpChildEnvironment() }

        return await withCheckedContinuation { (cont: CheckedContinuation<YTDlpProbeResult?, Never>) in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: ytDlpPath)
            if let env = childEnv {
                process.environment = env
            }
            // Four --print fields emitted as four lines on stdout, in
            // declaration order: live_status, duration, is_live, title.
            // Title is appended last so the existing parse logic for the
            // first three fields stays bytewise-identical; if a future yt-dlp
            // emits fewer lines than requested we still get the duration
            // signal before the title.
            var probeArgs: [String] = []
            if skipTLS {
                probeArgs.append("--no-check-certificate")
            }
            // --impersonate chrome ONLY for sites that benefit. See
            // AudioStreamExtractor download-path comment for the
            // full rationale — Facebook/Instagram need it; YouTube
            // gets HARDER bot challenges with it.
            let probeSource = StreamSource.detect(from: url)
            if probeSource.benefitsFromImpersonation {
                probeArgs.append(contentsOf: ["--impersonate", "chrome"])
            }
            probeArgs.append(contentsOf: [
                "--quiet",
                "--no-warnings",
                "--print", "%(live_status)s",
                "--print", "%(duration)s",
                "--print", "%(is_live)s",
                "--print", "%(title)s",
                url.absoluteString
            ])
            process.arguments = probeArgs
            process.standardOutput = stdout
            // Capture stderr so we can surface it on failure. The previous
            // probe discarded stderr, which made probe failures invisible —
            // when `-J` returned in 270ms we had no idea why.
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                print("[Probe] yt-dlp probe failed to start: \(error.localizedDescription)")
                cont.resume(returning: nil)
                return
            }

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if process.isRunning {
                    print("[Probe] yt-dlp probe timed out at 15s; terminating.")
                    process.terminate()
                }
            }

            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                timeoutTask.cancel()

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                guard process.terminationStatus == 0 else {
                    if !errText.isEmpty {
                        print("[Probe] yt-dlp exited \(process.terminationStatus): \(errText.prefix(200))")
                    } else {
                        print("[Probe] yt-dlp exited \(process.terminationStatus) with no stderr.")
                    }
                    cont.resume(returning: nil)
                    return
                }

                let text = String(data: outData, encoding: .utf8) ?? ""
                let lines = text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
                // Expect 4 lines (one per --print). Fewer means yt-dlp
                // returned partial output — treat as unparseable for the
                // duration signal but try to salvage the title if it
                // happened to come through.
                guard lines.count >= 3 else {
                    print("[Probe] yt-dlp --print returned \(lines.count) lines, expected 4. stdout=\(text.prefix(120))")
                    cont.resume(returning: nil)
                    return
                }
                let liveStatusStr = lines[0].lowercased()
                let durationStr = lines[1]
                let isLiveStr = lines[2].lowercased()
                // Title is lines[3] if present; some sources don't have a
                // title (e.g. generic-extractor pages on bare HLS URLs) and
                // yt-dlp prints "NA" in that case. Map NA/empty to nil.
                let titleRaw = lines.count >= 4 ? lines[3] : ""
                let title: String? = (titleRaw.isEmpty || titleRaw.lowercased() == "na") ? nil : titleRaw

                // Decide the duration field from the existing three signals,
                // then return both duration and title together. The decision
                // tree below mirrors the pre-refactor logic exactly — we just
                // build a YTDlpProbeResult instead of returning the
                // TimeInterval directly. `liveSignalConfirmed` tracks whether
                // we got an authoritative live-or-upcoming signal (true) vs.
                // defaulted to nil for "no signal" reasons (false) — the
                // outer `probeYTDlpMetadata` uses this to decide whether to
                // attempt URL-resolution fallback.
                let duration: TimeInterval?
                let liveSignalConfirmed: Bool

                // 1. live_status — most specific signal. Only is_live and
                //    is_upcoming mean genuinely live; everything else
                //    (was_live, post_live, not_live) is VOD-treatable.
                switch liveStatusStr {
                case "is_live", "is_upcoming":
                    print("[Probe] yt-dlp live_status='\(liveStatusStr)' → Live.")
                    duration = nil
                    liveSignalConfirmed = true
                case "was_live", "post_live", "not_live":
                    // Fall through to duration parsing.
                    if let seconds = Double(durationStr), seconds > 0 {
                        duration = seconds
                    } else {
                        duration = nil
                    }
                    liveSignalConfirmed = false
                case "na", "":
                    if isLiveStr == "true" {
                        print("[Probe] yt-dlp is_live=True (live_status NA) → Live.")
                        duration = nil
                        liveSignalConfirmed = true
                    } else if let seconds = Double(durationStr), seconds > 0 {
                        duration = seconds
                        liveSignalConfirmed = false
                    } else {
                        print("[Probe] yt-dlp: live_status='\(liveStatusStr)', duration='\(durationStr)', is_live='\(isLiveStr)' — no usable signal, will attempt URL-resolution fallback.")
                        duration = nil
                        liveSignalConfirmed = false
                    }
                default:
                    print("[Probe] yt-dlp unrecognized live_status='\(liveStatusStr)'; falling through to duration.")
                    if let seconds = Double(durationStr), seconds > 0 {
                        duration = seconds
                    } else {
                        duration = nil
                    }
                    liveSignalConfirmed = false
                }

                cont.resume(returning: YTDlpProbeResult(duration: duration, title: title, liveSignalConfirmed: liveSignalConfirmed))
            }
        }
    }
}
