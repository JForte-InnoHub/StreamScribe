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

    /// Templates grouped by source category, preserving the order of
    /// the source URLs in `r2URLs`. Populated by `refreshFromRemote`;
    /// empty when we've only loaded from cache (categories aren't
    /// persisted in the cache — see the comment in `saveToLocalCache`
    /// for why).
    ///
    /// The UI renders this as separate collapsible sections when
    /// non-empty. When empty (cache-only mode, or first-load-still-
    /// in-flight), the UI falls back to a flat list of `templates`
    /// so users always see what's loaded regardless of whether a
    /// live refresh has completed.
    @Published private(set) var categorizedTemplates: [CategoryGroup] = []

    /// Per-session map of FluidAudio cluster ID → identified speaker.
    /// Populated by `setManualIdentification` (user-driven cluster-level
    /// reassignment via the "Identify Speaker" context menu). Cleared
    /// on session start via `resetForNewSession()`.
    ///
    /// **Cluster-level is now manual-only.** Automatic identification
    /// has moved to per-segment matching (see `segmentIdentifications`)
    /// because the cluster-level approach couldn't disambiguate
    /// diarizer-merged speakers — when LSEEND lumped Senator A and
    /// Senator B into one cluster, the cluster's running-mean embedding
    /// landed somewhere between them and matched neither well. Per-
    /// segment matching catches the individual identities at segment
    /// granularity.
    @Published private(set) var identifications: [String: Identification] = [:]

    /// Names of speakers identified during the current transcription
    /// session — union of every name assigned via automatic matching
    /// (`identifySegment`), manual cluster-level identification
    /// (`setManualIdentification`), and manual per-segment
    /// identification (`setManualSegmentIdentification`).
    ///
    /// **Why session-scoped.** Context menus for speaker
    /// identification used to render the ENTIRE voice-template
    /// library (~660 templates), which broke NSMenu's tracking
    /// (`didChangeSubmenu: rep returned item view with wrong item:`
    /// spam) and made the menu unresponsive. The new UI shows only
    /// speakers already used in this session directly in the menu —
    /// a small, workable list — with an "Other speaker…" fallback
    /// that opens a search sheet for the full library.
    ///
    /// **Persistence semantics.** Additive within a session; never
    /// shrinks even when a user clears an identification. Full
    /// reset only on `resetForNewSession`. So a user who assigns
    /// "Elizabeth Warren" once, later clears that identification,
    /// and then wants to re-identify a different segment as Warren
    /// still sees her in the immediate menu without having to
    /// re-search.
    @Published private(set) var sessionSpeakerHistory: Set<String> = []

    // MARK: - Cluster embedding aggregation
    //
    // Rather than matching each segment's embedding independently
    // against the template library (which produced inconsistent
    // "same speaker cluster gets identified as 3 different people"
    // outcomes and false positives from short/noisy segments), we
    // maintain a running average of each cluster's embeddings and
    // match at the cluster level.
    //
    // **Why this works better:**
    //   - **Trust diarization for grouping.** Diarization is more
    //     accurate at "these audio moments belong to the same person"
    //     than voiceprint matching is at "who is this person" — so
    //     let diarization group first, then identify each group.
    //   - **Better SNR at match time.** An average of 20 embeddings
    //     has ~4.5x lower noise floor than a single embedding
    //     (√20 ≈ 4.47). Weak matches on single noisy segments
    //     disappear; strong matches on the aggregated cluster stay.
    //   - **Consistent labeling.** If cluster 客 ID 5 gets matched to
    //     "Todd Blanche," every segment in cluster 5 becomes Todd
    //     Blanche automatically. No majority-vote smoothing needed.
    //
    // **Implementation as running totals** rather than a list of
    // embeddings per cluster: constant memory per cluster (256 floats
    // + 1 int), no allocation on each add, average is one division
    // pass at match time. Trade-off is that we can't remove an
    // embedding after the fact — fine because diarization rarely
    // moves segments between clusters after they're assigned.
    private var clusterEmbeddingSums: [String: [Float]] = [:]
    private var clusterEmbeddingCounts: [String: Int] = [:]

    /// Every extracted embedding, keyed by segment UUID — the raw
    /// evidence, independent of which cluster it was credited to at
    /// extraction time. This is what makes identity SURVIVE
    /// re-diarization: when a whole-file/post-finish pass relabels
    /// segments, `reaggregate` rebuilds cluster evidence from these
    /// against the NEW labels instead of orphaning it against the
    /// old ones (unification stage 2 / F3, 2026-07). ~1 KB per
    /// segment (256-dim Float); a 3-hour hearing is a few MB.
    private var retainedEmbeddings: [UUID: [Float]] = [:]

    /// Count of embeddings contributed to each cluster's running
    /// total since the cluster was last identified. Used to decide
    /// when to re-run identification — see `identifyCluster` gates.
    private var clusterEmbeddingsSinceLastMatch: [String: Int] = [:]

    /// Per-session map of segment UUID → identified speaker. Populated
    /// by automatic per-segment matching (after WeSpeaker extraction
    /// runs on a segment's audio) and by manual per-segment overrides.
    /// Cleared on session start.
    ///
    /// **Why segment-level matters.** When the diarizer merges two
    /// speakers into one cluster, the cluster has one ID ("Speaker 1")
    /// but its segments individually contain different voices. Per-
    /// segment matching identifies each segment from its own audio,
    /// so a merged cluster produces segments with different identified
    /// names — which the transcript view then groups by effective
    /// name, visually splitting the merge.

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
    /// User-editable list of remote source URLs, ONE URL PER LINE.
    /// Multi-line support was added so users can organize their
    /// templates into separate JSON files by category (e.g.
    /// `voiceprints-House.json`, `voiceprints-Senate.json`) and load
    /// them all as a merged pool. Backward-compatible with the
    /// original single-URL configuration: a value with no newlines
    /// is treated as one URL.
    ///
    /// The AppStorage KEY stays `voiceprint.r2URL` (singular) even
    /// though the value is now plural. Renaming the key would strand
    /// existing users' customized value on upgrade. Existing single-
    /// URL settings continue to work unchanged.
    @AppStorage("voiceprint.r2URL")
    var r2URLsRaw: String = """
        https://pub-201cda1156ec4d469157edb7a3ec216d.r2.dev/voiceprints-House.json
        https://pub-201cda1156ec4d469157edb7a3ec216d.r2.dev/voiceprints-Senate.json
        https://pub-201cda1156ec4d469157edb7a3ec216d.r2.dev/voiceprints-Executive.json
        https://pub-201cda1156ec4d469157edb7a3ec216d.r2.dev/voiceprints-Governors.json
        https://pub-201cda1156ec4d469157edb7a3ec216d.r2.dev/voiceprints-Media.json
        https://pub-201cda1156ec4d469157edb7a3ec216d.r2.dev/voiceprints-Other.json
        """

    /// Parsed list of URLs from `r2URLsRaw`. Splits on newlines,
    /// trims whitespace, drops empty lines, and drops entries that
    /// don't parse as URLs. Called on every refresh so mid-session
    /// edits in Settings take effect on the next refresh without
    /// requiring an app restart.
    var r2URLs: [URL] {
        r2URLsRaw
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { URL(string: $0) }
    }

    // MARK: - Types

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(count: Int)
        case error(String)
    }

    /// A group of templates loaded from a single source URL.
    /// The `name` derives from the URL filename: for a URL like
    /// `.../voiceprints-House.json`, the category is "House".
    /// Rendered as a collapsible section in the Settings UI.
    struct CategoryGroup: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let templates: [Voiceprint]
    }

    /// Append a `?_ts=<epoch>` query parameter to force CDNs to
    /// treat the request as a fresh URL, bypassing edge caches that
    /// key on URL rather than headers. Used exclusively during
    /// refresh — the resulting URL isn't stored, only requested.
    ///
    /// Cloudflare R2 (and most CDNs) fingerprint cached responses
    /// by full URL including query string. Adding a unique timestamp
    /// makes each refresh a cache miss at the edge, forcing R2 to
    /// serve the latest object from origin. Trivial overhead —
    /// milliseconds per request even on cache misses.
    ///
    /// If the URL already has query params, the timestamp gets
    /// appended alongside. Never overwrites existing params.
    private func bustCache(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "_ts", value: String(Int(Date().timeIntervalSince1970))))
        components.queryItems = items
        return components.url ?? url
    }

    /// Derive a human-readable category name from a source URL.
    ///
    /// Recognized pattern: `voiceprints-<Category>.json` (or `_` in
    /// place of `-`; case-insensitive on the `voiceprints` prefix).
    /// Falls back to the URL's filename without extension for
    /// URLs that don't fit the pattern — so users hosting their
    /// files under different naming conventions still see something
    /// meaningful.
    ///
    /// **Special case: `voiceprints.json` (no suffix).** Returns
    /// "Uncategorized" so a single monolithic file doesn't produce
    /// a section named "voiceprints" that looks like a bug.
    static func categoryName(from url: URL) -> String {
        let filename = url.lastPathComponent
        let base = filename
            .split(separator: ".")
            .dropLast()
            .joined(separator: ".")
        guard !base.isEmpty else { return "Uncategorized" }

        // Match the canonical pattern first.
        let lowerBase = base.lowercased()
        if lowerBase.hasPrefix("voiceprints") {
            var suffix = String(base.dropFirst("voiceprints".count))
            while let first = suffix.first, first == "-" || first == "_" || first == " " {
                suffix.removeFirst()
            }
            if suffix.isEmpty {
                return "Uncategorized"
            }
            return suffix
        }
        // Fallback for non-canonical filenames.
        return base
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

    /// Run identification for a single segment. Updates
    /// `segmentIdentifications` if a match exists above the low
    /// threshold; leaves the registry unchanged otherwise. Skips
    /// segments that already have a manual identification (user
    /// corrections are sticky).
    ///
    /// Add a segment's embedding to its cluster's running average,
    /// then (potentially) run cluster-level identification. This is
    /// the primary automatic identification path — replaces the
    /// older per-segment matching approach that produced inconsistent
    /// identifications across segments in the same cluster.
    ///
    /// **What this does:**
    ///   1. Adds the segment's embedding to `clusterEmbeddingSums[cluster]`
    ///      (element-wise addition) and increments the count.
    ///   2. Checks if the cluster is due for (re-)identification. If
    ///      it is, computes the L2-normalized running average and
    ///      matches against templates. Result goes in
    ///      `identifications[cluster]`, applying to every segment
    ///      in that cluster automatically via `displayInfo`.
    ///
    /// **Identification cadence:**
    ///   - First identification at 3 accumulated embeddings — enough
    ///     to be more robust than a single-segment match, low enough
    ///     to identify short clusters.
    ///   - Re-identify every 5 new embeddings after that — cheap
    ///     (~1ms against 660 templates) but avoids re-matching on
    ///     every single new segment. As more audio accumulates, the
    ///     average stabilizes and identification becomes more
    ///     reliable; re-matching lets us "upgrade" from an early
    ///     tentative match to a stronger one.
    ///
    /// **Manual identification wins.** If the user has manually set a
    /// cluster or per-segment ID, we still update the running total
    /// (in case they clear the manual override later) but skip the
    /// automatic identify step so we don't clobber their choice.
    ///
    /// **Segment ID parameter is unused for aggregation** but kept
    /// in the signature for API compatibility with the older per-
    /// segment path. Also lets us support per-segment manual
    /// identifications as before if needed.
    /// Record one segment's embedding as evidence for its cluster and
    /// re-run cluster identification when due. This is the ONLY entry
    /// point for automatic identification, and it operates purely at
    /// cluster level — identity always lands on a diarizer speaker
    /// ("Speaker N"), never on a floating segment. (Unification,
    /// 2026-07: per-segment identity state was abolished; identifying
    /// a sub-cluster selection now SPLITS it into a new machine
    /// speaker instead — see TranscriptionEngine.identifySegments.)
    ///
    func recordEmbedding(segmentId: UUID, embedding: [Float], clusterId: String?) {
        guard isEnabled else { return }
        retainedEmbeddings[segmentId] = embedding

        // Add to cluster running total — always, regardless of
        // manual override state. Keeps the average correct if the
        // manual identification is later cleared.
        if let clusterId {
            addEmbeddingToCluster(clusterId: clusterId, embedding: embedding)
        }

        // Manual cluster assignment is user truth — don't re-match.
        if let clusterId,
           let clusterIdent = identifications[clusterId], clusterIdent.isManual {
            return
        }

        // Run identification for this cluster if it's due.
        if let clusterId {
            identifyCluster(clusterId: clusterId)
        }
    }

    /// Add an embedding to the running total for a cluster. Element-
    /// wise addition; count increments by 1. The `since-last-match`
    /// counter also increments, driving when we re-run identification.
    private func addEmbeddingToCluster(clusterId: String, embedding: [Float]) {
        if var existingSum = clusterEmbeddingSums[clusterId] {
            let limit = min(existingSum.count, embedding.count)
            for i in 0..<limit {
                existingSum[i] += embedding[i]
            }
            clusterEmbeddingSums[clusterId] = existingSum
        } else {
            // First embedding for this cluster — copy in as the sum.
            clusterEmbeddingSums[clusterId] = embedding
        }
        clusterEmbeddingCounts[clusterId, default: 0] += 1
        clusterEmbeddingsSinceLastMatch[clusterId, default: 0] += 1
    }

    /// Match a cluster's running-average embedding against templates
    /// and store the result. Skips if:
    ///   - Cluster has fewer than 3 embeddings (too little data for
    ///     reliable matching)
    ///   - Cluster was matched recently (fewer than 5 new embeddings
    ///     since last match)
    ///   - Cluster has a manual identification
    ///
    /// **Why gates instead of always matching:** matching is cheap
    /// but not free (~1ms against ~660 templates for cosine similarity),
    /// and the identity of a cluster stabilizes as more audio arrives.
    /// Re-running every N embeddings gives us the benefit of refinement
    /// without the cost of matching on every segment.
    private func identifyCluster(clusterId: String) {
        // Skip if user has locked this in.
        if let existing = identifications[clusterId], existing.isManual { return }

        guard let sum = clusterEmbeddingSums[clusterId],
              let count = clusterEmbeddingCounts[clusterId],
              count >= 3 else { return }

        // Only match if enough new evidence has arrived since last
        // match. Prevents re-matching on every single segment.
        let sinceLastMatch = clusterEmbeddingsSinceLastMatch[clusterId, default: 0]
        let previouslyIdentified = identifications[clusterId] != nil
        if previouslyIdentified && sinceLastMatch < 5 { return }

        // Compute running average and L2-normalize. Templates are
        // also L2-normalized (see `refreshFromRemote`), so cosine
        // similarity reduces to dot product.
        let scale = 1.0 / Float(count)
        var average = sum.map { $0 * scale }
        var normSquared: Float = 0
        for value in average { normSquared += value * value }
        let norm = sqrt(normSquared)
        if norm > 0 {
            for i in 0..<average.count {
                average[i] /= norm
            }
        }

        // Match against templates. If the match hits our threshold,
        // apply to the cluster. If not, leave the cluster
        // unidentified (or keep its previous identification if any —
        // don't overwrite with nil).
        if let newMatch = identify(embedding: average) {
            let previousName = identifications[clusterId]?.name
            identifications[clusterId] = newMatch
            sessionSpeakerHistory.insert(newMatch.name)
            if previousName != newMatch.name {
                print("[Voiceprint] Cluster \(clusterId) → \(newMatch.name) (conf \(String(format: "%.3f", newMatch.confidence)), \(count) segs)")
            }
        }

        clusterEmbeddingsSinceLastMatch[clusterId] = 0
    }

    /// Force cluster identification on every cluster that has an
    /// aggregated embedding, regardless of how many segments since
    /// last match. Called at session end (static mode) or when the
    /// user explicitly triggers a re-scan. Ensures short clusters
    /// that never crossed the "5 new segments since last match"
    /// threshold still get their final identification pass.
    ///
    /// Manual identifications are still respected — we don't
    /// re-match clusters where the user has set a name.
    func forceMatchAllPendingClusters() {
        for clusterId in clusterEmbeddingCounts.keys {
            // Temporarily bump the counter above the threshold so
            // `identifyCluster` doesn't gate us out.
            clusterEmbeddingsSinceLastMatch[clusterId] = 5
            identifyCluster(clusterId: clusterId)
        }
    }

    /// Whether we already hold an embedding for this segment — lets
    /// the static identification pass skip a second WeSpeaker
    /// extraction for audio the live pass already processed.
    func hasRetainedEmbedding(segmentId: UUID) -> Bool {
        retainedEmbeddings[segmentId] != nil
    }

    /// Re-ground ALL retained evidence on a fresh segment→cluster
    /// assignment map (the FINAL labels after a whole-file or
    /// post-finish diarization pass). Wipes per-cluster evidence and
    /// non-manual identifications, rebuilds sums from retained
    /// embeddings, then force-matches everything. Manual
    /// identifications survive untouched — user truth outranks any
    /// relabeling.
    func reaggregate(assignments: [UUID: String]) {
        clusterEmbeddingSums.removeAll()
        clusterEmbeddingCounts.removeAll()
        clusterEmbeddingsSinceLastMatch.removeAll()
        identifications = identifications.filter { $0.value.isManual }

        var used = 0
        for (segmentId, clusterId) in assignments {
            guard let emb = retainedEmbeddings[segmentId] else { continue }
            addEmbeddingToCluster(clusterId: clusterId, embedding: emb)
            used += 1
        }
        forceMatchAllPendingClusters()
        print("[Voiceprint] Re-aggregated \(used)/\(assignments.count) assignments across \(clusterEmbeddingCounts.count) clusters")
    }

    /// L2-normalized centroid of a cluster's accumulated evidence, or
    /// nil if the cluster has none. Same math as `identifyCluster`'s
    /// matching average — exposed for the engine's consolidation pass
    /// (centroid-similarity merging).
    func clusterCentroid(clusterId: String) -> [Float]? {
        guard let sum = clusterEmbeddingSums[clusterId],
              let count = clusterEmbeddingCounts[clusterId],
              count > 0 else { return nil }
        let scale = 1.0 / Float(count)
        var average = sum.map { $0 * scale }
        var normSquared: Float = 0
        for value in average { normSquared += value * value }
        let norm = normSquared.squareRoot()
        guard norm > 0 else { return nil }
        for i in 0..<average.count { average[i] /= norm }
        return average
    }

    /// Number of embeddings credited to a cluster.
    func clusterEvidenceCount(clusterId: String) -> Int {
        clusterEmbeddingCounts[clusterId] ?? 0
    }

    /// The cluster's automatically matched name IF the match clears
    /// the high-confidence bar — the engine's consolidation pass uses
    /// agreement between these as merge evidence and disagreement as
    /// a cannot-merge constraint. Returns nil for manual
    /// identifications (those are constraints of their own) and for
    /// low-confidence matches (too weak to merge on).
    func confidentAutoName(forCluster clusterId: String) -> String? {
        guard let id = identifications[clusterId],
              !id.isManual,
              id.confidence >= highConfidenceThreshold else { return nil }
        return id.name
    }

    /// The cluster's manual identification name, if any.
    func manualName(forCluster clusterId: String) -> String? {
        guard let id = identifications[clusterId], id.isManual else { return nil }
        return id.name
    }

    /// Fold cluster `from`'s evidence into `into` after the engine
    /// relabels the segments. Sums and counts add; `from`'s
    /// identification is dropped (the survivor re-derives its own
    /// from the merged evidence unless manually locked); the survivor
    /// is force-matched immediately so the merged name lands without
    /// waiting for new audio.
    func consolidate(from: String, into: String) {
        if let fromSum = clusterEmbeddingSums[from] {
            if var intoSum = clusterEmbeddingSums[into], intoSum.count == fromSum.count {
                for i in 0..<intoSum.count { intoSum[i] += fromSum[i] }
                clusterEmbeddingSums[into] = intoSum
            } else if clusterEmbeddingSums[into] == nil {
                clusterEmbeddingSums[into] = fromSum
            }
            clusterEmbeddingCounts[into, default: 0] += clusterEmbeddingCounts[from] ?? 0
        }
        clusterEmbeddingSums.removeValue(forKey: from)
        clusterEmbeddingCounts.removeValue(forKey: from)
        clusterEmbeddingsSinceLastMatch.removeValue(forKey: from)
        identifications.removeValue(forKey: from)
        if identifications[into]?.isManual != true {
            clusterEmbeddingsSinceLastMatch[into] = 5
            identifyCluster(clusterId: into)
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
        // Keep the name accessible in the context menu for the rest of
        // this session — see sessionSpeakerHistory docstring.
        sessionSpeakerHistory.insert(name)
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
    /// (different actual person, same cluster ID). Also clears per-
    /// segment identifications since those are session-specific too.
    func resetForNewSession() {
        identifications.removeAll()
        retainedEmbeddings.removeAll()
        sessionSpeakerHistory.removeAll()
        clusterEmbeddingSums.removeAll()
        clusterEmbeddingCounts.removeAll()
        clusterEmbeddingsSinceLastMatch.removeAll()
    }

    /// Look up display info using just a cluster ID. Used by callers
    /// that don't have a segment UUID (legacy paths, exports).
    /// Reflects cluster-level identifications only — for per-segment
    /// detail, use `displayInfo(forSegmentId:clusterId:)`.
    /// All distinct enrolled identity names from the loaded template
    /// bank (~660 voiceprints from R2), sorted for display. This is
    /// the catalog the user picks from when manually matching an
    /// unknown speaker to a stored identity — the speaker-panel
    /// "match to stored identity" workflow (2026-07-27). Empty until
    /// the template bank finishes loading.
    var allTemplateNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for t in templates where !seen.contains(t.name) {
            seen.insert(t.name)
            names.append(t.name)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

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
    ///
    /// **Multi-URL support.** Fetches every URL in `r2URLs`, merges
    /// the results into a single `templates` list, and caches the
    /// merged payload. Failures on individual URLs are surfaced in
    /// the console log but don't abort the whole refresh — as long
    /// as one URL succeeds, `templates` gets populated. Only when
    /// ALL URLs fail is `loadState` set to `.error`.
    ///
    /// **Merge semantics.** Duplicate names across files are NOT
    /// deduplicated — if `voiceprints-House.json` and
    /// `voiceprints-Senate.json` both contain "Bernie Sanders" (e.g.
    /// clips from different sessions), both templates remain in the
    /// pool and both participate in matching. This is intentional:
    /// more templates per person = better coverage of their vocal
    /// range = more reliable matching. Duplicate NAMES in the UI
    /// (spotter picker, Identify Speaker menu) are a minor cosmetic
    /// issue but not a correctness one.
    func refreshFromRemote() async {
        let urls = r2URLs
        guard !urls.isEmpty else {
            loadState = .error("No source URLs configured")
            return
        }

        loadState = .loading

        var merged: [Voiceprint] = []
        var groups: [CategoryGroup] = []
        var errors: [(source: String, message: String)] = []

        print("[Voiceprint] Loading from \(urls.count) source URL(s)…")

        // Sequential fetch. Voice-template JSONs are typically
        // small (few KB per person, so tens to hundreds of KB per
        // file), and we're fetching a handful of files (2-10),
        // not hundreds. Sequential keeps error reporting simple
        // and avoids saturating the connection with parallel
        // requests to the same R2 bucket.
        for url in urls {
            let category = Self.categoryName(from: url)
            do {
                // Explicitly bypass all HTTP caches on refresh.
                // Default URLSession behavior honors cache-control
                // headers, which means a recently-updated
                // voiceprints-Executive.json can still return its
                // stale predecessor if either URLSession's local
                // cache or Cloudflare's edge cache has a fresh copy.
                //
                // **Why belt-and-suspenders:**
                //   - `cachePolicy = .reloadIgnoringLocalAndRemoteCacheData`
                //     tells URLSession to skip its local cache and
                //     adds a `Pragma: no-cache` header so intermediate
                //     proxies also bypass their caches.
                //   - Cache-busting query param (`?_ts=<epoch>`) makes
                //     the URL unique per request, defeating any cache
                //     that keys purely on URL rather than headers.
                //     Cloudflare's CDN cache is URL-keyed, so this is
                //     required for R2 edge-cache misses on updated
                //     files.
                //
                // Both together guarantee refresh actually fetches
                // fresh content, regardless of what upstream cache
                // policies say.
                var request = URLRequest(url: bustCache(url))
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    errors.append((url.lastPathComponent, "HTTP \(code)"))
                    print("[Voiceprint]   ✗ \(url.lastPathComponent) — HTTP \(code)")
                    continue
                }
                let payload = try JSONDecoder().decode(VoiceprintsPayload.self, from: data)
                let sorted = payload.templates.sorted { $0.name < $1.name }
                merged.append(contentsOf: sorted)
                groups.append(CategoryGroup(name: category, templates: sorted))
                print("[Voiceprint]   ✓ \(url.lastPathComponent) — \(payload.templates.count) template(s) [\(category)]")
            } catch {
                errors.append((url.lastPathComponent, error.localizedDescription))
                print("[Voiceprint]   ✗ \(url.lastPathComponent) — \(error.localizedDescription)")
            }
        }

        // Publish grouped view first — the UI reads this before it
        // reads templates, so setting them in this order avoids
        // brief flashes of "loaded but uncategorized" state.
        // Groups preserve URL-list order (House before Senate,
        // etc.) rather than alphabetizing, which matches the
        // user's mental order.
        categorizedTemplates = groups

        // Flat merged list for matching. Alphabetically sorted for
        // consistent display in pickers that consume `templates`
        // directly (spotter picker, Identify Speaker menu).
        // Matching doesn't care about order; display does.
        templates = merged.sorted { $0.name < $1.name }
        lastRefreshedAt = Date()

        // Load-state reporting:
        //   - All succeeded → .loaded (clean)
        //   - Partial success → .loaded, error count noted in
        //     console but not shown as error in UI (we have
        //     usable data)
        //   - All failed → .error with the first failure's message
        if errors.isEmpty {
            loadState = .loaded(count: templates.count)
            print("[Voiceprint] Loaded \(templates.count) template(s) from \(urls.count) source(s)")
        } else if templates.isEmpty {
            let first = errors.first?.message ?? "unknown"
            loadState = .error("All sources failed. First: \(first)")
        } else {
            loadState = .loaded(count: templates.count)
            print("[Voiceprint] Partial success: \(templates.count) template(s) loaded, \(errors.count) source(s) failed")
        }

        // Cache the merged payload so we can boot from it if a
        // future refresh fails. Version metadata gets a synthetic
        // value since we're synthesizing this from N sources.
        let cachePayload = VoiceprintsPayload(
            version: 1,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            embeddingModel: "wespeaker-en-voxceleb-resnet34",
            templates: templates
        )
        if let cacheData = try? JSONEncoder().encode(cachePayload) {
            saveToLocalCache(cacheData)
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
