import Foundation

// MARK: - StreamScribe Web Portal — models
//
// Everything here is plain data plus two small engines of logic that are
// worth reading on their own:
//
//   - PortalSettingsApplier: applies a job's per-job settings to the ONE shared
//     TranscriptionEngine / UserDefaults and records exactly what it changed, so
//     the Mac's own settings come back afterwards. It only restores a value that
//     still holds what the portal set — if someone changed a setting on the Mac
//     mid-job, their change wins.
//   - PortalTranscriptIndex: per-segment revision tracking, so a browser polling
//     a 3-hour hearing receives only what changed since its last poll instead of
//     the whole transcript every 1.5 seconds.

// MARK: - Job

enum PortalJobStatus: String, Codable {
    case queued
    case preparing
    case running
    case finishing
    case completed
    case failed
    case cancelled
    /// The app quit (or crashed) while the job was on the engine.
    case interrupted

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted: return true
        default: return false
        }
    }

    var isOnEngine: Bool {
        switch self {
        case .preparing, .running, .finishing: return true
        default: return false
        }
    }
}

/// Per-job settings chosen in the web form. "default" (or nil) means "leave the
/// Mac Mini's current setting alone".
struct PortalJobSettings: Codable, Equatable {
    /// default | auto | live | static
    var mode: String = "default"
    /// auto | whisperKit | parakeet | canary
    var engine: String = "auto"
    /// Model for the chosen engine (a WhisperKit model name or a Parakeet
    /// repo). nil = the Mini's current model for that engine. Ignored for
    /// "auto" and for Canary, which has a single model.
    var model: String? = nil
    /// default | off | fluidAudio | speakerKit | sortformer
    var diarization: String = "default"
    /// nil = Mini default; 0 = unconstrained; N = expected number of voices
    var expectedSpeakers: Int? = nil
    /// default | auto | ISO code ("en", "es", …)
    var language: String = "default"
    /// nil = Mini default
    var liveFromStart: Bool? = nil
    /// nil = Mini default
    var cleanup: Bool? = nil

    init() {}

    // Tolerant decoding: the browser may omit any field.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `try?` flattens the optional (SE-0230), so each line is String?/Int?/Bool?.
        mode = (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? "default"
        engine = (try? c.decodeIfPresent(String.self, forKey: .engine)) ?? "auto"
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        diarization = (try? c.decodeIfPresent(String.self, forKey: .diarization)) ?? "default"
        expectedSpeakers = try? c.decodeIfPresent(Int.self, forKey: .expectedSpeakers)
        language = (try? c.decodeIfPresent(String.self, forKey: .language)) ?? "default"
        liveFromStart = try? c.decodeIfPresent(Bool.self, forKey: .liveFromStart)
        cleanup = try? c.decodeIfPresent(Bool.self, forKey: .cleanup)
    }

    static let modeIDs = ["default", "auto", "live", "static"]
    static let engineIDs = ["auto", "whisperKit", "parakeet", "canary"]
    static let diarizationIDs = ["default", "off", "fluidAudio", "speakerKit", "sortformer"]

    /// Returns a human-readable problem, or nil when every field is valid.
    func validationError() -> String? {
        if !Self.modeIDs.contains(mode) { return "Unknown mode '\(mode)'" }
        if !Self.engineIDs.contains(engine) { return "Unknown engine '\(engine)'" }
        if !Self.diarizationIDs.contains(diarization) { return "Unknown speaker engine '\(diarization)'" }
        if let n = expectedSpeakers, n < 0 || n > 60 { return "Expected speakers must be between 0 and 60" }
        if let model, !model.isEmpty {
            switch engine {
            case "whisperKit":
                if !TranscriptionEngine.availableWhisperModels.contains(model) { return "Unknown WhisperKit model '\(model)'" }
            case "parakeet":
                if !TranscriptionEngine.availableParakeetModels.contains(model) { return "Unknown Parakeet model '\(model)'" }
            default:
                break
            }
        }
        if language != "default" && language != "auto" {
            let known = TranscriptionEngine.availableLanguages.compactMap { $0.code }
            if !known.contains(language) { return "Unsupported language '\(language)'" }
        }
        return nil
    }

    static func engineKind(_ id: String) -> TranscriptionEngineKind? {
        switch id {
        case "whisperKit": return .whisperKit
        case "parakeet": return .parakeet
        case "canary": return .canary
        default: return nil
        }
    }

    static func diarizationKind(_ id: String) -> DiarizationEngineKind? {
        switch id {
        case "off": return .off
        case "fluidAudio": return .fluidAudio
        case "speakerKit": return .speakerKit
        case "sortformer": return .sortformer
        default: return nil
        }
    }

    static func id(for kind: TranscriptionEngineKind) -> String {
        switch kind {
        case .whisperKit: return "whisperKit"
        case .parakeet: return "parakeet"
        case .canary: return "canary"
        }
    }

    static func id(for kind: DiarizationEngineKind) -> String {
        switch kind {
        case .off: return "off"
        case .fluidAudio: return "fluidAudio"
        case .speakerKit: return "speakerKit"
        case .sortformer: return "sortformer"
        }
    }
}

struct PortalJob: Codable, Identifiable {
    let id: UUID
    /// What the engine is given: an http(s) URL, or the absolute path of an
    /// uploaded file on this Mac. Never shown to web users for uploads.
    var input: String
    /// What web users see: the URL, or the uploaded file's original name.
    var displaySource: String
    var isUpload: Bool
    /// Folder holding the uploaded file; deleted with the job.
    var uploadDirectory: String?
    var settings: PortalJobSettings
    var submittedBy: String
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var status: PortalJobStatus
    var message: String?
    var title: String?
    /// "live" / "static" as the engine actually resolved it.
    var resolvedMode: String?
    var durationSeconds: Double?
    var processedSeconds: Double?

    // Transcript snapshot. Kept in sync with the engine while the engine still
    // holds this job's session; frozen once another session starts.
    var segments: [TranscriptSegment]
    /// Manual renames, keyed by machine label.
    var speakerNames: [String: String]
    /// Voiceprint identities captured from the session, keyed by machine label.
    /// Captured because VoiceprintService resets on the next session.
    var voiceprintNames: [String: String]
    var pins: [PinnedQuote]

    /// `TranscriptionEngine.sessionGeneration` of this job's session — the
    /// token that says "the engine is still holding this transcript".
    var engineSession: Int?
    /// Which portal engine slot ran this job (0 = the Mac window's engine).
    var slotIndex: Int?
    var stoppedBy: String?
    /// Browser-playable copy of the job's media on the Mini, for the web
    /// player and clips. Optional so job files saved before this existed load.
    var mediaPath: String?
    /// preparing | ready | unavailable (nil = not attempted yet)
    var mediaState: String?

    init(id: UUID = UUID(), input: String, displaySource: String, isUpload: Bool,
         uploadDirectory: String?, settings: PortalJobSettings, submittedBy: String) {
        self.id = id
        self.input = input
        self.displaySource = displaySource
        self.isUpload = isUpload
        self.uploadDirectory = uploadDirectory
        self.settings = settings
        self.submittedBy = submittedBy
        self.createdAt = Date()
        self.status = .queued
        self.segments = []
        self.speakerNames = [:]
        self.voiceprintNames = [:]
        self.pins = []
    }

    /// rename → voiceprint identity → machine label (same order as the Mac UI).
    func displayName(for label: String?) -> String? {
        guard let label else { return nil }
        if let custom = speakerNames[label]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        if let vp = voiceprintNames[label], !vp.isEmpty { return vp }
        return label
    }
}

// MARK: - Settings apply / restore

struct PortalRestoreItem: Codable, Equatable {
    let key: String
    /// Value before the portal changed it. nil for a UserDefaults key that was unset.
    let before: String?
    /// Value the portal applied.
    let applied: String
}

enum PortalSettingsApplier {
    private static let sessionModeKey = "engine.sessionMode"
    private static let transcriptionKey = "engine.transcriptionEngine"
    private static let diarizationKey = "engine.diarizationEngine"
    private static let languageKey = "engine.language"
    private static let whisperModelKey = "engine.whisperModel"
    private static let parakeetModelKey = "engine.parakeetModel"

    /// Apply `settings`. `resolvedStatic` is the probe's verdict (true = finite
    /// recording, false = live, nil = unknown) and only matters for engine "auto".
    static func apply(_ settings: PortalJobSettings, resolvedStatic: Bool?,
                      engine: TranscriptionEngine) -> [PortalRestoreItem] {
        var items: [PortalRestoreItem] = []

        func change(_ key: String, to value: String) {
            let before = current(key, engine: engine)
            guard before != value else { return }
            items.append(PortalRestoreItem(key: key, before: before, applied: value))
            set(key, value, engine: engine)
        }

        if settings.mode != "default", SessionMode(rawValue: settings.mode) != nil {
            change(sessionModeKey, to: settings.mode)
        }

        // Engine. "auto" mirrors the Mac's per-mode default (Whisper for
        // recordings, Parakeet for live) but is applied EXPLICITLY, so it holds
        // even when someone has pinned an engine on the Mac this launch.
        var engineID: String? = nil
        if let kind = PortalJobSettings.engineKind(settings.engine) {
            engineID = kind.rawValue
        } else if settings.engine == "auto" {
            let isStatic: Bool?
            switch settings.mode {
            case "static": isStatic = true
            case "live": isStatic = false
            default: isStatic = resolvedStatic
            }
            if let isStatic {
                engineID = (isStatic ? TranscriptionEngineKind.whisperKit : .parakeet).rawValue
            }
        }
        if let engineID {
            // Keep the engine's own per-mode default (which re-runs inside
            // start()) from overriding the job's choice. Set even when the
            // value is already right — start() would still flip it.
            engine.portalEngineChoiceActive = true
            change(transcriptionKey, to: engineID)
        }

        if let model = settings.model, !model.isEmpty {
            switch settings.engine {
            case "whisperKit": change(whisperModelKey, to: model)
            case "parakeet": change(parakeetModelKey, to: model)
            default: break
            }
        }

        if let kind = PortalJobSettings.diarizationKind(settings.diarization) {
            change(diarizationKey, to: kind.rawValue)
        }

        if settings.language != "default" {
            change(languageKey, to: settings.language)   // "auto" → nil in set()
        }

        // Expected speakers, backlog-from-start and cleanup are not engine
        // properties: they ride along as a SessionSettings override that
        // start() consumes (2026-10-02), so they never touch the Mac's own
        // settings and can differ between concurrent sessions.
        engine.nextSessionOverrides = sessionOverrides(settings)

        if !items.isEmpty {
            print("[Portal] Applied job settings: " + items.map { "\($0.key)=\($0.applied)" }.joined(separator: ", "))
        }
        return items
    }

    static func sessionOverrides(_ settings: PortalJobSettings) -> SessionSettings.Overrides? {
        var o = SessionSettings.Overrides()
        o.expectedSpeakerCount = settings.expectedSpeakers
        o.liveFromStart = settings.liveFromStart
        o.cleanupEnabled = settings.cleanup
        return o == SessionSettings.Overrides() ? nil : o
    }

    /// Put back every value the portal changed, newest first, but only where the
    /// value is still what the portal set.
    static func restore(_ items: [PortalRestoreItem], engine: TranscriptionEngine?) {
        guard let engine else { return }
        for item in items.reversed() {
            guard current(item.key, engine: engine) == item.applied else {
                print("[Portal] Not restoring \(item.key): changed on the Mac since the job applied it.")
                continue
            }
            set(item.key, item.before, engine: engine)
        }
    }

    private static func current(_ key: String, engine: TranscriptionEngine?) -> String? {
        guard let engine else { return nil }
        switch key {
        case sessionModeKey: return engine.sessionMode.rawValue
        case transcriptionKey: return engine.transcriptionEngine.rawValue
        case diarizationKey: return engine.diarizationEngine.rawValue
        case languageKey: return engine.selectedLanguageCode ?? "auto"
        case whisperModelKey: return engine.whisperModelName
        case parakeetModelKey: return engine.parakeetModelName
        default: return nil
        }
    }

    private static func set(_ key: String, _ value: String?, engine: TranscriptionEngine?) {
        guard let engine, let value else { return }
        switch key {
        case sessionModeKey:
            if let m = SessionMode(rawValue: value) { engine.sessionMode = m }
        case transcriptionKey:
            if let k = TranscriptionEngineKind(rawValue: value) { engine.setTranscriptionEngineFromPortal(k) }
        case diarizationKey:
            if let k = DiarizationEngineKind(rawValue: value) { engine.diarizationEngine = k }
        case languageKey:
            engine.selectedLanguageCode = (value == "auto") ? nil : value
        case whisperModelKey:
            engine.whisperModelName = value
        case parakeetModelKey:
            engine.parakeetModelName = value
        default:
            break
        }
    }
}

// MARK: - Transcript revision index

/// Tracks which segments changed at which revision so polls return diffs.
/// In-memory only; `epoch` in responses tells the browser when to start over
/// (app relaunch).
struct PortalTranscriptIndex {
    private(set) var rev = 0
    private(set) var orderRev = 0
    private(set) var metaRev = 0
    private(set) var order: [UUID] = []
    private var segmentRevs: [UUID: (signature: String, rev: Int)] = [:]

    /// Returns true when anything changed.
    @discardableResult
    mutating func update(_ segments: [TranscriptSegment]) -> Bool {
        let next = rev + 1
        var changed = false
        for s in segments {
            let sig = Self.signature(s)
            if segmentRevs[s.id]?.signature != sig {
                segmentRevs[s.id] = (sig, next)
                changed = true
            }
        }
        let ids = segments.map(\.id)
        if ids != order {
            order = ids
            orderRev = next
            changed = true
            let live = Set(ids)
            segmentRevs = segmentRevs.filter { live.contains($0.key) }
        }
        if changed { rev = next }
        return changed
    }

    /// Speakers / pins / title changed.
    mutating func bumpMeta() {
        rev += 1
        metaRev = rev
    }

    func revision(of id: UUID) -> Int { segmentRevs[id]?.rev ?? 0 }

    static func signature(_ s: TranscriptSegment) -> String {
        "\(s.text)\u{1F}\(s.start)\u{1F}\(s.end)\u{1F}\(s.speaker ?? "")\u{1F}\(s.needsReview ?? false)\u{1F}\(s.userEdited ?? false)\u{1F}\(s.rawText ?? "")"
    }
}

extension TranscriptSegment {
    /// Whether "Restore verbatim" would change anything.
    var portalRestorable: Bool {
        guard let raw = rawText, !raw.isEmpty else { return false }
        return raw != text
    }
}

// MARK: - Upload sessions

struct PortalUploadSession {
    let id: UUID
    let owner: String
    let originalName: String
    let directory: URL
    let fileURL: URL
    let size: Int64
    var received: Int64
    let createdAt: Date
}

// MARK: - Wire DTOs

struct PortalSegmentDTO: Encodable {
    let id: String
    let start: Double
    let end: Double
    let text: String
    let speaker: String?
    let review: Bool
    let edited: Bool
    /// The verbatim ASR text differs from what is shown (cleanup, refinement
    /// or a web/Mac edit replaced it), so "Restore verbatim" has something to do.
    let restorable: Bool
}

struct PortalSpeakerDTO: Encodable {
    let label: String
    let name: String
    /// rename | voiceprint | machine — what `name` comes from.
    let source: String
    let count: Int
    /// The voiceprint identity on this speaker, if any — present even when a
    /// rename is what's displayed, so the page can offer to clear it.
    let identity: String?
}

/// Names a speaker can be identified as: people already in this transcript
/// first, then the whole enrolled catalog.
struct PortalIdentitiesDTO: Encodable {
    struct Group: Encodable { let name: String; let names: [String] }
    let session: [String]
    /// The enrolled catalog, grouped as the Mac's identify sheet shows it.
    let library: [Group]
    /// False while the template bank is still loading (or failed) on the Mac.
    let libraryLoaded: Bool
}

struct PortalPinDTO: Encodable {
    let id: String
    let text: String
    let speaker: String?
    let start: Double
    let end: Double
    let segmentId: String?
    let keyword: String?
}

struct PortalJobDTO: Encodable {
    let id: String
    let title: String?
    let source: String
    let isUpload: Bool
    let status: String
    let message: String?
    let submittedBy: String
    let createdAt: Date
    let startedAt: Date?
    let finishedAt: Date?
    let mode: String?
    let durationSeconds: Double?
    let processedSeconds: Double?
    let segmentCount: Int
    let queuePosition: Int?
    let canManage: Bool
    /// True while the Mac is still holding this transcript (edits sync both ways).
    let live: Bool
    /// Web player: preparing | ready | unavailable, or nil when not applicable yet.
    let media: String?
    let settings: PortalJobSettings
}

struct PortalTranscriptDTO: Encodable {
    let epoch: String
    let rev: Int
    let full: Bool
    let job: PortalJobDTO
    let order: [String]?
    let segments: [PortalSegmentDTO]
    let speakers: [PortalSpeakerDTO]?
    let pins: [PortalPinDTO]?
}

struct PortalOptionDTO: Encodable {
    let id: String
    let label: String
}

struct PortalStatusDTO: Encodable {
    struct Me: Encodable { let email: String; let isLocal: Bool; let isAdmin: Bool }
    struct Engine: Encodable {
        let label: String
        let active: Bool
        /// The engine is running a session started on the Mac, not by the portal.
        let busyWithMacSession: Bool
        let title: String?
        let activeJobId: String?
    }
    struct Queue: Encodable {
        let paused: Bool
        let queued: Int
        /// Jobs on an engine right now (ids), and how many may run at once.
        let running: [String]
        let capacity: Int
    }
    struct Options: Encodable {
        let modes: [PortalOptionDTO]
        let engines: [PortalOptionDTO]
        let diarizers: [PortalOptionDTO]
        let languages: [PortalOptionDTO]
        let exportFormats: [PortalOptionDTO]
        /// Engine id → models downloaded on the Mini. An engine with no
        /// entry (or an empty list) can't be used until a model is downloaded.
        let models: [String: [PortalOptionDTO]]
        /// Engine id → the model a portal download would fetch for it, and
        /// that download's state when one is running or has failed.
        let downloads: [String: PortalDownloadDTO]
        let speakerPlacements: [PortalOptionDTO]
        let uploadExtensions: [String]
        let maxUploadBytes: Int64
        let chunkBytes: Int
    }
    struct Defaults: Encodable {
        let mode: String
        let engine: String
        /// Engine id → the Mini's currently selected model for it.
        let models: [String: String]
        /// The Mac's Settings → Transcript Export values, used as each
        /// browser's starting export options.
        let export: PortalExportOptionsDTO
        let diarization: String
        let language: String
        let expectedSpeakers: Int
        let liveFromStart: Bool
        let cleanup: Bool
    }
    let me: Me
    let engine: Engine
    let queue: Queue
    let options: Options
    let defaults: Defaults
    let epoch: String
}

// Request bodies

struct PortalCreateJobBody: Decodable {
    let url: String
    let settings: PortalJobSettings?
}

struct PortalCreateUploadBody: Decodable {
    let filename: String
    let size: Int64
    /// Optional here (required at finish): lets the server reject a bad
    /// engine/model choice BEFORE a multi-gigabyte upload, not after.
    let settings: PortalJobSettings?
}

struct PortalFinishUploadBody: Decodable {
    let settings: PortalJobSettings?
}

struct PortalRenameBody: Decodable {
    let label: String
    let name: String
}

struct PortalPinBody: Decodable {
    let segmentId: String
}

/// Identify a whole speaker (cluster) as a stored identity; empty name clears.
struct PortalIdentifyBody: Decodable {
    let label: String
    let name: String
}

/// Move segments to another speaker. `speaker` is an existing machine label;
/// `newSpeaker: true` mints a fresh "Speaker N" instead (diarizer merged two
/// people). Optional `name` identifies that target in the same step.
struct PortalReassignBody: Decodable {
    let segmentIds: [String]
    let speaker: String?
    let newSpeaker: Bool?
    let name: String?
}

struct PortalSegmentTextBody: Decodable {
    let segmentId: String
    let text: String
}

struct PortalSegmentIDsBody: Decodable {
    let segmentIds: [String]
}

struct PortalProbeBody: Decodable {
    let url: String
}

/// Result of checking a pasted link before submitting it.
struct PortalProbeDTO: Encodable {
    let url: String
    /// recording | live | failed | busy
    let kind: String
    let durationSeconds: Double?
    let title: String?
    /// e.g. "YouTube", "U.S. Senate", "HLS Stream"
    let source: String?
    let message: String?
}

struct PortalExportOptionsDTO: Encodable {
    let timestamps: Bool
    let bold: Bool
    let placement: String
    let title: Bool
    let source: Bool
    let generated: Bool
}

struct PortalDownloadDTO: Encodable {
    /// The model that would be (or is being) downloaded.
    let model: String
    let label: String
    /// idle | downloading | loading | error
    let state: String
    let progress: Double?
    let message: String?
}

struct PortalDownloadBody: Decodable {
    let engine: String
}

struct PortalPauseBody: Decodable {
    let paused: Bool
}
