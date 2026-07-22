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
    static let defaultModelRepo = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

    /// Max segments per LLM request. Long monologue groups get
    /// sub-batched so a single request stays well inside the model's
    /// comfortable context.
    private static let maxSegmentsPerBatch = 25

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
        progress: @escaping (Int, Int) -> Void
    ) async throws -> [UUID: String] {
        // Batches: consecutive same-speaker runs, capped in size.
        var batches: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var currentSpeaker: String? = nil
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if seg.speaker == currentSpeaker && current.count < Self.maxSegmentsPerBatch {
                current.append(seg)
            } else {
                if !current.isEmpty { batches.append(current) }
                current = [seg]
                currentSpeaker = seg.speaker
            }
        }
        if !current.isEmpty { batches.append(current) }
        guard !batches.isEmpty else { return [:] }

        let model = try await loadModelIfNeeded()
        var cleaned: [UUID: String] = [:]

        for (i, batch) in batches.enumerated() {
            do {
                let result = try await cleanBatch(batch, model: model)
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
        print("[Cleanup] Loading model: \(modelRepo) (first run downloads from Hugging Face)…")
        let loaded = try await LLMModelFactory.shared.loadContainer(
            configuration: ModelConfiguration(id: modelRepo)
        )
        container = loaded
        print("[Cleanup] Model loaded.")
        return loaded
    }

    private func cleanBatch(
        _ batch: [TranscriptSegment],
        model: ModelContainer
    ) async throws -> [UUID: String] {
        let numberedInput = batch.enumerated().map { i, seg in
            "[\(i + 1)] \(seg.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: "\n")

        let userPrompt = "Clean up these transcript lines:\n\n\(numberedInput)"
        let system = Self.systemPrompt()

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

    /// Parse "[N] text" lines and validate the contract. Any
    /// violation throws — the caller keeps the whole batch verbatim.
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

        guard byIndex.count == batch.count else {
            throw CleanupError.contractViolation("expected \(batch.count) lines, parsed \(byIndex.count)")
        }

        var result: [UUID: String] = [:]
        for (i, seg) in batch.enumerated() {
            guard let cleaned = byIndex[i + 1], !cleaned.isEmpty else {
                throw CleanupError.contractViolation("line \(i + 1) missing or empty")
            }
            let original = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let ratio = Double(cleaned.count) / Double(max(original.count, 1))
            guard ratio >= 0.5 && ratio <= 1.35 else {
                throw CleanupError.contractViolation(
                    "line \(i + 1) length ratio \(String(format: "%.2f", ratio)) outside [0.5, 1.35]"
                )
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

    /// Copy editor, not writer. The dictionary's canonical spellings
    /// attack the proper-noun problem from a second angle — the model
    /// is TOLD the right names rather than guessing.
    private static func systemPrompt() -> String {
        var prompt = """
        You are a meticulous copy editor for verbatim transcripts of government hearings and news broadcasts.

        For each numbered input line, output the same numbered line with ONLY these corrections:
        - Fix punctuation and capitalization.
        - Remove filler words (um, uh, you know, I mean) and false starts / stutters.
        - Fix obvious transcription errors, including misspelled names and homophones.

        STRICT RULES:
        - NEVER paraphrase, reword, summarize, or "improve" phrasing. The speaker's exact words must survive.
        - Never merge, split, reorder, or renumber lines. Output exactly one line per input line, same [N] markers.
        - If a line needs no changes, output it unchanged.
        - Output ONLY the numbered lines. No commentary.
        """
        let terms = CustomDictionary.shared.entries.map(\.replace)
            .filter { !$0.isEmpty }
            .prefix(40)
        if !terms.isEmpty {
            prompt += "\n\nKnown correct spellings for names/terms in this material: "
                + terms.joined(separator: ", ")
        }
        return prompt
    }
}
