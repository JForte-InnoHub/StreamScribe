import Foundation
import MLX
import MLXAudioSTT

/// Parakeet-backed transcription via mlx-audio-swift.
///
/// Public API consumed (verified against mlx-audio-swift 0.1.2 sources):
///   • `ParakeetModel.fromPretrained(_:cache:)` — declared in `public extension ParakeetModel`,
///     so it's accessible from outside MLXAudioSTT.
///   • `model.generate(audio:generationParameters:)` — declared on protocol `STTGenerationModel`
///     with a public extension overload that supplies default parameters.
///   • Returns `STTOutput` with `text: String`, `language: String?`, and
///     `segments: [[String: Any]]?` where each dict has keys `"text"`, `"start"`, `"end"`
///     (per-sentence timing extracted from Parakeet's alignment output).
actor ParakeetBackend: TranscriptionBackend {

    private var model: ParakeetModel?
    private let modelRepo: String
    private let chunkDuration: TimeInterval

    /// Rolling cache of the last ~80 tokens we emitted, used to catch boundary
    /// duplication where Parakeet re-transcribes the overlap region of consecutive
    /// chunks. The shared engine-level dedup (`trimmedAfterOverlap`) is exact-match
    /// only and slips on Parakeet's fuzzy boundaries — Parakeet hallucinates small
    /// connective tokens at chunk starts ("of America retreats…") and produces minor
    /// word-form variations ("manufacturers" vs "manufacturing"). This per-backend
    /// cache feeds a fuzzy aligner that handles both.
    ///
    /// Cleared in `reset()`; updated after every non-empty `transcribe()` call.
    private var recentTailText: String = ""

    /// Monotonically incrementing call counter, for log readability. Reset in
    /// `reset()` so per-session logs start at #1.
    private var transcribeCallCount: Int = 0

    /// One-shot: only log the detected language the first time we see one. Avoids
    /// spamming the same "language=en" line on every chunk. Reset in `reset()`.
    private var loggedLanguage: Bool = false

    init(modelRepo: String, chunkDuration: TimeInterval) {
        self.modelRepo = modelRepo
        self.chunkDuration = chunkDuration
    }

    func loadingDescription() -> String {
        "Loading Parakeet model \(ParakeetBackend.shortName(modelRepo))…"
    }

    func prepare() async throws {
        if model != nil { return }
        // Apply the user's MLX buffer-cache limit BEFORE loading the model.
        // Without a cap, MLX's intermediate-buffer cache grows without bound
        // across inferences; in session 5 testing this caused a single 5s
        // chunk's inference to take 82s by chunk #176 (16× slower than
        // realtime) as macOS started paging Metal memory. The limit is
        // global, read fresh from UserDefaults each prepare(), so changes
        // to the Settings slider take effect on the next session start
        // without an app restart.
        applyMLXCacheLimit()

        // Check for a sideloaded copy in ~/Documents and migrate it into
        // the library's cache location if needed. Lets users on networks
        // that block Hugging Face receive model files out-of-band and
        // drop them somewhere visible (Documents) rather than the hidden
        // ~/.cache directory. See `migrateSideloadedCacheIfPresent` for
        // the layout requirement and copy semantics.
        Self.migrateSideloadedCacheIfPresent(modelRepo: modelRepo)

        // First-run downloads weights from the mlx-community HF repo into the system Hub cache.
        let modelShort = ParakeetBackend.shortName(modelRepo)
        print("[Parakeet] Loading model \(modelShort) (repo=\(modelRepo))…")
        let loadStart = Date()
        model = try await ParakeetModel.fromPretrained(modelRepo)
        let loadElapsed = Date().timeIntervalSince(loadStart)
        print("[Parakeet] Model \(modelShort) ready in \(String(format: "%.2f", loadElapsed))s. Chunk duration=\(String(format: "%.1f", chunkDuration))s.")

        // Reclaim disk: mlx-audio-swift internally downloads the model
        // twice — once to the standard HF Hub layout at
        // `hub/models--<org>--<name>/`, then again to its own runtime
        // location at `hub/mlx-audio/models--<org>--<name>/`. Only the
        // latter is read at load time. Now that the model is loaded
        // into memory, the former is dead weight.
        Self.cleanupDuplicateHubCopy(modelRepo: modelRepo)
    }

    func transcribe(samples: [Float], chunkStartTime: TimeInterval) async throws -> TranscriptionResult {
        guard let model else {
            print("[Parakeet] transcribe() called before prepare() — returning empty.")
            return TranscriptionResult(segments: [], detectedLanguage: nil)
        }

        transcribeCallCount += 1
        let callNum = transcribeCallCount
        let audioSeconds = Double(samples.count) / 16_000.0
        let chunkEnd = chunkStartTime + audioSeconds
        print(String(format: "[Parakeet] #%d transcribe start: chunk [%.2fs..%.2fs] (%d samples, %.2fs audio)",
                     callNum, chunkStartTime, chunkEnd, samples.count, audioSeconds))

        let inferStart = Date()

        // mlx-audio-swift wants an MLXArray. Build one directly from our Float buffer.
        let audio = MLXArray(samples)

        // STTOutput is the protocol-defined output type. Call uses the convenience overload
        // (defaults from the model). Note: not throwing despite generate() being non-throwing
        // on Parakeet — `try` here would actually be a warning. Don't add it.
        let output = model.generate(audio: audio)

        let inferElapsed = Date().timeIntervalSince(inferStart)
        let rtf = audioSeconds > 0 ? inferElapsed / audioSeconds : 0
        let textLen = output.text.count
        let rawSegCount = output.segments?.count ?? 0
        print(String(format: "[Parakeet] #%d inference complete in %.2fs (RTF=%.2fx, %dx realtime), raw text=%d chars, raw segments=%d",
                     callNum, inferElapsed, rtf, rtf > 0 ? Int((1.0 / rtf).rounded()) : 0, textLen, rawSegCount))

        // Periodic explicit cache clear. The cache-limit cap (set in
        // prepare()) is the first line of defense; this is belt-and-
        // suspenders for long sessions where even bounded growth can
        // fragment Metal memory. 30 chunks ≈ 2.5 minutes of audio at 5s
        // chunks — long enough to avoid clearing useful intermediates
        // every call, short enough that even sessions running for hours
        // get periodic cleanup. Hard-coded rather than user-configurable
        // because it shouldn't need tuning unless something's wrong with
        // the cache-limit ceiling, in which case the user wants the
        // slider, not a second knob.
        if callNum % 30 == 0 {
            MLX.GPU.clearCache()
            print("[Parakeet] Periodic MLX cache clear at chunk #\(callNum).")
        }

        if !loggedLanguage, let lang = output.language, !lang.isEmpty {
            print("[Parakeet] Detected language: \(lang)")
            loggedLanguage = true
        }

        let trimmedFullText = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFullText.isEmpty else {
            print("[Parakeet] #\(callNum) empty output (silence or non-speech).")
            return TranscriptionResult(segments: [], detectedLanguage: output.language)
        }

        // STTOutput.segments is [[String: Any]]? — Parakeet populates it from
        // ParakeetAlignedResult.segments where each dict has keys "text" (String),
        // "start" (Double), "end" (Double). Cast carefully and skip any that don't conform.
        let parsedSegments: [TranscriptSegment]
        if let raw = output.segments, !raw.isEmpty {
            parsedSegments = raw.compactMap { dict in
                guard let text = dict["text"] as? String,
                      let start = ParakeetBackend.toDouble(dict["start"]),
                      let end = ParakeetBackend.toDouble(dict["end"])
                else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return TranscriptSegment(
                    text: trimmed,
                    start: chunkStartTime + start,
                    end: chunkStartTime + end,
                    speaker: nil,
                    isFinalized: true
                )
            }
        } else {
            parsedSegments = []
        }

        // Fallback: if the per-sentence segments were unavailable or unparseable, treat the
        // entire chunk text as one segment spanning the chunk window.
        var finalSegments: [TranscriptSegment]
        if parsedSegments.isEmpty {
            finalSegments = [
                TranscriptSegment(
                    text: trimmedFullText,
                    start: chunkStartTime,
                    end: chunkStartTime + chunkDuration,
                    speaker: nil,
                    isFinalized: true
                )
            ]
        } else {
            finalSegments = parsedSegments
        }

        // Boundary dedup: if we have a tail from the previous chunk, fuzzy-align it
        // against the start of this chunk's first segment and drop the overlapping
        // prefix. Only the first segment is checked — within-chunk segments come
        // from one transcription pass and don't duplicate each other.
        let preDedupCount = finalSegments.count
        var dedupAction = "none"
        if !recentTailText.isEmpty, !finalSegments.isEmpty {
            let head = finalSegments[0]
            if let trimmed = ParakeetBackend.fuzzyTrimmedAfterOverlap(
                prevTail: recentTailText,
                newText: head.text
            ) {
                if trimmed.isEmpty {
                    // Whole first segment was a duplicate of the tail — drop it.
                    finalSegments.removeFirst()
                    dedupAction = "dropped-first-segment"
                } else {
                    finalSegments[0] = TranscriptSegment(
                        id: head.id,
                        text: trimmed,
                        start: head.start,
                        end: head.end,
                        speaker: head.speaker,
                        isFinalized: head.isFinalized
                    )
                    dedupAction = "trimmed-prefix"
                }
            }
        }

        // Update the rolling tail with the joined text we're about to return. We
        // keep only the last ~80 tokens — enough to cover any plausible overlap
        // window (2s overlap × ~3 words/sec × safety margin) without growing
        // unboundedly across long sessions.
        if !finalSegments.isEmpty {
            let joined = finalSegments.map { $0.text }.joined(separator: " ")
            recentTailText = ParakeetBackend.lastNTokens(of: joined, n: 80)
        }

        let outChars = finalSegments.reduce(0) { $0 + $1.text.count }
        print("[Parakeet] #\(callNum) emit: \(finalSegments.count) segment(s), \(outChars) char(s) (pre-dedup=\(preDedupCount), dedup=\(dedupAction))")

        return TranscriptionResult(
            segments: finalSegments,
            detectedLanguage: output.language
        )
    }

    func reset() async {
        recentTailText = ""
        transcribeCallCount = 0
        loggedLanguage = false
        print("[Parakeet] reset.")
    }

    /// Drop the loaded model. Symmetric with `WhisperKitBackend.unload()`.
    /// Parakeet isn't used in the lazy-load refinement path today (it's the
    /// raw transcriber under the canonical split, and raw stays loaded the
    /// whole session) — but implementing this here keeps the protocol clean
    /// and makes a future "lazy-load raw too" change a scheduler-only edit.
    ///
    /// Also clears the per-session log counters and the rolling dedup tail
    /// since those are conceptually tied to a loaded model.
    func unload() async {
        guard model != nil else { return }
        model = nil
        recentTailText = ""
        transcribeCallCount = 0
        loggedLanguage = false
        print("[Parakeet] unloaded model.")
    }

    // MARK: - Helpers

    /// The dict values can be Double, Float, or NSNumber depending on JSON path. Coerce.
    private static func toDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let f = value as? Float { return Double(f) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    /// Token with normalized form + character range in the original string. Allows
    /// us to slice the original back out (preserving casing and punctuation) once we
    /// know how many tokens to drop.
    private struct TokenSpan {
        let normalized: String
        let rangeInOriginal: Range<String.Index>
    }

    /// Word-tokenize a string. Splits on whitespace; each token's normalized form
    /// is lowercased with leading/trailing punctuation stripped. Empty tokens
    /// (pure punctuation) are dropped.
    private static func tokenize(_ s: String) -> [TokenSpan] {
        var tokens: [TokenSpan] = []
        var i = s.startIndex
        while i < s.endIndex {
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
                tokens.append(TokenSpan(
                    normalized: normalized,
                    rangeInOriginal: wordStart..<wordEnd
                ))
            }
        }
        return tokens
    }

    /// Return the last `n` tokens of `s` joined back into a string (with single
    /// spaces). Used to bound the rolling tail so it doesn't grow without bound.
    fileprivate static func lastNTokens(of s: String, n: Int) -> String {
        let tokens = tokenize(s)
        guard tokens.count > n else { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let kept = tokens.suffix(n)
        guard let first = kept.first else { return "" }
        // Slice from the start of the first kept token to end of the last.
        let lastEnd = kept.last!.rangeInOriginal.upperBound
        return String(s[first.rangeInOriginal.lowerBound..<lastEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fuzzy boundary trim: if `newText` begins with content that matches the tail
    /// of `prevTail` — even with small word-form differences or hallucinated
    /// connective words — return `newText` with that overlapping prefix removed.
    /// Returns `nil` when no acceptable alignment is found, leaving the segment
    /// untouched.
    ///
    /// Algorithm: try every alignment window in newText's first ~80 tokens,
    /// scoring each by a token-level edit distance against the suffix of prevTail.
    /// Accept the lowest-cost alignment that meets quality bars:
    ///   • match length ≥ 3 tokens
    ///   • the first OR last 2 tokens of the matched span must match exactly
    ///     (anchor bigram). This prevents drift on common 3-word phrases like
    ///     "in the world" or "all of the" recurring legitimately, while still
    ///     allowing one substitution somewhere in the middle/end of the span.
    ///   • edit cost budget: 1 edit per 3 tokens (so length 3: 1; length 6: 2; etc.)
    ///   • allows skipping up to 2 tokens at the start of newText (catches
    ///     hallucinated leading connectives like "of", "and", "the")
    ///
    /// Designed to be conservative — false negatives (missed dups) are recoverable
    /// by visual review; false positives delete real content silently. Quality
    /// bars chosen with that asymmetry in mind.
    ///
    /// Known limitation: if a speaker legitimately repeats a phrase across the
    /// chunk boundary (e.g. "I said no. I said no, never."), this will trim the
    /// repetition since it's indistinguishable from an ASR-induced duplicate. We
    /// accept this trade-off because legitimate cross-chunk repetition is rare
    /// while ASR-induced dups are not.
    fileprivate static func fuzzyTrimmedAfterOverlap(prevTail: String, newText: String) -> String? {
        let prevTokens = tokenize(prevTail)
        let newTokens = tokenize(newText)
        guard !prevTokens.isEmpty, !newTokens.isEmpty else { return nil }

        // Cap the search window. Anything beyond ~80 tokens (~25-30s of speech) is
        // not an overlap dup — it's continuation we should keep.
        let searchWindowMax = min(80, newTokens.count)
        // Length range to consider: 3 tokens (minimum-length match) up to the
        // shorter of prevTail length or the search window.
        let maxMatchLen = min(prevTokens.count, searchWindowMax)
        guard maxMatchLen >= 3 else { return nil }

        // Allow the matched span in newText to start a few tokens in, to absorb
        // hallucinated leading words. Don't allow more than 2 — bigger gaps usually
        // mean it's not actually the same content.
        let maxStartOffset = min(2, searchWindowMax - 3)

        // Best alignment so far: lowest cost, breaking ties by longer match length.
        struct Candidate {
            let startOffset: Int    // tokens in newText to skip before the match begins
            let length: Int          // length of the matched span in tokens
            let cost: Int            // edit distance against prevTail's suffix
        }
        var best: Candidate?

        for startOffset in 0...maxStartOffset {
            // Don't try lengths that would extend past the search window.
            let maxLenAtThisOffset = min(maxMatchLen, searchWindowMax - startOffset)
            guard maxLenAtThisOffset >= 3 else { continue }

            for length in stride(from: maxLenAtThisOffset, through: 3, by: -1) {
                let prevSuffix = Array(prevTokens.suffix(length).map { $0.normalized })
                let newSpan = Array(newTokens[startOffset..<(startOffset + length)].map { $0.normalized })

                // Anchor bigram check: at least one end of the matched span must
                // align exactly. This is what keeps short fuzzy matches safe — a
                // single drifting word is fine, but 3 random matching words in a
                // shuffled order should NOT trigger a trim.
                let prefixAnchored = prevSuffix[0] == newSpan[0]
                    && prevSuffix[1] == newSpan[1]
                let suffixAnchored = prevSuffix[length - 1] == newSpan[length - 1]
                    && prevSuffix[length - 2] == newSpan[length - 2]
                guard prefixAnchored || suffixAnchored else { continue }

                let cost = editDistance(prevSuffix, newSpan)
                // 1 edit per 3 tokens. Length 3: 1 edit. Length 6: 2. Length 12: 4.
                let budget = max(1, length / 3)
                guard cost <= budget else { continue }

                // Prefer longer matches when cost ratio is comparable. Equivalent to
                // sorting by (cost ASC, length DESC).
                if best == nil
                    || cost < best!.cost
                    || (cost == best!.cost && length > best!.length)
                {
                    best = Candidate(startOffset: startOffset, length: length, cost: cost)
                }
            }
        }

        guard let chosen = best else { return nil }

        // Drop everything in newText through the end of the matched span.
        let lastMatchedTokenIdx = chosen.startOffset + chosen.length - 1
        let dropToCharIndex = newTokens[lastMatchedTokenIdx].rangeInOriginal.upperBound
        var remainder = String(newText[dropToCharIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // If the remainder starts with orphaned punctuation, strip it.
        while let first = remainder.first, ".,;:!?".contains(first) {
            remainder.removeFirst()
            remainder = remainder.trimmingCharacters(in: .whitespaces)
        }
        return remainder
    }

    /// Standard token-level Levenshtein distance. Each insertion, deletion, and
    /// substitution costs 1. Operates on already-normalized token arrays.
    private static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        // Two-row DP — we only need the previous row.
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,        // deletion
                    curr[j - 1] + 1,    // insertion
                    prev[j - 1] + cost  // substitution / match
                )
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }

    static func shortName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "mlx-community/", with: "")
    }

    /// Whether the weights for `modelRepo` are already on disk in any of the
    /// known mlx-audio-swift / Hugging Face Hub cache locations. Used by
    /// `ModelDownloadManager` to drive the sidebar's "Downloaded" indicator
    /// without instantiating a backend just to find out.
    ///
    /// mlx-audio-swift's `ParakeetModel.fromPretrained` ultimately delegates
    /// to the swift-transformers Hub library, which stores snapshots under
    /// `~/Documents/huggingface/models/<org>/<repo>` (the same root that
    /// WhisperKit uses, observed empirically in session 4 testing on macOS).
    /// We also probe `~/.cache/huggingface/hub/...` as a fallback for
    /// configurations where the Hub library was pointed at the XDG cache
    /// instead. Conservative when the cache layout differs: returns false,
    /// which makes `isCached` show "Not downloaded" and the user can click
    /// Download — `prepare()` is idempotent and fast in the cache-hit case
    /// (the Hub library checks ETag and short-circuits if local files match),
    /// so a false negative just costs a few seconds.
    static func isModelCached(modelRepo: String) -> Bool {
        let fm = FileManager.default
        for path in cacheCandidatePaths(modelRepo: modelRepo) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let contents = try? fm.contentsOfDirectory(atPath: path), !contents.isEmpty else {
                continue
            }
            // Verify the directory actually contains a usable model, not
            // just leftover scaffolding from an interrupted download. A
            // complete mlx-audio Parakeet / Sortformer checkout always
            // contains a `config.json` plus at least one weight file
            // (`.safetensors` for both, sometimes `model.npz` for
            // older snapshots). Without this guard, a partial download
            // where the config.json arrived but the weights didn't
            // would be flagged "cached" → status sidebar shows
            // "Downloaded" → user clicks Start → mlx-audio-swift's
            // fromPretrained detects the missing weights and silently
            // re-downloads the entire 2.5 GB (taking ~3 minutes with
            // no UI feedback that anything is happening, since the
            // download bar only animates during `.downloading` state
            // and we already transitioned to `.loading`). Strict
            // probe catches this and keeps the sidebar honest.
            //
            // Defensive sizes — these floors are well below any
            // real weight file size but well above any
            // metadata-only artifact that might exist after a
            // half-complete download. If the weights are partially
            // written but smaller than the floor, treat as not-cached
            // and force a clean re-download.
            let hasConfig = contents.contains("config.json")
            let weightFiles = contents.filter { name in
                name.hasSuffix(".safetensors") || name.hasSuffix(".npz")
            }
            let hasWeightFile = weightFiles.contains { name in
                let weightPath = (path as NSString).appendingPathComponent(name)
                if let attrs = try? fm.attributesOfItem(atPath: weightPath),
                   let size = attrs[.size] as? NSNumber {
                    // 1 MB floor — even the tiniest valid weight file
                    // for these models is in the hundreds of MB. 1 MB
                    // weeds out empty-shell files that the HF library
                    // sometimes leaves when a download is interrupted
                    // mid-transfer.
                    return size.int64Value > 1_000_000
                }
                return false
            }
            if hasConfig && hasWeightFile {
                return true
            }
        }
        return false
    }

    /// Possible disk locations where mlx-audio-swift might have placed a
    /// downloaded model. Mirrors `WhisperKitBackend.cacheCandidatePaths`
    /// shape so the `ModelDownloadManager` can use a uniform polling loop
    /// across all four backends.
    ///
    /// **Actual write path.** Empirically (confirmed by a runtime log
    /// line emitted by the library: "Model downloaded to: <path>"),
    /// mlx-audio-swift 0.1.2 writes models to a CUSTOM subdirectory
    /// `<HF_HOME>/hub/mlx-audio/<org>_<name>/` — note the underscore
    /// between org and name, not the standard HF Hub `--` separator.
    /// With `HF_HOME=~/Documents/huggingface` (set in
    /// `StreamScribeApp.init`) this becomes
    /// `~/Documents/huggingface/hub/mlx-audio/mlx-community_<name>/`.
    /// That's what the primary candidate probes.
    ///
    /// We also keep two legacy fallbacks for users who had downloaded
    /// models on previous app builds before the path discovery /
    /// `HF_HOME` redirect:
    ///   - `~/.cache/huggingface/hub/mlx-audio/<org>_<name>` — same
    ///     mlx-audio subdir under the OS-default HF cache root.
    ///   - `~/.cache/huggingface/hub/models--<org>--<name>` — standard
    ///     HF Hub layout, in case a future mlx-audio-swift version
    ///     switches to it (or a manual sideload places files here).
    static func cacheCandidatePaths(modelRepo: String) -> [String] {
        let fm = FileManager.default
        var candidates: [String] = []

        let parts = modelRepo.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return candidates }
        let org = String(parts[0])
        let name = String(parts[1])
        let mlxAudioDirName = "\(org)_\(name)"
        let hubLayoutDirName = "models--\(org)--\(name)"

        // Primary: HF_HOME-redirected Documents location, mlx-audio's
        // own subdir layout.
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(docs
                .appendingPathComponent("huggingface")
                .appendingPathComponent("hub")
                .appendingPathComponent("mlx-audio")
                .appendingPathComponent(mlxAudioDirName)
                .path)
            // Also probe the standard HF Hub layout under Documents in
            // case future library versions switch to it, OR a sideloaded
            // model uses the canonical layout.
            candidates.append(docs
                .appendingPathComponent("huggingface")
                .appendingPathComponent("hub")
                .appendingPathComponent(hubLayoutDirName)
                .path)
        }
        // Legacy: pre-HF_HOME default cache root.
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            candidates.append("\(home)/.cache/huggingface/hub/mlx-audio/\(mlxAudioDirName)")
            candidates.append("\(home)/.cache/huggingface/hub/\(hubLayoutDirName)")
        }
        return candidates
    }

    /// Migrate a previously-downloaded model from the legacy
    /// `~/.cache/huggingface/hub/mlx-audio/` location into the new
    /// HF_HOME-redirected `~/Documents/huggingface/hub/mlx-audio/`
    /// location.
    ///
    /// **Why this exists.** Earlier builds of StreamScribe didn't set
    /// `HF_HOME`, so mlx-audio-swift wrote to its default location of
    /// `~/.cache/huggingface/hub/mlx-audio/<org>_<name>/`. This build
    /// sets `HF_HOME=~/Documents/huggingface` so all model data lives
    /// under Documents (visible in Finder, sideload-friendly). Users
    /// upgrading from the prior build still have their downloaded model
    /// in the legacy location; this helper moves it over once so they
    /// don't have to re-download a 2.5 GB model.
    ///
    /// **Layout.** mlx-audio-swift 0.1.2 uses a custom subdirectory
    /// shape (NOT the standard HF Hub layout): `mlx-audio/<org>_<name>/`
    /// with the model files sitting directly inside (no
    /// `snapshots/`/`blobs/`/`refs/` triad). We copy that directory
    /// verbatim.
    ///
    /// **Idempotency.** Skipped when the destination already has content
    /// (regular case for everyone after first upgrade run). Only the
    /// literal first-run-after-upgrade triggers the copy. After that the
    /// user can delete the legacy `~/.cache/huggingface/hub/mlx-audio/
    /// <folder>` if they want to reclaim disk.
    ///
    /// **Failure mode.** Errors during copy are logged and swallowed —
    /// the subsequent `fromPretrained` call will fall through to a
    /// normal download. The legacy files stay untouched so a future run
    /// can retry.
    static func migrateSideloadedCacheIfPresent(modelRepo: String) {
        let fm = FileManager.default
        let parts = modelRepo.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return }
        let org = String(parts[0])
        let name = String(parts[1])
        let mlxAudioDirName = "\(org)_\(name)"

        // Destination: the HF_HOME-redirected location under Documents.
        // After this app's setenv() call, mlx-audio-swift reads and
        // writes here.
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let destDir = docs
            .appendingPathComponent("huggingface")
            .appendingPathComponent("hub")
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent(mlxAudioDirName)

        // Destination already populated? Normal case after first
        // migration or for fresh installs. Nothing to do.
        if let contents = try? fm.contentsOfDirectory(atPath: destDir.path), !contents.isEmpty {
            return
        }

        // Source: legacy cache location from before HF_HOME was set.
        guard let home = ProcessInfo.processInfo.environment["HOME"] else { return }
        let legacyPath = "\(home)/.cache/huggingface/hub/mlx-audio/\(mlxAudioDirName)"
        let legacyURL = URL(fileURLWithPath: legacyPath)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: legacyPath, isDirectory: &isDir), isDir.boolValue else { return }
        guard let legacyContents = try? fm.contentsOfDirectory(atPath: legacyPath),
              !legacyContents.isEmpty else { return }

        print("[Parakeet] Legacy cache detected at \(legacyPath). Migrating to \(destDir.path)…")

        // Ensure ~/Documents/huggingface/hub/mlx-audio/ exists.
        // createDirectory with withIntermediateDirectories: true is a
        // no-op if already there.
        let destParent = destDir.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: destParent, withIntermediateDirectories: true)
        } catch {
            print("[Parakeet] Failed to prepare \(destParent.path): \(error.localizedDescription)")
            return
        }

        let migrateStart = Date()
        do {
            try fm.copyItem(at: legacyURL, to: destDir)
            let elapsed = Date().timeIntervalSince(migrateStart)
            print(String(format: "[Parakeet] Legacy cache migration complete in %.2fs.", elapsed))
        } catch {
            // Partial destination from a previous interrupted copy?
            // Remove and retry once.
            print("[Parakeet] Initial copy failed (\(error.localizedDescription)); retrying after removing partial destination…")
            try? fm.removeItem(at: destDir)
            do {
                try fm.copyItem(at: legacyURL, to: destDir)
                let elapsed = Date().timeIntervalSince(migrateStart)
                print(String(format: "[Parakeet] Legacy cache migration complete in %.2fs (after retry).", elapsed))
            } catch {
                print("[Parakeet] Legacy cache migration failed: \(error.localizedDescription). Falling through to normal download path.")
            }
        }
    }

    /// Delete the duplicate HF Hub layout copy of the model that
    /// mlx-audio-swift leaves behind in `<HF_HOME>/hub/models--<org>--<name>/`.
    ///
    /// **Why this exists.** mlx-audio-swift 0.1.2 downloads each model
    /// twice during `fromPretrained`:
    ///
    ///   1. To the standard HF Hub layout at
    ///      `<HF_HOME>/hub/models--<org>--<name>/` with `blobs/`,
    ///      `refs/`, `snapshots/` (swift-huggingface's canonical layout
    ///      — the library uses it as a staging area).
    ///   2. To its own runtime location at
    ///      `<HF_HOME>/hub/mlx-audio/models--<org>--<name>/` with the
    ///      flat files mlx-audio loads from at runtime.
    ///
    /// Both copies are real 2+ GB directories — not symlinked. For
    /// Parakeet 0.6b that's ~4.6 GB of disk for a single model. Once
    /// `fromPretrained` returns successfully, copy #1 is dead weight:
    /// no library code reads from it afterward, and a future
    /// `fromPretrained` call for the same repo short-circuits via
    /// copy #2.
    ///
    /// **Safety.** Only deletes copy #1 when copy #2 exists with
    /// content — defensive against running before the second copy is
    /// fully written. If something goes wrong (deletion fails, second
    /// copy is partial, etc.) the worst case is the original disk-
    /// wastage situation, never a broken model load.
    ///
    /// **Idempotency.** Safe to call on every prepare. After the first
    /// run, copy #1 is already gone and the existence check makes
    /// subsequent calls no-ops.
    static func cleanupDuplicateHubCopy(modelRepo: String) {
        let fm = FileManager.default
        let parts = modelRepo.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return }
        let org = String(parts[0])
        let name = String(parts[1])
        let hubLayoutDirName = "models--\(org)--\(name)"

        // Resolve HF_HOME root. The cleanup applies to wherever HF_HOME
        // points, so it works for both the Documents-redirected and
        // legacy ~/.cache layouts.
        let hubRoot: URL
        if let hfHome = ProcessInfo.processInfo.environment["HF_HOME"] {
            hubRoot = URL(fileURLWithPath: hfHome).appendingPathComponent("hub")
        } else if let home = ProcessInfo.processInfo.environment["HOME"] {
            hubRoot = URL(fileURLWithPath: home).appendingPathComponent(".cache/huggingface/hub")
        } else {
            return
        }

        // Copy #2 (the one we KEEP) — mlx-audio-swift's runtime location.
        // Empirically (from the log line "Model downloaded to: ..."
        // that mlx-audio-swift 0.1.2 prints at the end of every
        // fromPretrained), the runtime copy is named with an UNDERSCORE
        // between org and name, NOT the standard HF Hub `--` separator,
        // and it lives directly under `hub/mlx-audio/`. Example:
        // `hub/mlx-audio/mlx-community_parakeet-tdt-0.6b-v3/`.
        let mlxAudioDirName = "\(org)_\(name)"
        let runtimeCopy = hubRoot
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent(mlxAudioDirName)

        // Copy #1 (the one we DELETE) — the staging HF Hub layout.
        let stagingCopy = hubRoot.appendingPathComponent(hubLayoutDirName)

        // Safety check: only delete the staging copy if the runtime
        // copy exists and has content. We never want to delete the
        // only on-disk copy.
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: runtimeCopy.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }
        guard let runtimeContents = try? fm.contentsOfDirectory(atPath: runtimeCopy.path),
              !runtimeContents.isEmpty else {
            return
        }

        // Is the staging copy actually there?
        guard fm.fileExists(atPath: stagingCopy.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }

        // Compute reclaimed bytes for the log message — useful for
        // confirming the cleanup actually mattered. Sums the staging
        // directory recursively.
        let bytesReclaimed: Int64 = {
            guard let enumerator = fm.enumerator(atPath: stagingCopy.path) else { return 0 }
            var total: Int64 = 0
            for case let sub as String in enumerator {
                let full = (stagingCopy.path as NSString).appendingPathComponent(sub)
                if let attrs = try? fm.attributesOfItem(atPath: full),
                   let size = attrs[.size] as? Int64 {
                    total += size
                }
            }
            return total
        }()

        do {
            try fm.removeItem(at: stagingCopy)
            let mb = Double(bytesReclaimed) / 1_048_576.0
            print(String(format: "[Parakeet] Removed duplicate HF Hub staging copy at %@ (reclaimed %.0f MB).",
                         stagingCopy.path, mb))
        } catch {
            // Not fatal — disk is just less clean than ideal. Log and
            // continue.
            print("[Parakeet] Failed to remove duplicate at \(stagingCopy.path): \(error.localizedDescription)")
        }
    }
}
