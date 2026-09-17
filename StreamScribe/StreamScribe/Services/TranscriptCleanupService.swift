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

    /// Selects the cleanup engine (2026-09-15).
    ///
    /// `.thorough` is the original batched Qwen path: numbered lines, DIFF
    /// output, glossary injection, and the `!REVIEW` decline. `.fast` runs
    /// a small dedicated cleanup model (S1-mini class, a fine-tuned
    /// Qwen3-0.6B) ONE SEGMENT AT A TIME, because such models are trained
    /// to take a transcript and return cleaned text — they do not follow a
    /// line-numbered protocol and are not instruction-following, so the
    /// glossary and the decline marker have nowhere to live in that mode.
    ///
    /// The speed case: generation dominates cleanup, and `.fast` pairs a
    /// ~6x cheaper per-token model with the candidate pre-filter. The cost
    /// is the glossary and the decline — accepted deliberately, to be
    /// revisited if accuracy suffers.
    static let fastModeKey = "cleanup.fastMode"

    static var isFastMode: Bool {
        UserDefaults.standard.bool(forKey: fastModeKey)
    }

    /// Model repo used when `.fast` is selected. Separate from
    /// `modelRepoKey` so switching modes doesn't require retyping either.
    static let fastModelRepoKey = "cleanup.fastModelRepo"
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

    /// Repo for the CURRENTLY SELECTED mode. Fast mode has its own key so
    /// switching modes never requires retyping either repo — and, more
    /// importantly, so fast mode cannot silently load the 4B thorough
    /// model, which would make it slower than the path it replaces.
    var modelRepo: String {
        if Self.isFastMode {
            let fast = UserDefaults.standard.string(forKey: Self.fastModelRepoKey) ?? ""
            return fast.isEmpty ? Self.defaultFastModelRepo : fast
        }
        let stored = UserDefaults.standard.string(forKey: Self.modelRepoKey) ?? ""
        return stored.isEmpty ? Self.defaultModelRepo : stored
    }

    /// The fast cleanup model as STAGED IN OUR OWN R2 BUCKET, so a fresh
    /// install works with no configuration (2026-09-15).
    ///
    /// `ensureModelFromMirror` derives the object name by replacing "/"
    /// with "--", so this value must correspond exactly to the uploaded
    /// tarball:
    ///
    ///     superwhisper/s1-mini-4bit  ->  llm/superwhisper--s1-mini-4bit.tar.gz
    ///
    /// Change one without the other and fast mode 404s on the mirror,
    /// falls back to Hugging Face, and finally reports a missing
    /// `config.json` — three errors, none of which names the real
    /// problem. An earlier PLACEHOLDER default caused exactly that.
    /// Anyone re-staging under a different name must update this line.
    static let defaultFastModelRepo = "superwhisper/s1-mini-4bit"

    /// What a cleanup run produced: text corrections, plus the
    /// segments the model explicitly DECLINED to repair.
    struct CleanupResult {
        var corrections: [UUID: String] = [:]
        var needsReview: Set<UUID> = []
    }

    /// Run cleanup over a segments snapshot. Returns cleaned text by
    /// segment ID — only entries that changed AND passed validation —
    /// plus the IDs the model flagged as too disfluent to repair.
    /// `progress(done, total)` reports batch completion for UI.
    func cleanTranscript(
        segments: [TranscriptSegment],
        knownNames: [String] = [],
        progress: @escaping (Int, Int) -> Void
    ) async throws -> CleanupResult {
        // Batches: greedy pack in document order until either budget
        // is hit. Cross-speaker packing is fine — cleanup is per-line.
        var batches: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var currentChars = 0
        var skipped = 0
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // CANDIDATE PRE-FILTER (2026-09-15). Most lines in a hearing
            // need no repair at all, and sending them costs the same as
            // sending a broken one. Skipping them is safe under the DIFF
            // protocol: an absent line already means "unchanged", so a
            // skipped segment travels the exact path an unmodified one
            // would. Generation dominates cleanup time, so this cuts the
            // bill roughly in proportion to how clean the transcript is.
            guard Self.mayNeedCleanup(text) else {
                skipped += 1
                continue
            }
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
        if skipped > 0 {
            print("[Cleanup] Pre-filter: \(skipped) segment(s) already clean, skipped; \(batches.reduce(0) { $0 + $1.count }) sent to the model.")
        }
        guard !batches.isEmpty else { return CleanupResult() }

        let model = try await loadModelIfNeeded()
        var cleaned = CleanupResult()

        let fast = Self.isFastMode
        if fast, self.modelRepo.isEmpty {
            throw NSError(domain: "TranscriptCleanupService", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "Fast cleanup mode is on but no fast model is configured. "
                    + "Set Settings → Transcript Cleanup → \"Fast cleanup model\" to the "
                    + "repo name you staged, e.g. superwhisper/s1-mini-4bit. StreamScribe "
                    + "derives the R2 object from it by replacing \"/\" with \"--\", so that "
                    + "example looks for llm/superwhisper--s1-mini-4bit.tar.gz",
            ])
        }
        if fast {
            print("[Cleanup] Fast mode: per-segment cleanup with \(self.modelRepo). Glossary and !REVIEW are unavailable in this mode.")
        }

        for (i, batch) in batches.enumerated() {
            do {
                let result = fast
                    ? try await cleanBatchFast(batch, model: model)
                    : try await cleanBatch(batch, model: model, knownNames: knownNames)
                for (id, text) in result.corrections { cleaned.corrections[id] = text }
                cleaned.needsReview.formUnion(result.needsReview)
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
        Self.inlineChatTemplateIfNeeded(in: staging)

        try? fm.removeItem(at: dir)
        try fm.moveItem(at: staging, to: dir)
        print("[Cleanup] Model staged locally at \(dir.path).")
        return dir
    }

    /// Fold a sidecar `chat_template.jinja` into `tokenizer_config.json`.
    ///
    /// Shipping the chat template as its OWN file is a newer Hugging Face
    /// convention. Python's `transformers` reads it, which is why model
    /// cards say the template is picked up with no configuration — but
    /// swift-transformers, underneath MLXLMCommon, looks for a
    /// `chat_template` KEY inside `tokenizer_config.json` and never opens
    /// the sidecar. When the key is absent it falls back to generic
    /// "role: content" text, so the model never sees the prompt format it
    /// was trained on.
    ///
    /// That is not a subtle degradation. On S1-mini it produced reasoning
    /// blocks, stray "user" lines, an "assistant: " prefix on the reply,
    /// and — because a normalizer handed an unrecognized format has no
    /// reason to change anything — a single edit across an entire hearing
    /// (2026-09-16). The template file was present the whole time; nothing
    /// was reading it.
    ///
    /// Done at extract time so it covers any model with this layout, not
    /// just the one that exposed it. Best-effort: a failure here leaves
    /// the model exactly as it was.
    private static func inlineChatTemplateIfNeeded(in directory: URL) {
        let fm = FileManager.default
        let sidecar = directory.appendingPathComponent("chat_template.jinja")
        let configURL = directory.appendingPathComponent("tokenizer_config.json")
        guard fm.fileExists(atPath: sidecar.path), fm.fileExists(atPath: configURL.path) else { return }
        guard let template = try? String(contentsOf: sidecar, encoding: .utf8),
              let data = try? Data(contentsOf: configURL),
              var config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        // An existing key wins — never overwrite a template the converter
        // deliberately embedded.
        guard config["chat_template"] == nil else { return }

        config["chat_template"] = template
        guard let merged = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]),
              (try? merged.write(to: configURL)) != nil else { return }
        print("[Cleanup] Inlined chat_template.jinja into tokenizer_config.json — swift-transformers does not read the sidecar file.")
    }

    private func cleanBatch(
        _ batch: [TranscriptSegment],
        model: ModelContainer,
        knownNames: [String]
    ) async throws -> CleanupResult {
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

    /// Prompt for the small dedicated cleanup model.
    ///
    /// ⚠️ VERIFY AGAINST THE MODEL CARD BEFORE TRUSTING OUTPUT. Models of
    /// this class are NOT instruction-following chat models: they expect
    /// one specific prompt shape, usually a short control line plus the raw
    /// transcript, and they degrade badly (or emit nothing) when given a
    /// conversational system prompt instead. This constant is isolated so
    /// correcting it is a one-line change rather than a code hunt. Two
    /// things to confirm: the exact control-line syntax, and whether the
    /// chat template needs thinking disabled — omitting that flag is a
    /// documented cause of blank output in this family.
    /// EXACT system prompt required by S1-mini. Do not reword it.
    ///
    /// The model card is explicit: the system prompt and the control line
    /// are the input format the model was TRAINED on, and changing the
    /// wording, dropping either, or sending control values outside the
    /// trained sets can make it hallucinate or emit garbled text. It is
    /// not a chat model and will not follow general instructions — our
    /// original hand-written "clean up the transcript…" instruction was
    /// steering nothing, which is why output arrived full of reasoning
    /// blocks and chat-turn fragments (2026-09-16).
    static let fastSystemPrompt = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."

    /// Control line prepended to every transcript, per the documented
    /// format: `[Styling: …] [Structure: …] [Context: …]` then a newline.
    ///
    /// Values chosen for hearing transcripts: `semi-formal` is the card's
    /// recommended default and gives standard written English with
    /// contractions kept; `prose` keeps everything in sentences, since a
    /// model deciding to bullet-point a senator's remarks would be wrong
    /// for a quotable record; `general` avoids the email greeting and
    /// sign-off layout. All three are within the trained value sets.
    static let fastControlLine = "[Styling: semi-formal] [Structure: prose] [Context: general]"

    /// Per-segment cleanup for `.fast` mode.
    ///
    /// No line numbers and no DIFF: the model returns the whole cleaned
    /// line, so EVERY return is a candidate rewrite and validation carries
    /// more weight than in the batched path. It reuses the same guards —
    /// non-empty, and a length ratio inside the accepted band — because a
    /// small model handed one short line is exactly where a runaway
    /// continuation or a dropped clause would otherwise slip through.
    private func cleanBatchFast(
        _ batch: [TranscriptSegment],
        model: ModelContainer
    ) async throws -> CleanupResult {
        var result = CleanupResult()
        for seg in batch {
            if Task.isCancelled { break }
            let original = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !original.isEmpty else { continue }

            let output: String = try await model.perform { context in
                // Control line, newline, then the raw transcript — the exact
                // shape the model was trained on. `/no_think` rides at the
                // end because Qwen3's chat template consumes that token and
                // renders the empty `<think></think>` prefix S1-mini expects;
                // it is the in-prompt equivalent of `enable_thinking=False`,
                // which we cannot pass without chat-template kwargs. It goes
                // HERE rather than in the system prompt because that string
                // must stay verbatim. Without thinking disabled this model
                // typically returns nothing usable at all.
                let userContent = "\(Self.fastControlLine)\n\(original)\n/no_think"
                let input = try await context.processor.prepare(
                    input: UserInput(chat: [
                        .system(Self.fastSystemPrompt),
                        .user(userContent),
                    ])
                )
                // Output length tracks input length; the model card's safe
                // ceiling is 1.3 x input tokens + 32. At roughly 4 chars per
                // token that is chars/3 + 32 — far cheaper than a flat cap,
                // and it still stops a confused model running into invented
                // dialogue.
                let maxTokens = original.count / 3 + 32
                let generated = try MLXLMCommon.generate(
                    input: input,
                    parameters: GenerateParameters(temperature: 0.0),
                    context: context
                ) { tokens in
                    tokens.count >= maxTokens ? .stop : .more
                }
                return generated.output
            }

            // Order matters: both helpers rely on newlines still being
            // present, so the collapse to spaces happens last.
            let cleaned = Self.trimAtTurnBoundary(Self.stripReasoning(output))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            guard !cleaned.isEmpty else { continue }
            let ratio = Double(cleaned.count) / Double(max(original.count, 1))
            guard ratio >= 0.5 && ratio <= 1.35 else {
                print(String(format: "[Cleanup/fast] length ratio %.2f outside [0.50, 1.35] — keeping verbatim.", ratio))
                continue
            }
            if cleaned != original { result.corrections[seg.id] = cleaned }
        }
        return result
    }

    /// Remove a reasoning block from model output.
    ///
    /// Takes whatever follows the LAST `</think>`, because the answer is
    /// what comes after the model stops reasoning. Two failure shapes are
    /// handled deliberately:
    ///
    ///   - An UNCLOSED `<think>` (the model hit the token ceiling
    ///     mid-thought) leaves no answer at all, so this returns empty
    ///     and the caller keeps the segment verbatim. Returning the
    ///     partial monologue would be far worse than changing nothing.
    ///   - Output with no reasoning at all passes through untouched.
    static func stripReasoning(_ output: String) -> String {
        guard output.contains("<think>") || output.contains("</think>") else { return output }
        if let closeRange = output.range(of: "</think>", options: .backwards) {
            return String(output[closeRange.upperBound...])
        }
        // Opened but never closed — there is no answer in here.
        if let openRange = output.range(of: "<think>") {
            return String(output[..<openRange.lowerBound])
        }
        return output
    }

    /// Cut model output at the first CHAT-TURN BOUNDARY.
    ///
    /// A small model that doesn't stop cleanly at end-of-turn simply
    /// keeps going and writes the NEXT turn itself — `<|im_end|>` then
    /// `<|im_start|>user` and a fresh prompt. When the tokenizer strips
    /// those special tokens during decoding, the bare role word survives,
    /// which is how stray "user" lines ended up scattered through an
    /// exported transcript (2026-09-16).
    ///
    /// Two detectors, because the special tokens may or may not survive
    /// decoding: the literal markers, and a role word ALONE on its own
    /// line. The aloneness test is the important guard — "user" is
    /// ordinary English, and "the end user was never consulted" is real
    /// hearing testimony that must pass through untouched.
    static func trimAtTurnBoundary(_ output: String) -> String {
        // Leading role label. When the tokenizer has no chat template,
        // MLXLMCommon falls back to plain "role: content" text, and the
        // model continues that pattern by labelling its own turn — so the
        // reply arrives as "assistant: <text>" (2026-09-16 field report,
        // where the single edit in a whole transcript was this prefix).
        // Stripping it is a repair, not a fix: the real problem is the
        // missing template, and a model that never sees its trained
        // prefix also will not normalize well.
        var output = output
        for role in ["assistant:", "assistant :", "Assistant:"] {
            let leading = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if leading.lowercased().hasPrefix(role.lowercased()) {
                output = String(leading.dropFirst(role.count))
                break
            }
        }

        var cut = output.endIndex

        for marker in ["<|im_end|>", "<|im_start|>", "<|endoftext|>"] {
            if let range = output.range(of: marker), range.lowerBound < cut {
                cut = range.lowerBound
            }
        }

        var lineStart = output.startIndex
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let bare = line.trimmingCharacters(in: .whitespaces).lowercased()
            if ["user", "assistant", "system"].contains(bare) {
                if lineStart < cut { cut = lineStart }
                break
            }
            // +1 for the newline that split() consumed.
            let advance = line.count + 1
            guard let next = output.index(lineStart, offsetBy: advance, limitedBy: output.endIndex) else { break }
            lineStart = next
        }

        return String(output[..<cut])
    }

    /// Cheap text-only test for whether a line shows any evidence of the
    /// error classes the cleanup prompt repairs.
    ///
    /// Deliberately biased toward SENDING: a false positive costs one
    /// line of model time, while a false negative silently leaves a
    /// defect in the transcript. Anything ambiguous goes to the model.
    ///
    /// **Known blind spot:** a misspelled proper noun in an otherwise
    /// tidy sentence carries no textual signal, so it will be skipped.
    /// That class needs acoustic evidence (confidence, N-best) or a
    /// phonetic glossary match, neither of which exists yet — so this
    /// filter trades a little proper-noun recall for a large speed win,
    /// and should be revisited when confidence plumbing lands.
    static func mayNeedCleanup(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }

        // Filler and hedging — the most common repair.
        if s.range(of: #"\b(um+|uh+|er+|ah+|you know|i mean|sort of|kind of|like)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil { return true }
        // Stutter / duplicated word, the false-start signature.
        if s.range(of: #"\b(\w+)\s+\1\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil { return true }
        // Numerals and number words — inverse text normalization.
        if s.range(of: #"\b(\d|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|twenty|thirty|forty|fifty|hundred|thousand|million|billion|percent|dollars?)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil { return true }
        // No terminal punctuation — the chunk-seam artifact.
        if s.range(of: #"[.!?\"')\]]$"#, options: .regularExpression) == nil { return true }
        // Sentence starting lowercase — casing repair.
        if let first = s.first, first.isLowercase { return true }
        // Shouted text — the deshout path's territory.
        if s.count > 12, s == s.uppercased(), s.rangeOfCharacter(from: .letters) != nil { return true }
        return false
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
    ) throws -> CleanupResult {
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

        var result = CleanupResult()
        // Length floor: numeral conversion legitimately shrinks text
        // ("sixty six billion dollars" → "$66 billion"), so the lower
        // bound relaxes when that option is on. The ceiling never
        // moves — nothing legitimate makes a line much LONGER.
        let floor = UserDefaults.standard.bool(forKey: numeralsKey) ? 0.3 : 0.5
        for (i, seg) in batch.enumerated() {
            guard let cleaned = byIndex[i + 1] else { continue }  // omitted = unchanged
            // DECLINE MARKER (2026-08-07): the model may return
            // `!REVIEW` instead of a rewrite when a passage is too
            // disfluent to repair safely. The text stays exactly as the
            // ASR produced it and the segment is flagged for a human.
            // This converts the worst failure mode — confidently
            // rewriting speech nobody can reconstruct — into the most
            // benign one, an untouched verbatim line on a worklist.
            if cleaned.uppercased().hasPrefix("!REVIEW") {
                result.needsReview.insert(seg.id)
                continue
            }
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
                result.corrections[seg.id] = cleaned
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
        - If a passage is so disfluent that you cannot reconstruct what the speaker meant — heavy stumbling, an abandoned thought with no clean restart, a subject change mid-clause — do NOT attempt a repair. Output "[N] !REVIEW" for that line instead. Its text will be kept exactly as spoken and flagged for a human. Prefer this over guessing: a passage nobody can reconstruct is one where a confident rewrite does the most damage.
        - !REVIEW is for UNREPAIRABLE passages only, not for ordinary false starts, filler, or stutter — repair those normally.
        """
        // Dictionary terms + THIS SESSION's speaker names. The
        // session names are the sleeper feature: witnesses and
        // members identified or renamed during the hearing are
        // exactly the proper nouns the ASR is mangling in body text
        // ("Fire" for "Farar"), and no model can fix a name it has
        // never been given.
        // ORDER MATTERS — session names FIRST (2026-08-07). The list is
        // capped at 60 to bound prefill cost, and `prefix` truncates the
        // TAIL, so whatever is appended last is what gets dropped. With
        // dictionary terms first, a user whose dictionary has grown past
        // 60 entries silently lost EVERY session name — the witnesses
        // and members identified during this specific hearing, which the
        // comment above rightly calls the sleeper feature and which are
        // the terms the ASR is most likely to be mangling right now. The
        // static dictionary is the general-purpose fallback and is the
        // correct thing to truncate.
        var terms = knownNames.filter { !$0.isEmpty }
        terms.append(contentsOf: CustomDictionary.shared.entries.map(\.replace)
            .filter { !$0.isEmpty })
        var seen = Set<String>()
        let unique = terms.filter { seen.insert($0).inserted }.prefix(60)
        if !unique.isEmpty {
            prompt += "\n\nKnown correct spellings for names/terms in this material (fix near-miss transcriptions to these): "
                + unique.joined(separator: ", ")
        }
        return prompt
    }
}
