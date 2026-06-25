import Foundation
import SwiftUI
import Combine

/// Service that manages voice templates and performs speaker
/// identification against runtime embeddings from FluidAudio's
/// diarization pipeline.
///
/// **Architecture overview.**
/// - **Templates**: loaded from R2 (single combined `voiceprints.json`)
///   with a local cache for offline use. Refreshed on app launch and
///   on demand via the Settings refresh button.
/// - **Registry**: per-session map of FluidAudio cluster IDs
///   ("Speaker 1", "Speaker 2") to identified speakers. Populated by
///   automatic matching (cosine similarity against templates) and
///   manual user reassignments. Cleared when a new transcription
///   session begins.
/// - **Matching**: cosine similarity between L2-normalized embeddings.
///   Templates are normalized at enrollment time; runtime embeddings
///   from FluidAudio get normalized at match time. Best match above
///   the configurable confidence threshold wins; below the threshold,
///   the cluster keeps its generic "Speaker N" label.
///
/// **Threading.** `@MainActor` to match how SwiftUI views observe it.
/// All identification + registry operations are fast (microseconds for
/// a 500-template lookup) so main-thread is fine. R2 refresh runs in
/// a Task and hops to main only when updating state.
///
/// **Why singleton.** Templates + registry are global app state, read
/// from multiple views (Settings, TranscriptPane, Sidebar) and the
/// transcription engine. Passing through every initializer would
/// be noise. Singleton with @MainActor isolation is the same pattern
/// CustomDictionary uses.
@MainActor
final class VoiceprintService: ObservableObject {

    static let shared = VoiceprintService()

    // MARK: - Published state

    /// Loaded voice templates from R2 or local cache. Empty until the
    /// first successful load completes.
    @Published private(set) var templates: [Voiceprint] = []

    /// Per-session map of FluidAudio cluster ID → identified speaker.
    /// Populated by `identifyNewSpeakers` (automatic) and
    /// `setManualIdentification` (user-driven). Cleared on session
    /// start via `resetForNewSession()`.
    @Published private(set) var identifications: [String: Identification] = [:]

    /// State of the R2 refresh — drives the Settings UI to show
    /// loading spinners, error messages, etc.
    @Published private(set) var loadState: LoadState = .idle

    /// Wall-clock time of the last successful R2 refresh. Nil before
    /// the first refresh completes. Surfaced in Settings so users
    /// can tell when templates are stale.
    @Published private(set) var lastRefreshedAt: Date?

    // MARK: - User preferences

    /// Master toggle: when false, identification is skipped entirely.
    /// Useful for users who don't want voice identification or are
    /// debugging diarization issues without the extra layer.
    @AppStorage("voiceprint.enabled")
    var isEnabled: Bool = true

    /// Above this similarity, identifications are applied without
    /// any uncertainty marker. Tuned conservatively — 0.75 means
    /// "almost certainly the same speaker" in WeSpeaker's embedding
    /// space.
    @AppStorage("voiceprint.highConfidenceThreshold")
    var highConfidenceThreshold: Double = 0.75

    /// Below this similarity, matches are discarded entirely and
    /// the cluster keeps its generic "Speaker N" label. Between low
    /// and high, the match is applied with an uncertainty marker
    /// (italicized name in the transcript). 0.50 is roughly the
    /// VoxCeleb EER threshold — beneath it, matches are noisier
    /// than signal.
    @AppStorage("voiceprint.lowConfidenceThreshold")
    var lowConfidenceThreshold: Double = 0.50

    /// R2 URL for the combined voiceprints.json. Editable in Settings
    /// in case the user moves the file or has a private mirror.
    /// Default points at the production R2 bucket.
    @AppStorage("voiceprint.r2URL")
    var r2URL: String = "https://pub-201cda1156ec4d469157edb7a3ec216d.r2.dev/voiceprints.json"

    // MARK: - Types

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(count: Int)
        case error(String)
    }

    /// One enrolled voice template. Matches the JSON shape produced
    /// by the SpeakerEnroll CLI. Most metadata fields are optional
    /// so partial / legacy JSONs still decode.
    struct Voiceprint: Codable, Identifiable, Equatable {
        var id: String { name }
        let name: String
        let embedding: [Float]
        let nClips: Int?
        let embeddingModel: String?
        let createdAt: String?

        enum CodingKeys: String, CodingKey {
            case name, embedding
            case nClips = "n_clips"
            case embeddingModel = "embedding_model"
            case createdAt = "created_at"
        }
    }

    /// Top-level JSON envelope for the R2-hosted voiceprints file.
    /// Versioned so a future schema change doesn't break old clients.
    /// `templates` is the only required field; the rest are metadata.
    struct VoiceprintsPayload: Codable {
        let version: Int
        let updatedAt: String?
        let embeddingModel: String?
        let templates: [Voiceprint]

        enum CodingKeys: String, CodingKey {
            case version, templates
            case updatedAt = "updated_at"
            case embeddingModel = "embedding_model"
        }
    }

    /// A single registry entry — one speaker cluster's identified
    /// name + confidence + provenance.
    struct Identification: Equatable {
        let name: String
        /// Cosine similarity for automatic identifications (0.5 – 1.0
        /// range in practice given thresholding). Always 1.0 for
        /// manual reassignments — the user is certain.
        let confidence: Double
        /// True when the user manually assigned this identity.
        /// Manual identifications take priority over automatic ones
        /// and aren't overwritten by `identifyNewSpeakers`.
        let isManual: Bool
    }

    // MARK: - Init

    private init() {
        // Load local cache synchronously so the first session can
        // start identifying speakers immediately even on a cold launch
        // before R2 responds. R2 refresh runs in the background and
        // overwrites the cache when it succeeds.
        loadFromLocalCache()
        Task { await refreshFromRemote() }
    }

    // MARK: - Identification

    /// Identify a speaker from a runtime embedding. Returns the best
    /// match if its similarity exceeds the low threshold. Returns nil
    /// if no match clears that bar — caller should keep the generic
    /// cluster label.
    ///
    /// Walks all templates linearly (O(N × dim) where N = template
    /// count and dim = 256). For 500 templates that's ~128K
    /// multiply-adds per identification, well under a millisecond.
    /// Suitable for per-segment identification if we ever want that
    /// granularity — currently used per-cluster (once per new
    /// FluidAudio cluster ID per session).
    func identify(embedding: [Float]) -> Identification? {
        guard isEnabled, !templates.isEmpty else { return nil }
        guard !embedding.isEmpty else { return nil }

        // Runtime embeddings from FluidAudio's SpeakerManager aren't
        // necessarily L2-normalized. Templates were normalized at
        // enrollment, so for cosine similarity to reduce to dot
        // product we need both sides normalized. Normalizing the
        // runtime embedding here costs one sqrt + 256 multiplies,
        // ~5µs.
        let normalizedQuery = Self.l2Normalize(embedding)

        var bestName: String? = nil
        var bestSimilarity: Double = -1.0
        for template in templates {
            let sim = cosineSimilarity(normalizedQuery, template.embedding)
            if sim > bestSimilarity {
                bestSimilarity = sim
                bestName = template.name
            }
        }

        guard let name = bestName, bestSimilarity >= lowConfidenceThreshold else {
            return nil
        }
        return Identification(name: name, confidence: bestSimilarity, isManual: false)
    }

    /// Run identification for a batch of cluster ID → embedding pairs,
    /// updating the registry for any cluster that doesn't already have
    /// a manual identification. Called from `TranscriptionEngine` after
    /// each diarization pass; skips clusters with manual reassignments
    /// to avoid clobbering user corrections.
    func identifyNewSpeakers(_ clusterEmbeddings: [String: [Float]]) {
        guard isEnabled else { return }

        for (clusterId, embedding) in clusterEmbeddings {
            // Manual reassignments are sticky — don't let automatic
            // matching override them. The user explicitly said "this
            // cluster is Senator Warren"; we trust that over any
            // cosine similarity outcome.
            if let existing = identifications[clusterId], existing.isManual {
                continue
            }

            // Automatic identifications get re-run on every batch.
            // This means if FluidAudio's cluster embedding drifts as
            // more audio accumulates, the identification may switch.
            // Usually a good thing — more audio = better embedding.
            // The drift is bounded since FluidAudio keeps a running
            // mean within each cluster.
            if let id = identify(embedding: embedding) {
                identifications[clusterId] = id
            }
        }
    }

    /// Manually assign a speaker to a cluster. Stored as `isManual=true`
    /// so automatic matching won't overwrite it. Confidence is
    /// recorded as 1.0 because the user is certain.
    func setManualIdentification(clusterId: String, name: String) {
        identifications[clusterId] = Identification(
            name: name,
            confidence: 1.0,
            isManual: true
        )
    }

    /// Remove a manual identification for a cluster, reverting to
    /// automatic identification (if any) or the generic label. The
    /// next `identifyNewSpeakers` batch may re-populate the entry.
    func clearIdentification(clusterId: String) {
        identifications.removeValue(forKey: clusterId)
    }

    /// Clear the entire registry. Called by `TranscriptionEngine` when
    /// a new session starts — without this, "Speaker 1" from session A
    /// would carry its identification into "Speaker 1" of session B
    /// (different actual person, same cluster ID).
    func resetForNewSession() {
        identifications.removeAll()
    }

    /// Look up the display info for a cluster ID. The transcript pane
    /// uses this to decide what to show next to each speaker group.
    /// Returns (displayName, isIdentified, isUncertain):
    ///   - `isIdentified`: false → fall back to generic cluster ID
    ///   - `isUncertain`: true → render in italics or with `?`
    func displayInfo(forClusterId clusterId: String) -> (name: String, isIdentified: Bool, isUncertain: Bool) {
        guard let id = identifications[clusterId] else {
            return (clusterId, false, false)
        }
        // Manual reassignments are never uncertain — user said so.
        let uncertain = !id.isManual && id.confidence < highConfidenceThreshold
        return (id.name, true, uncertain)
    }

    // MARK: - R2 loading

    /// Fetch the latest voiceprints.json from R2. Updates `templates`
    /// and the local cache on success. On failure, leaves existing
    /// templates intact (so a flaky network doesn't wipe out the
    /// user's working state) and surfaces the error via `loadState`.
    func refreshFromRemote() async {
        guard let url = URL(string: r2URL) else {
            loadState = .error("Invalid R2 URL")
            return
        }

        loadState = .loading

        do {
            // Plain URLSession — no cache (R2 returns its own
            // Cache-Control), no auth, no special headers. The
            // bucket is public.
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                loadState = .error("HTTP \(code)")
                return
            }

            let payload = try JSONDecoder().decode(VoiceprintsPayload.self, from: data)
            templates = payload.templates.sorted { $0.name < $1.name }
            lastRefreshedAt = Date()
            loadState = .loaded(count: templates.count)
            saveToLocalCache(data)

            print("[Voiceprint] Loaded \(templates.count) templates from R2")
        } catch {
            print("[Voiceprint] R2 refresh failed: \(error.localizedDescription) — keeping existing templates")
            loadState = .error(error.localizedDescription)
        }
    }

    /// Load templates from the local cache on startup. Synchronous
    /// because `init()` runs at app launch and we want templates
    /// available before the first transcription session can start.
    private func loadFromLocalCache() {
        guard let url = localCacheURL(),
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder().decode(VoiceprintsPayload.self, from: data)
            templates = payload.templates.sorted { $0.name < $1.name }
            print("[Voiceprint] Loaded \(templates.count) templates from local cache")
        } catch {
            print("[Voiceprint] Local cache load failed: \(error.localizedDescription)")
        }
    }

    private func saveToLocalCache(_ data: Data) {
        guard let url = localCacheURL() else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url)
    }

    /// Local cache path. Lives under Application Support alongside
    /// the unified models root (but not inside it, since it's not a
    /// model — it's user-derived metadata about models).
    private func localCacheURL() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("StreamScribe")
            .appendingPathComponent("voiceprints.json")
    }

    // MARK: - Math

    /// Cosine similarity between two L2-normalized embeddings reduces
    /// to a dot product. Clamp to [-1, 1] for numerical safety —
    /// float arithmetic can produce 1.0000003 etc.
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
        }
        return Double(max(-1, min(1, dot)))
    }

    /// L2-normalize a vector so its magnitude equals 1. Defensive
    /// against all-zero input (returns input unchanged) which would
    /// otherwise produce NaN.
    static func l2Normalize(_ v: [Float]) -> [Float] {
        let magnitude = sqrt(v.map { $0 * $0 }.reduce(0, +))
        guard magnitude > 0 else { return v }
        return v.map { $0 / magnitude }
    }
}
