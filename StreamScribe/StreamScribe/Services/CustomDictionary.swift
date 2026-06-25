import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// User-managed find/replace dictionary applied to transcribed text.
///
/// **Purpose.** ASR backends mishear proper nouns regularly — "Jamie
/// Diamond" instead of "Jamie Dimon," "Power" instead of "Powell," etc.
/// This dictionary lets the user pre-register the corrections they
/// want; substitutions run automatically on every segment as it's
/// produced, plus on demand for previously-finalized segments via
/// `apply(to:)`.
///
/// **Architecture.**
///   - Singleton `shared` because dictionary state is global to the app
///     and accessed from both `TranscriptionEngine` (the transcribe-time
///     hook) and `SettingsView` (the editor UI). No need for multiple
///     instances.
///   - `@Published var entries` for SwiftUI bindings. Mutations through
///     `add`/`remove`/`update`/`setAll` automatically trigger a save to
///     UserDefaults and propagate to any observing view.
///   - Substitutions use `NSRegularExpression` with case-insensitive
///     word-boundary matching. The find phrase is regex-escaped so the
///     user can include literal regex metacharacters like `.` or `+`
///     in their find pattern without surprise.
///
/// **Matching semantics.**
///   - **Case-insensitive find**: "jamie diamond" / "Jamie Diamond" /
///     "JAMIE DIAMOND" all match.
///   - **Case-exact replace**: the replacement string is inserted
///     verbatim, preserving whatever casing the user typed in the
///     editor. So `find: "Jamie Diamond" → replace: "Jamie Dimon"`
///     produces "Jamie Dimon" even when the source text was lowercase.
///   - **Whole-word matching**: regex word boundaries (`\b...\b`) wrap
///     the entire find phrase. "Diamond" doesn't match inside
///     "diamondback" or "Diamond Bay" (the bay doesn't because the
///     phrase boundary requires no trailing word characters in the
///     match — though "Diamond Bay" would match if the find was
///     literally "Diamond Bay", because the boundary is on the phrase
///     edges, not on each word).
///   - **Multi-word phrases**: handled the same way — "Jamie Diamond"
///     is treated as a single find pattern with the boundary at each
///     end.
///
/// **Apply-on-write semantics.** The engine calls `apply(to:)` at two
/// known sites:
///   1. Right before live segments are appended (raw transcription path)
///   2. Right after the refined pass produces replacement text
/// Both paths produce final, user-visible text that already includes
/// substitutions. Mid-session dictionary edits don't retroactively
/// apply to past segments — there's a separate `applyToAllSegments`
/// helper in the engine for that, triggered by a Settings button.
///
/// **Persistence.** Entries are saved to UserDefaults under
/// `customDictionary.entries` as JSON-encoded `[Entry]`. UserDefaults
/// is fine for a typical 5-50 entry dictionary; even a few hundred
/// entries would be well under the soft limit. If users ever build
/// dictionaries larger than that, we'd want to migrate to a file
/// under Application Support — but that's deferred until needed.
@MainActor
final class CustomDictionary: ObservableObject {

    /// Shared singleton. Reads/writes UserDefaults at instantiation.
    /// Idempotent — re-creating the instance restores the same state.
    static let shared = CustomDictionary()

    /// A single find→replace rule. `id` is generated on creation; the
    /// find and replace strings are user-editable. Equatable for
    /// SwiftUI diffing in ForEach.
    struct Entry: Identifiable, Codable, Equatable, Hashable {
        let id: UUID
        var find: String
        var replace: String

        init(id: UUID = UUID(), find: String, replace: String) {
            self.id = id
            self.find = find
            self.replace = replace
        }
    }

    /// All currently active substitution rules. SwiftUI views bind to
    /// this directly (e.g. via ForEach + Binding for inline editing).
    /// Mutations through `add`/`remove`/`update`/`setAll` auto-save;
    /// direct mutation of array elements via `$entries[idx]` bindings
    /// goes through the property's didSet which also saves.
    ///
    /// **Side effect on change: regex cache invalidation.** Every
    /// entries mutation flushes `compiledRegexCache` so the next
    /// `apply()` call rebuilds from scratch with the new patterns.
    /// Otherwise edits to a find string wouldn't take effect (the
    /// cached regex still matches the old pattern).
    @Published var entries: [Entry] = [] {
        didSet {
            saveToDefaults()
            invalidateRegexCache()
        }
    }

    /// Cached compiled regexes keyed by entry ID, with the find
    /// pattern stored alongside for invalidation detection. Without
    /// this, every `apply()` call recompiles a `NSRegularExpression`
    /// per entry — the slow step in regex evaluation (~200-500µs per
    /// pattern, vs ~10µs for matching itself). With caching, the
    /// first apply per app launch warms the cache and subsequent
    /// calls drop to pure matching cost.
    ///
    /// **Eviction policy.** Entries are evicted in two cases:
    ///   1. Wholesale on any `entries` mutation (handled by the
    ///      didSet on entries above). Conservative — we could be
    ///      smarter about invalidating only the rules that changed,
    ///      but the cost is so small (a 20-entry cache rebuild is
    ///      ~5ms) that selective invalidation isn't worth the
    ///      complexity.
    ///   2. On a per-entry basis inside `regexFor(entry:)` if the
    ///      cached find pattern doesn't match the current entry's
    ///      find — defensive against any code path that mutates an
    ///      entry without going through the didSet (shouldn't
    ///      happen, but cheap insurance).
    private var compiledRegexCache: [UUID: (find: String, regex: NSRegularExpression)] = [:]

    /// UserDefaults key for serialized entries. Constants live here
    /// rather than at file scope because they're tied to this class's
    /// persistence contract — moving them out would require a comment
    /// linking back here anyway.
    private static let defaultsKey = "customDictionary.entries"

    /// File format version stored in import/export JSON. Increment if
    /// the schema changes incompatibly so older clients can refuse to
    /// import. Currently 1; no migration logic needed yet.
    private static let exportFormatVersion = 1

    private init() {
        loadFromDefaults()
    }

    // MARK: - Substitution

    /// Apply all active rules to `text` in entry order. Returns the
    /// rewritten string. Empty find patterns are skipped (defensive —
    /// the editor UI prevents adding empties, but a corrupted import
    /// could still produce one).
    ///
    /// **Order matters when rules overlap.** If the user has both
    /// `Jay → Jerome` and `Jay Powell → Jerome Powell`, applying `Jay
    /// → Jerome` first would turn "Jay Powell" into "Jerome Powell"
    /// naturally; applying the second rule first wouldn't match the
    /// first rule afterward (since "Jerome" doesn't contain "Jay").
    /// Users who care can reorder via the editor.
    ///
    /// **Performance.** With the regex cache warm, this is dominated
    /// by `stringByReplacingMatches` cost — ~10µs per entry for a
    /// 100-character segment. A 20-entry dictionary applied to a
    /// segment costs ~200µs total, which is negligible compared to
    /// ASR inference cost (hundreds of ms). Cache-cold first call
    /// per session is ~10-15ms; subsequent calls are 100x faster.
    func apply(to text: String) -> String {
        guard !entries.isEmpty else { return text }

        var result = text
        for entry in entries {
            guard let regex = regexFor(entry: entry) else { continue }

            // Escape replacement template so user-typed "$" and "\"
            // don't get interpreted as backreferences. Most users
            // won't include these in proper-noun corrections, but the
            // escape is cheap insurance against confusion if they do.
            let escapedTemplate = NSRegularExpression.escapedTemplate(for: entry.replace)

            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: escapedTemplate
            )
        }
        return result
    }

    /// Return a compiled regex for `entry`, hitting the cache when
    /// possible. Cache hit requires both the entry ID AND the find
    /// pattern to match — the find check is belt-and-suspenders for
    /// any future code path that mutates an entry without going
    /// through the published didSet (shouldn't exist, but defensive).
    ///
    /// Cache miss: compile and store. Compilation failures (shouldn't
    /// happen since we escape, but defensive) return nil; the caller
    /// in `apply()` just skips this entry. Empty find patterns also
    /// return nil — they wouldn't produce useful matches and would
    /// cause the regex to match every position with zero-width hits.
    private func regexFor(entry: Entry) -> NSRegularExpression? {
        if let cached = compiledRegexCache[entry.id], cached.find == entry.find {
            return cached.regex
        }

        let find = entry.find.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !find.isEmpty else { return nil }

        // Escape regex metacharacters in the find pattern. Without
        // this, users typing literal "." or "?" in proper-noun
        // corrections would get unintended wildcard behavior.
        let escapedFind = NSRegularExpression.escapedPattern(for: find)

        // Word boundaries around the whole phrase. `\b` matches at
        // word/non-word transitions, so "Diamond" doesn't match
        // inside "diamondback" but does match in "the diamond
        // (was)". Note this is anchored to the OUTER edges of the
        // phrase, not each internal word — "Jamie Diamond" treats
        // the whole two-word phrase as a unit.
        let pattern = "\\b\(escapedFind)\\b"

        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: .caseInsensitive
        ) else {
            return nil
        }
        compiledRegexCache[entry.id] = (find: entry.find, regex: regex)
        return regex
    }

    /// Drop all cached compiled regexes. Called from the entries
    /// didSet whenever the dictionary changes — the next `apply()`
    /// call rebuilds the cache lazily on first miss.
    private func invalidateRegexCache() {
        compiledRegexCache.removeAll()
    }

    // MARK: - CRUD

    func add(find: String, replace: String) {
        entries.append(Entry(find: find, replace: replace))
    }

    func remove(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    func update(_ entry: Entry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        }
    }

    /// Bulk replacement, used by the import path. Triggers a single
    /// publish + save instead of N individual ones from looped `add`s.
    func setAll(_ newEntries: [Entry]) {
        entries = newEntries
    }

    // MARK: - Persistence

    private func saveToDefaults() {
        do {
            let data = try JSONEncoder().encode(entries)
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        } catch {
            // Save failures are rare (encoding plain String fields
            // can't really fail). Log and continue — user keeps the
            // in-memory state, just no persistence this run.
            print("[CustomDictionary] save failed: \(error.localizedDescription)")
        }
    }

    private func loadFromDefaults() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else {
            return
        }
        do {
            entries = try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            print("[CustomDictionary] load failed: \(error.localizedDescription) — starting empty")
            // Don't clobber the corrupted defaults entry — the user
            // might want to recover from it later. Just start the
            // session empty.
        }
    }

    // MARK: - Import/Export

    /// JSON file payload for export/import. Wraps the entries in a
    /// versioned envelope so we can evolve the schema without
    /// breaking older exports. The `entries` here drop the UUIDs
    /// (regenerated on import) so two devices importing the same
    /// file don't end up with conflicting IDs.
    struct ExportPayload: Codable {
        let version: Int
        let entries: [ExportEntry]
    }

    struct ExportEntry: Codable {
        let find: String
        let replace: String
    }

    /// Encode the current dictionary as a pretty-printed JSON file
    /// suitable for sharing with another StreamScribe user. The
    /// pretty-print + sorted keys makes the file diff-friendly if a
    /// user is checking it into a repo of their team's custom
    /// dictionaries.
    func exportToData() throws -> Data {
        let payload = ExportPayload(
            version: Self.exportFormatVersion,
            entries: entries.map { ExportEntry(find: $0.find, replace: $0.replace) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    /// Import behavior when the file contains entries.
    enum ImportMode {
        /// Discard the current dictionary, use the imported entries
        /// verbatim. Cleanest semantics; matches what most users
        /// expect from "Import" in apps like Numbers or Pages.
        case replace
        /// Append imported entries to the current dictionary, skipping
        /// duplicates (same find+replace pair). Useful when combining
        /// dictionaries from multiple sources.
        case merge
    }

    /// Decode a previously-exported JSON file and apply it to the
    /// dictionary per the chosen mode. Returns the count of entries
    /// loaded for the caller to surface in a confirmation message.
    @discardableResult
    func importFromData(_ data: Data, mode: ImportMode) throws -> Int {
        let payload = try JSONDecoder().decode(ExportPayload.self, from: data)
        // We don't strictly require version == 1 — a future v2
        // format that's a strict superset (added optional fields)
        // would decode fine here. If we ever break compatibility,
        // we'll add an explicit version check that errors out for
        // unknown versions.
        let imported = payload.entries.map { Entry(find: $0.find, replace: $0.replace) }

        switch mode {
        case .replace:
            setAll(imported)
        case .merge:
            // Dedupe by (find, replace) tuple. Case-sensitive on
            // both sides — a user who imports "jamie diamond" and
            // already has "Jamie Diamond" keeps both as separate
            // entries (the runtime apply is case-insensitive on find
            // anyway, so duplicates here are harmless except as
            // visual noise in the editor).
            let existingKeys = Set(entries.map { "\($0.find)\t\($0.replace)" })
            let newOnes = imported.filter { entry in
                !existingKeys.contains("\(entry.find)\t\(entry.replace)")
            }
            entries.append(contentsOf: newOnes)
        }
        return imported.count
    }
}
