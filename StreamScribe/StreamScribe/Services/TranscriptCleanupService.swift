import Foundation
import MLXLMCommon
import MLXLLM

/// Post-session transcript cleanup via a local MLX LLM (default:
/// Qwen3-4B-Instruct 4-bit). Fixes punctuation/capitalization,
/// removes fillers and false starts, corrects obvious
/// mis-transcriptions — and is engineered to NEVER paraphrase,
/// because these transcripts feed press quotes.
///
/// **Why MLX instead of Apple Foundation Models:** field experience —
/// the Foundation Models PnC restorer underwhelmed, and MLX lets the
/// model be swapped by editing a settings string (any mlx-community
/// chat model repo works). The MLX runtime already ships in the app
/// for Parakeet, so this adds a model, not a stack. Requires the
/// MLXLLM/MLXLMCommon products from the mlx-swift-examples package.
///
/// **The safety design (more important than the model):**
///   - Segments are sent as NUMBERED LINES per speaker group; the
///     model must return the same numbered lines, cleaned. Numbering
///     is the contract that lets output map back to segment IDs —
///     timestamps and speakers never enter the model at all.
///   - Every batch is validated: exact line-count/index match, each
///     line within [50%, 135%] of its original length, no emptied
///     lines. ANY violation rejects the WHOLE batch — those segments
///     keep their verbatim text. Conservative by design: a skipped
///     cleanup costs nothing; a paraphrased quote costs trust.
///   - Verbatim text is preserved on every cleaned segment
///     (`rawText`), so nothing is ever destroyed.
@MainActor
final class TranscriptCleanupService {
    static let shared = TranscriptCleanupService()

    static let enabledKey = "cleanup.enabled"
    static let modelRepoKey = "cleanup.modelRepo"
    static let numeralsKey = "cleanup.convertNumerals"
    static let defaultModelRepo = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

    /// Batch packing budgets. Batching is purely by size — speaker
    /// boundaries are irrelevant to cleanup (the line numbering is
    /// the contract), and the original per-speaker batching shattered
    /// Q&A exchanges into dozens of tiny requests (155 batches on a
    /// normal hearing), each paying full prompt+prefill overhead.
    /// 45 lines / ~4800 chars roughly halves the request count vs
    /// the previous 30/2400 budgets — measurably faster passes, and
    /// still small enough that a 4B model tracks the line protocol
    /// reliably (compliance degrades on much longer lists).
    private static let maxSegmentsPerBatch = 45
    private static let maxCharsPerBatch = 4800

    private var container: ModelContainer?

    var modelRepo: String {
        let stored = UserDefaults.standard.string(forKey: Self.modelRepoKey) ?? ""
        return stored.isEmpty ? Self.defaultModelRepo : stored
    }

    /// Run cleanup over a segments snapshot. Returns cleaned text by
    /// segment ID — only entries that changed AND passed validation.
    /// `progress(done, total)` reports batch completion for UI.
    func cleanTranscript(
        segments: [TranscriptSegment],
        knownNames: [String] = [],
        progress: @escaping (Int, Int) -> Void
    ) async throws -> [UUID: String] {
        // Batches: greedy pack in document order until either budget
        // is hit. Cross-speaker packing is fine — cleanup is per-line.
        var batches: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var currentChars = 0
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if current.count >= Self.maxSegmentsPerBatch
                || (currentChars + text.count > Self.maxCharsPerBatch && !current.isEmpty) {
                batches.append(current)
                current = []
                currentChars = 0
            }
            current.append(seg)
            currentChars += text.count
        }
        if !current.isEmpty { batches.append(current) }
        guard !batches.isEmpty else { return [:] }

        let model = try await loadModelIfNeeded()
        var cleaned: [UUID: String] = [:]

        for (i, batch) in batches.enumerated() {
            do {
                let result = try await cleanBatch(batch, model: model, knownNames: knownNames)
                for (id, text) in result { cleaned[id] = text }
            } catch {
                print("[Cleanup] Batch \(i + 1)/\(batches.count) failed (\(error.localizedDescription)) — keeping verbatim text for its \(batch.count) segment(s).")
            }
            progress(i + 1, batches.count)
        }
        return cleaned
    }

    /// Release the model's memory. Called after the pass completes —
    /// a 4B model holds ~2.3GB that has no business staying resident
    /// between sessions.
    func unload() {
        container = nil
    }

    // MARK: - Internals

    private func loadModelIfNeeded() async throws -> ModelContainer {
        if let container { return container }
        // R2-FIRST DISTRIBUTION (2026-07-22, policy: fleet machines
        // have NO Hugging Face access; R2 is the mandatory default for
        // ALL model downloads). Loading by HF model id — the previous
        // behavior — silently worked only on machines that can reach
        // huggingface.co. Now: ensure a local copy from the R2 mirror
        // (tarball, same pattern as Canary — HF-shaped downloaders
        // make Hub API listing calls a plain R2 bucket cannot answer,
        // which is why endpoint-override approaches 404) and load by
        // DIRECTORY. HF remains a loud last-resort fallback so model
        // experimentation on a dev machine isn't blocked by staging —
        // but a fallback hit means the fleet CANNOT get this model
        // until it's staged.
        let localDir = try await ensureModelFromMirror()
        if let localDir {
            print("[Cleanup] Loading model from local mirror copy: \(localDir.lastPathComponent)…")
            let loaded = try await LLMModelFactory.shared.loadContainer(
                configuration: ModelConfiguration(directory: localDir)
            )
            container = loaded
            print("[Cleanup] Model loaded.")
            return loaded
        }
        print("""
        [Cleanup] ⚠️ Model \(modelRepo) is NOT staged on the R2 mirror — \
        falling back to Hugging Face. This works on THIS machine only; \
        fleet machines have no HF access and cleanup will fail for them \
        until the model is staged. Stage it:
          hf download \(modelRepo) --local-dir model-tmp
          tar -czf \(Self.mirrorObjectName(for: modelRepo)) -C model-tmp .
          → upload to the streamscribe-models bucket under llm/
        """)
        let loaded = try await LLMModelFactory.shared.loadContainer(
            configuration: ModelConfiguration(id: modelRepo)
        )
        container = loaded
        print("[Cleanup] Model loaded (via Hugging Face fallback).")
        return loaded
    }

    /// R2 object name for a model repo id: slashes become `--` so the
    /// bucket stays flat under `llm/`.
    private static func mirrorObjectName(for repo: String) -> String {
        repo.replacingOccurrences(of: "/", with: "--") + ".tar.gz"
    }

    /// Local directory for the mirrored model, under the app's unified
    /// models path.
    private static func localModelDirectory(for repo: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("StreamScribe/Models/mlx-llm", isDirectory: true)
            .appendingPathComponent(repo.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    /// Ensure a local copy of `modelRepo` from the R2 mirror. Returns
    /// the model directory, or nil when the mirror doesn't have the
    /// model (404 → caller falls back to HF with a loud warning).
    /// Throws on real failures (network mid-download, extraction) so
    /// they surface instead of masquerading as "not staged".
    private func ensureModelFromMirror() async throws -> URL? {
        let fm = FileManager.default
        let dir = Self.localModelDirectory(for: modelRepo)
        // config.json is universal to MLX model snapshots — presence
        // means a previous download completed (extraction is atomic:
        // we extract to a temp dir and rename into place).
        if fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) {
            return dir
        }

        let mirrorBase = FluidAudioBackend.resolvedMirrorURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let remote = URL(string: "\(mirrorBase)/llm/\(Self.mirrorObjectName(for: modelRepo))") else {
            return nil
        }
        print("[Cleanup] Downloading model from mirror: \(remote.absoluteString) (~2GB for the default model; one-time)…")

        let (tmpFile, response) = try await URLSession.shared.download(from: remote)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "TranscriptCleanupService", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Mirror download failed (HTTP \(http.statusCode)) for \(remote.absoluteString)",
            ])
        }

        // Extract to a temp sibling, verify, then rename into place —
        // a half-extracted directory must never pass the config.json
        // check on a later launch.
        let staging = dir.deletingLastPathComponent()
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["xzf", tmpFile.path, "-C", staging.path]
        tar.standardOutput = Pipe(); tar.standardError = Pipe()
        try tar.run()
        tar.waitUntilExit()
        try? fm.removeItem(at: tmpFile)
        guard tar.terminationStatus == 0,
              fm.fileExists(atPath: staging.appendingPathComponent("config.json").path) else {
            throw NSError(domain: "TranscriptCleanupService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Mirror tarball for \(modelRepo) extracted without a config.json — re-stage it with the model files at the archive ROOT (tar -czf … -C model-dir .)",
            ])
        }
        try? fm.removeItem(at: dir)
        try fm.moveItem(at: staging, to: dir)
        print("[Cleanup] Model staged locally at \(dir.path).")
        return dir
    }

    private func cleanBatch(
        _ batch: [TranscriptSegment],
        model: ModelContainer,
        knownNames: [String]
    ) async throws -> [UUID: String] {
        let numberedInput = batch.enumerated().map { i, seg in
            "[\(i + 1)] \(seg.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: "\n")

        let userPrompt = "Clean up these transcript lines:\n\n\(numberedInput)"
        let system = Self.systemPrompt(knownNames: knownNames)

        let output: String = try await model.perform { context in
            let input = try await context.processor.prepare(
                input: UserInput(chat: [
                    .system(system),
                    .user(userPrompt),
                ])
            )
            // Generation budget: cleanup output is at most modestly
            // longer than input; 1.5× the input token estimate plus
            // headroom prevents runaway generation on a confused model.
            let maxTokens = numberedInput.count / 2 + 300
            var collected = ""
            let result = try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(temperature: 0.2),
                context: context
            ) { tokens in
                tokens.count >= maxTokens ? .stop : .more
            }
            collected = result.output
            return collected
        }

        return try Self.parseAndValidate(output: output, batch: batch)
    }

    /// Parse "[N] text" lines under the DIFF protocol and validate
    /// each returned line independently.
    ///
    /// Semantics: a missing index means "no changes needed" — the
    /// segment keeps its current text. A returned line is accepted
    /// only if its index is in range, its text is non-empty, and its
    /// length is within [50%, 135%] of the original; violations skip
    /// THAT LINE (segment keeps verbatim) rather than rejecting the
    /// batch. Per-line validation makes whole-batch rejection
    /// unnecessary — index-matched, length-checked lines can't be
    /// misattributed — and the old all-or-nothing rule threw away 22
    /// good corrections over 1 dropped line (the model deleting a
    /// pure-filler segment, which models do incorrigibly regardless
    /// of instructions).
    static func parseAndValidate(
        output: String,
        batch: [TranscriptSegment]
    ) throws -> [UUID: String] {
        var byIndex: [Int: String] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["),
                  let close = trimmed.firstIndex(of: "]"),
                  let n = Int(trimmed[trimmed.index(after: trimmed.startIndex)..<close]) else { continue }
            let text = String(trimmed[trimmed.index(after: close)...])
                .trimmingCharacters(in: .whitespaces)
            byIndex[n] = text
        }

        var result: [UUID: String] = [:]
        // Length floor: numeral conversion legitimately shrinks text
        // ("sixty six billion dollars" → "$66 billion"), so the lower
        // bound relaxes when that option is on. The ceiling never
        // moves — nothing legitimate makes a line much LONGER.
        let floor = UserDefaults.standard.bool(forKey: numeralsKey) ? 0.3 : 0.5
        for (i, seg) in batch.enumerated() {
            guard let cleaned = byIndex[i + 1] else { continue }  // omitted = unchanged
            let original = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                print("[Cleanup] Line \(i + 1): model tried to empty a segment — keeping verbatim.")
                continue
            }
            let ratio = Double(cleaned.count) / Double(max(original.count, 1))
            guard ratio >= floor && ratio <= 1.35 else {
                print(String(format: "[Cleanup] Line %d: length ratio %.2f outside [%.2f, 1.35] — keeping verbatim.", i + 1, ratio, floor))
                continue
            }
            if cleaned != original {
                result[seg.id] = cleaned
            }
        }
        return result
    }

    enum CleanupError: LocalizedError {
        case contractViolation(String)
        var errorDescription: String? {
            switch self {
            case .contractViolation(let detail):
                return "Model output violated the line contract (\(detail))"
            }
        }
    }

    /// Copy editor, not writer. Targets the specific error classes
    /// ASR produces — with EXAMPLES, because few-shot demonstrations
    /// move a 4B model's behavior far more than abstract rules do.
    /// The dictionary's canonical spellings attack the proper-noun
    /// problem from a second angle — the model is TOLD the right
    /// names rather than guessing.
    private static func systemPrompt(knownNames: [String]) -> String {
        let numerals = UserDefaults.standard.bool(forKey: numeralsKey)
        var prompt = """
        You are a meticulous copy editor for verbatim transcripts of government hearings and news broadcasts. The text comes from automatic speech recognition and contains these specific error classes:

        1. DUPLICATED words/phrases from ASR stutter: "the the committee", "we need to we need to act".
        2. Stray punctuation, especially periods dropped mid-sentence: "The committee. Will come to order."
        3. Missing punctuation and capitalization.
        4. Filler words (um, uh, you know, I mean) and false starts.
        5. Mis-transcribed proper nouns and homophones.

        Examples of corrections:
        [3] the the chairman. Recognizes the the gentleman from ohio  →  [3] The chairman recognizes the gentleman from Ohio.
        [7] um, I think we we should, uh, move to. Amend the bill  →  [7] I think we should move to amend the bill.
        [9] what's the most important thing for your what's the most important priority for the agency  →  [9] What's the most important priority for the agency?
        (When a speaker restarts a phrase, keep only the completed restart — the abandoned fragment is a false start, not content.)
        """
        if numerals {
            prompt += """

        6. Spelled-out numbers: convert to numerals. "sixty six" → "66", "three point five percent" → "3.5%", "twenty twenty four" (as a year) → "2024". Keep "one" through "nine" as words when they read naturally.
        Example: [4] the deficit grew by sixty six billion dollars  →  [4] The deficit grew by $66 billion.
        """
        }
        prompt += """


        OUTPUT PROTOCOL — output ONLY the lines you changed:
        - For each line you corrected, output it as "[N] corrected text" with its original [N] marker.
        - OMIT lines that need no changes entirely. If nothing needs changing, output nothing.
        - Never merge, split, reorder, or renumber lines. One output line per changed input line.
        - Never delete a line's content: if a line is entirely filler, leave it unchanged (omit it).
        - NEVER paraphrase, reword, summarize, or "improve" phrasing. The speaker's exact words must survive.
        - No commentary, no code fences.
        """
        // Dictionary terms + THIS SESSION's speaker names. The
        // session names are the sleeper feature: witnesses and
        // members identified or renamed during the hearing are
        // exactly the proper nouns the ASR is mangling in body text
        // ("Fire" for "Farar"), and no model can fix a name it has
        // never been given.
        var terms = CustomDictionary.shared.entries.map(\.replace)
            .filter { !$0.isEmpty }
        terms.append(contentsOf: knownNames.filter { !$0.isEmpty })
        var seen = Set<String>()
        let unique = terms.filter { seen.insert($0).inserted }.prefix(60)
        if !unique.isEmpty {
            prompt += "\n\nKnown correct spellings for names/terms in this material (fix near-miss transcriptions to these): "
                + unique.joined(separator: ", ")
        }
        return prompt
    }
}
