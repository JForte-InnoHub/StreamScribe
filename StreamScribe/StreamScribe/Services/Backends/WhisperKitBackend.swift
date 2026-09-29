import Foundation
import CoreML
import WhisperKit

/// WhisperKit-backed transcription. Same path we've been using since v1 — CoreML Whisper with
/// the encoder typically routed to the Apple Neural Engine and the decoder to CPU/GPU.
actor WhisperKitBackend: TranscriptionBackend {

    private var whisperKit: WhisperKit?

    /// STYLE-ANCHOR PROMPT (2026-07-21). Root-cause fix for Whisper's
    /// ALL-CAPS collapse: the model's training data includes broadcast
    /// SDH captions (traditionally UPPERCASE), and hot, compressed
    /// broadcast audio — Fox News clips are the reliable field trigger
    /// — flips the decoder into that caption style, which then
    /// self-perpetuates through the window. Whisper's documented
    /// counter-lever is prompt conditioning: output style follows the
    /// prompt's style, so a well-cased, punctuated prompt biases every
    /// window toward mixed case BEFORE decoding starts.
    ///
    /// Deliberately STATIC — never previous-transcript text. Feeding
    /// prior output back as the prompt is the classic caps-perpetuation
    /// loop (one shouted chunk would seed the next). A fixed anchor has
    /// no feedback path. Domain-flavored as a free bonus: mildly biases
    /// toward hearing/finance vocabulary and healthy punctuation.
    /// The deshout post-pass remains as a rarely-needed backstop.
    private static let styleAnchorPrompt =
        "Thank you, Mr. Chairman. The committee will come to order. We welcome today's witnesses and look forward to their testimony on financial regulation."

    /// Opt-in gate for the style-anchor prompt. Defaults false (see
    /// the regression note at the DecodingOptions wiring).
    static var styleAnchorPromptEnabled: Bool {
        UserDefaults.standard.bool(forKey: "whisper.styleAnchorPromptEnabled")
    }

    /// `styleAnchorPrompt` encoded with the loaded model's tokenizer.
    /// Computed once per model load in `prepare()`; nil until then
    /// (DecodingOptions treats nil promptTokens as "no prompt").
    private var styleAnchorPromptTokens: [Int]?
    private var loadedModelName: String?
    private let modelName: String
    /// nil = auto-detect; ISO 639-1 code (e.g. "en", "es") = force language.
    private let languageCode: String?
    /// Phase 7: compute unit override. `.auto` (default) lets WhisperKit pick
    /// — same as every prior phase. Non-auto values are converted to
    /// `MLComputeUnits` and passed via `WhisperKitConfig.computeOptions`,
    /// applied to both the audio encoder and text decoder. WhisperKit
    /// supports separate per-component routing too (encoder on ANE, decoder
    /// on GPU) via `ModelComputeOptions(audioEncoderCompute:textDecoderCompute:)`;
    /// for simplicity we apply the same selection to both, which is enough
    /// for the multi-pass design's stated use case ("raw vs refined") even if
    /// it isn't the finest-grained possible.
    private let computeUnits: ComputeUnits

    /// Free-form tag included in `[WhisperKit]` log lines so raw vs refined
    /// backend instances can be told apart at a glance. Set at init by the
    /// caller (`makeTranscriber`) — typically "raw" or "refined". Defaults to
    /// empty for callers that don't care; logs then just say `[WhisperKit]`.
    private let role: String

    /// Monotonically incrementing call counter, for log readability. Reset in
    /// `reset()` so per-session logs start at #1.
    private var transcribeCallCount: Int = 0

    /// One-shot: only log the detected language the first time we see a
    /// non-empty value. WhisperKit's `TranscriptionResult.language` is a
    /// non-optional String (empty when unknown), so we filter on `!isEmpty`
    /// rather than `if let`. Reset in `reset()`.
    private var loggedLanguage: Bool = false

    init(modelName: String, languageCode: String?, computeUnits: ComputeUnits = .auto, role: String = "") {
        self.modelName = modelName
        self.languageCode = languageCode
        self.computeUnits = computeUnits
        self.role = role
    }

    func loadingDescription() -> String {
        "Loading Whisper model \(WhisperKitBackend.shortName(modelName))…"
    }

    func prepare() async throws {
        if whisperKit != nil, loadedModelName == modelName { return }

        // Look for a bundled copy of this model first. We ship the default model
        // (large-v3-turbo) inside the app under Resources/WhisperModels/<modelName>/
        // so first-launch transcription works offline without a 600+ MB download.
        // Non-default models (tiny, base, distil, etc.) aren't bundled — those still
        // resolve to the HuggingFace cache and download on first use.
        //
        // The lookup is folder-by-name, not file-by-name, so WhisperKit gets the
        // directory containing MelSpectrogram.mlmodelc/, AudioEncoder.mlmodelc/,
        // TextDecoder.mlmodelc/, etc. Make sure when adding the model to Xcode you
        // pick "Create folder references" (blue folder), NOT groups (yellow folder).
        // Groups flatten the tree and the .mlmodelc package contents will land in
        // the bundle root with name collisions; folder refs preserve the hierarchy
        // verbatim, which is what CoreML needs.
        let bundledFolder = Bundle.main.path(
            forResource: modelName,
            ofType: nil,
            inDirectory: "WhisperModels"
        )

        // Probe candidate cache locations BEFORE asking WhisperKit to load the
        // model. After the load, we'll re-probe to detect whether anything new
        // appeared on disk — which tells us "cache hit" vs "downloaded this run."
        // We don't have a public API to ask WhisperKit "where did you load from?"
        // so we infer it by watching the filesystem.
        let cacheCandidates = WhisperKitBackend.cacheCandidatePaths(modelName: modelName)
        let preLoadExisting: [String: Bool] = cacheCandidates.reduce(into: [:]) { dict, path in
            dict[path] = FileManager.default.fileExists(atPath: path)
        }

        // Phase 7: optional compute unit override. `.auto` keeps
        // WhisperKit's own encoder/decoder routing; non-auto values map
        // to MLComputeUnits and are applied to both. Either way we now
        // pin `melCompute` ourselves — see `melComputeUnits` below.
        let computeOptions: ModelComputeOptions = {
            guard let mlUnits = self.mlComputeUnits else {
                // `.auto`: leave audioEncoder/textDecoder nil-defaulted so
                // WhisperKit's own choices apply verbatim (encoder
                // `.cpuAndNeuralEngine` on macOS 14+, decoder
                // `.cpuAndNeuralEngine`). Only mel is overridden.
                return ModelComputeOptions(melCompute: Self.melComputeUnits)
            }
            return ModelComputeOptions(
                melCompute: Self.melComputeUnits,
                audioEncoderCompute: mlUnits,
                textDecoderCompute: mlUnits
            )
        }()

        // OFFLINE LOAD FOR CACHED MODELS (2026-08-07). Passing
        // `modelFolder: nil` + `download: true` tells WhisperKit to
        // resolve the model through the HuggingFace Hub — and it does
        // that even when the model is ALREADY sitting complete in the
        // on-disk cache, because Hub resolution is how it discovers
        // the path. On a normal network that's an invisible check; on
        // a Netskope fleet machine it stalls and the timeout surfaces
        // as "Model not found. Please check the model or repo name"
        // for a model the app itself just probed as `cached`.
        //
        // (The `HF_HUB_OFFLINE` env var set around this call in
        // TranscriptionEngine does NOT prevent it: that's a Python
        // huggingface_hub variable, and WhisperKit's Swift Hub client
        // never reads it. Pointing `modelFolder` at the local copy is
        // what actually guarantees no network access — an explicit
        // path means there is nothing left to resolve.)
        //
        // Priority: bundled copy → on-disk cache → Hub (first run only).
        let localFolder = bundledFolder ?? Self.resolvedLocalModelFolder(modelName: modelName)
        if bundledFolder == nil, let localFolder {
            print("[Whisper] Loading \(modelName) from on-disk cache (no network): \(localFolder)")
        }

        let config = WhisperKitConfig(
            model: modelName,
            modelFolder: localFolder,               // nil ONLY when we have no local copy
            computeOptions: computeOptions,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: localFolder == nil            // download only when nothing is on disk
        )
        whisperKit = try await WhisperKit(config)
        loadedModelName = modelName

        // Encode the style-anchor prompt with this model's tokenizer.
        // Leading space per GPT-2-style BPE convention; filter defends
        // against any special tokens the encoder might emit (mirrors
        // WhisperKit's own prompt-handling examples). Whisper's prompt
        // budget is 224 tokens; this is ~30.
        if let tokenizer = whisperKit?.tokenizer {
            let encoded = tokenizer.encode(text: " " + Self.styleAnchorPrompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            styleAnchorPromptTokens = encoded
            print("\(role.isEmpty ? "[WhisperKit]" : "[WhisperKit/\(role)]") Style-anchor prompt encoded (\(encoded.count) tokens).")
        } else {
            styleAnchorPromptTokens = nil
        }

        // After load: report exactly what happened, where files live, and whether
        // they look healthy. This is the primary diagnostic when transcription
        // quality differs between runs — corrupted/partial model files manifest
        // as silent audio drops or hallucinations rather than load errors.
        Self.logResolutionSummary(
            modelName: modelName,
            bundledFolder: bundledFolder,
            cacheCandidates: cacheCandidates,
            preLoadExisting: preLoadExisting
        )
    }

    // MARK: - Resolution diagnostics

    /// Whether a COMPLETE downloaded copy of `modelName` exists in any of
    /// the cache locations WhisperKit is known to use (see
    /// `isCompleteModelFolder` — an empty or half-pulled directory left
    /// behind by a failed earlier download doesn't count as "cached").
    /// Used by `ModelDownloadManager` to drive the sidebar's
    /// "Downloaded" / "Not downloaded" indicator without instantiating a
    /// full backend just to check.
    ///
    /// Also returns true if the model is bundled inside the app (the default
    /// Whisper variant we ship in Resources/WhisperModels/) — a bundled model
    /// is effectively "always cached" from the user's perspective.
    static func isModelCached(modelName: String) -> Bool {
        // Bundled-resource check first — the default model lives in the app
        // bundle and never appears in the HF cache directory.
        if Bundle.main.path(forResource: modelName, ofType: nil, inDirectory: "WhisperModels") != nil {
            return true
        }
        // Same completeness test the loader uses (2026-09-29). Previously
        // this was a non-empty-directory check, which reported "Downloaded"
        // for a half-pulled tree the loader would then reject — the sidebar
        // said the model was ready while every session failed to start.
        // Agreeing with `resolvedLocalModelFolder` means a partial tree now
        // reads as "Not downloaded" and the re-download actually resolves it.
        return cacheCandidatePaths(modelName: modelName).contains(where: isCompleteModelFolder)
    }

    /// Possible disk locations where WhisperKit might have placed a downloaded
    /// model. The actual location depends on the WhisperKit version — we probe a
    /// few historically-known paths rather than depending on internal API.
    /// Returns absolute paths in priority order.
    ///
    /// Visibility note: was `private` originally — kept internal now so the
    /// `ModelDownloadManager`'s `isModelCached` helper above can reuse the
    /// same path list. No callers outside this module.
    /// First cache location that holds a COMPLETE copy of `modelName`,
    /// or nil if none does. The result suppresses the download path, so
    /// a half-pulled folder that merely exists must NOT convince us to
    /// load offline.
    /// COMPLETENESS (2026-09-29). The old test — "contains at least one
    /// `.mlmodelc`" — was not strict enough, and on a fleet machine it
    /// produced an unbreakable download loop:
    ///
    ///   1. The R2 mirror downloads and extracts a COMPLETE copy into the
    ///      unified models root under Application Support.
    ///   2. That directory was not in `cacheCandidatePaths` at all, so
    ///      this returned nil, `modelFolder` stayed nil, `download` stayed
    ///      true, and WhisperKit went to HuggingFace anyway.
    ///   3. On a Netskope fleet machine the Hub pull times out after 300 s
    ///      — but not before writing a PARTIAL tree into
    ///      `~/Documents/huggingface/...`, with one or two `.mlmodelc`
    ///      folders in it.
    ///   4. Every subsequent attempt matched that partial tree here, handed
    ///      it to WhisperKit as `modelFolder`, and got back "Model file not
    ///      found" — for a model whose complete copy was already on disk a
    ///      few directories away.
    ///
    /// The user in the report downloaded 477 MB twice inside 90 seconds and
    /// loaded neither copy. Both halves are fixed: the mirror's extraction
    /// directory now leads `cacheCandidatePaths`, and a candidate must now
    /// carry the full model — every required `.mlmodelc` package, each with
    /// its `coremldata.bin` and `weights/weight.bin` — before it can
    /// suppress the download. We also keep scanning after a rejection
    /// instead of failing the whole lookup, so one bad candidate can no
    /// longer shadow a good one.
    static func resolvedLocalModelFolder(modelName: String) -> String? {
        for path in cacheCandidatePaths(modelName: modelName) {
            if isCompleteModelFolder(path) { return path }
        }
        return nil
    }

    /// Required `.mlmodelc` packages for a WhisperKit model folder.
    /// `TextDecoderContextPrefill.mlmodelc` is deliberately NOT required —
    /// it is absent from several published variants and WhisperKit treats
    /// it as optional.
    private static let requiredModelPackages = [
        "MelSpectrogram.mlmodelc",
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
    ]

    /// True when `path` holds a complete, loadable WhisperKit model.
    /// Checks package presence AND the two files inside each package that
    /// an interrupted download leaves missing, which is what distinguishes
    /// a half-pulled tree from a good one.
    static func isCompleteModelFolder(_ path: String) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }

        for package in requiredModelPackages {
            let packagePath = (path as NSString).appendingPathComponent(package)
            var packageIsDir: ObjCBool = false
            guard fm.fileExists(atPath: packagePath, isDirectory: &packageIsDir),
                  packageIsDir.boolValue else {
                print("[Whisper] Cache candidate rejected (missing \(package)): \(path)")
                return false
            }
            for required in ["coremldata.bin", "weights/weight.bin"] {
                let filePath = (packagePath as NSString).appendingPathComponent(required)
                guard fm.fileExists(atPath: filePath) else {
                    print("[Whisper] Cache candidate rejected (\(package) missing \(required)): \(path)")
                    return false
                }
            }
        }
        return true
    }

    static func cacheCandidatePaths(modelName: String) -> [String] {
        let fm = FileManager.default
        var paths: [String] = []

        // ~/Library/Application Support/StreamScribe/Models/huggingface/...
        // FIRST, and this is the important one: it is where
        // `ModelDownloadManager.mirror(for:)` extracts the R2 tarball for
        // `.whisper(modelName)`. It was missing from this list entirely,
        // which meant the mirror — the ONLY download route that works on a
        // fleet machine with no HuggingFace access — wrote a complete model
        // that the loader then refused to look at. Must stay in sync with
        // `ModelDownloadManager.streamScribeModelsRoot()` +
        // `StreamScribeApp.setupUnifiedModelsRoot()`.
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            paths.append(appSupport
                .appendingPathComponent("StreamScribe")
                .appendingPathComponent("Models")
                .appendingPathComponent("huggingface")
                .appendingPathComponent("models")
                .appendingPathComponent("argmaxinc")
                .appendingPathComponent("whisperkit-coreml")
                .appendingPathComponent(modelName)
                .path)
        }

        // ~/Documents/huggingface/... — observed location for argmax-oss-swift v0.18.0
        // (matches what the user saw in their cache after the test download).
        // This is also WhisperKit's own `downloadBase`, so it is where a
        // Hub pull lands — complete or partial.
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            paths.append(docs
                .appendingPathComponent("huggingface")
                .appendingPathComponent("models")
                .appendingPathComponent("argmaxinc")
                .appendingPathComponent("whisperkit-coreml")
                .appendingPathComponent(modelName)
                .path)
        }

        // ~/.cache/huggingface/... — Hugging Face Hub's default cross-platform cache,
        // used by some other Argmax loaders. Worth probing as a fallback.
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            paths.append("\(home)/.cache/huggingface/hub/models--argmaxinc--whisperkit-coreml/snapshots/\(modelName)")
        }

        // App container Caches dir — some sandboxed configurations land here.
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            paths.append(caches
                .appendingPathComponent("huggingface")
                .appendingPathComponent("models")
                .appendingPathComponent("argmaxinc")
                .appendingPathComponent("whisperkit-coreml")
                .appendingPathComponent(modelName)
                .path)
        }

        return paths
    }

    /// Print a clear, multi-line summary of where the model was actually loaded
    /// from, including file inventory + size totals. Helps diagnose corrupted
    /// bundles, partial Git LFS pulls, and revision drift between bundle and
    /// HuggingFace.
    private static func logResolutionSummary(
        modelName: String,
        bundledFolder: String?,
        cacheCandidates: [String],
        preLoadExisting: [String: Bool]
    ) {
        let fm = FileManager.default

        // Determine effective source. Order of preference: bundled path (if
        // present and non-empty) → newly-downloaded cache → existing cache hit
        // → unknown.
        let source: String
        let effectivePath: String?
        if let bp = bundledFolder, fm.fileExists(atPath: bp) {
            source = "BUNDLED in app Resources"
            effectivePath = bp
        } else {
            // Look for a cache path that exists now. If it didn't exist before
            // the load, mark it as newly downloaded.
            let postLoadExisting = cacheCandidates.first { fm.fileExists(atPath: $0) }
            if let path = postLoadExisting {
                let wasPresentBefore = preLoadExisting[path] ?? false
                source = wasPresentBefore
                    ? "HUGGINGFACE CACHE (existing)"
                    : "HUGGINGFACE DOWNLOAD (new this run)"
                effectivePath = path
            } else {
                source = "UNKNOWN (no bundled copy and no cache path matched)"
                effectivePath = nil
            }
        }

        var lines: [String] = []
        lines.append("[WhisperKitBackend] Model resolution summary:")
        lines.append("  Requested model: \(modelName)")
        lines.append("  Source:          \(source)")
        if let path = effectivePath {
            lines.append("  Path:            \(path)")
            // Inventory the model directory so we catch corrupted/truncated copies.
            // We only list immediate children — that's what matters for sanity
            // checking. Going deeper would explode for .mlmodelc packages.
            if let children = try? fm.contentsOfDirectory(atPath: path) {
                let sorted = children.sorted()
                var totalBytes: Int64 = 0
                lines.append("  Contents:")
                for child in sorted {
                    let childPath = (path as NSString).appendingPathComponent(child)
                    let bytes = directorySize(at: childPath)
                    totalBytes += bytes
                    lines.append("    \(child) — \(formatBytes(bytes))")
                }
                lines.append("  Total size:      \(formatBytes(totalBytes))")
            } else {
                lines.append("  Contents:        (could not read directory)")
            }
        } else {
            // Unknown case: dump the candidate paths we checked so the user knows
            // where we looked. Helps diagnose new WhisperKit versions that may
            // change the cache layout.
            lines.append("  Probed cache locations:")
            for candidate in cacheCandidates {
                lines.append("    \(candidate)")
            }
        }
        print(lines.joined(separator: "\n"))
    }

    /// Recursive size of a file or directory. .mlmodelc packages are directories
    /// containing weights, metadata, and compiled code; we want the total.
    private static func directorySize(at path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Human-friendly byte size (kB/MB/GB). We use 1024-based units to match what
    /// macOS displays in Finder for these particular sizes; the difference vs
    /// SI 1000-based units is small and the goal is a quick-scan number.
    private static func formatBytes(_ bytes: Int64) -> String {
        let units: [(threshold: Int64, suffix: String, divisor: Double)] = [
            (1_073_741_824, "GB", 1_073_741_824.0),
            (1_048_576,     "MB", 1_048_576.0),
            (1_024,         "KB", 1_024.0),
        ]
        for unit in units where bytes >= unit.threshold {
            return String(format: "%.1f %@", Double(bytes) / unit.divisor, unit.suffix)
        }
        return "\(bytes) B"
    }

    func transcribe(samples: [Float], chunkStartTime: TimeInterval) async throws -> TranscriptionResult {
        let tag = role.isEmpty ? "[WhisperKit]" : "[WhisperKit/\(role)]"

        guard let whisperKit else {
            print("\(tag) transcribe() called before prepare() — returning empty.")
            return TranscriptionResult(segments: [], detectedLanguage: nil)
        }

        transcribeCallCount += 1
        let callNum = transcribeCallCount
        let audioSeconds = Double(samples.count) / 16_000.0
        let chunkEnd = chunkStartTime + audioSeconds
        print(String(format: "\(tag) #%d transcribe start: chunk [%.2fs..%.2fs] (%d samples, %.2fs audio)",
                     callNum, chunkStartTime, chunkEnd, samples.count, audioSeconds))

        let inferStart = Date()

        // Decode options:
        // - `language`: explicit code = force it; nil = auto-detect.
        //   Forcing a language skips per-chunk language detection, which is unreliable
        //   on short chunks (we send 5s; Whisper's window is 30s and it pads with zeros).
        //   The Turbo variant in particular has weak language detection on short clips.
        // - `detectLanguage: false` when we have an explicit language; `true` when auto.
        // - `withoutTimestamps: false` keeps Whisper emitting <|t0.00|>...<|t5.00|> tokens
        //   so we get per-segment timing back.
        let opts = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: languageCode,
            temperature: 0.0,
            temperatureFallbackCount: 5,
            usePrefillPrompt: true,
            detectLanguage: languageCode == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: true,
            // Style-anchor prompt — DEFAULT OFF after a same-week
            // field regression (2026-07-22): with the prompt active, a
            // 273s local clip with diarizer-confirmed speech across
            // 95.6% of its frames transcribed only its first 13
            // seconds — chunks #2-#10 bailed in ~0.6s each with empty
            // output. Prompt conditioning shifts the no-speech and
            // log-prob distributions the decode gates
            // (noSpeechThreshold/firstTokenLogProbThreshold) were
            // tuned against, tipping real speech into "silence".
            // Re-enabling requires a controlled A/B (per-chunk RTF +
            // emptiness on a known-good clip AND a Fox caps clip),
            // likely with relaxed gates while the prompt is active:
            //   defaults write PLUS-PR.StreamScribe whisper.styleAnchorPromptEnabled -bool YES
            promptTokens: Self.styleAnchorPromptEnabled ? styleAnchorPromptTokens : nil,
            suppressBlank: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.6
        )

        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: opts)
        let inferElapsed = Date().timeIntervalSince(inferStart)
        let rtf = audioSeconds > 0 ? inferElapsed / audioSeconds : 0

        guard let result = results.first else {
            print(String(format: "\(tag) #%d inference complete in %.2fs (RTF=%.2fx) — no result.",
                         callNum, inferElapsed, rtf))
            return TranscriptionResult(segments: [], detectedLanguage: nil)
        }

        // WhisperKit's TranscriptionResult.language is a non-optional String,
        // empty when no language was detected. Filter on `!isEmpty` rather
        // than `if let` — using optional binding here is a compile error.
        if !loggedLanguage, !result.language.isEmpty {
            print("\(tag) Detected language: \(result.language)")
            loggedLanguage = true
        }

        let segs: [TranscriptSegment] = result.segments.compactMap { ws in
            let text = ws.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            // Map WhisperKit's per-word timing onto our `WordToken` model,
            // remapping the per-chunk-relative timestamps to the absolute
            // stream timeline via `chunkStartTime` (same offset we apply
            // to the segment-level start/end above).
            //
            // WhisperKit's `words` may be `[WordTiming]?` or `[WordTiming]`
            // depending on WhisperKit version. We treat any empty/nil
            // result as "no word timing for this segment" — `nil` on our
            // side. The splitter falls back to segment-level voting when
            // it sees nil. Short segments and chunk-boundary segments often
            // come back without word data even with `wordTimestamps: true`.
            let rawWords = ws.words ?? []
            let tokens: [WordToken]? = rawWords.isEmpty ? nil : rawWords.map { wt in
                WordToken(
                    text: wt.word,
                    start: chunkStartTime + Double(wt.start),
                    end: chunkStartTime + Double(wt.end)
                )
            }

            return TranscriptSegment(
                text: text,
                start: chunkStartTime + Double(ws.start),
                end: chunkStartTime + Double(ws.end),
                speaker: nil,
                isFinalized: true,
                words: tokens
            )
        }

        let outChars = segs.reduce(0) { $0 + $1.text.count }
        print(String(format: "\(tag) #%d emit: %d segment(s), %d char(s), inference %.2fs (RTF=%.2fx, %dx realtime)",
                     callNum, segs.count, outChars, inferElapsed, rtf, rtf > 0 ? Int((1.0 / rtf).rounded()) : 0))

        return TranscriptionResult(segments: segs, detectedLanguage: result.language)
    }

    func reset() async {
        // WhisperKit is stateless across `transcribe` calls — nothing in the
        // library to reset. We do clear our own per-session log counters so
        // the next session's logs start at #1.
        let tag = role.isEmpty ? "[WhisperKit]" : "[WhisperKit/\(role)]"
        transcribeCallCount = 0
        loggedLanguage = false
        print("\(tag) reset.")
    }

    /// Drop the loaded model. Subsequent `prepare()` will re-load (re-running
    /// CoreML compilation on first call after unload — expect a few seconds).
    ///
    /// Used by the multi-pass refinement pipeline: load → infer → unload per
    /// window, so the refined Whisper isn't sitting in GPU memory between
    /// windows and pressuring the raw pass (Parakeet on MLX shares unified
    /// memory with anything CoreML has resident). The empirical observation
    /// driving this: with idle Whisper-Large-v3-Turbo loaded, Parakeet
    /// inference cost on 5s chunks went from ~0.5s to ~4s; after Whisper ran
    /// once it dropped to ~1.6s. Unloading after each refinement window aims
    /// to keep Parakeet at the unencumbered ~0.5s baseline.
    ///
    /// We nil out both `whisperKit` and `loadedModelName` so the next
    /// `prepare()` short-circuit check (`whisperKit != nil &&
    /// loadedModelName == modelName`) correctly re-enters the load path.
    func unload() async {
        let tag = role.isEmpty ? "[WhisperKit]" : "[WhisperKit/\(role)]"
        guard whisperKit != nil else {
            // Not loaded — silent no-op. Callers can call unload() defensively
            // without needing to know the load state.
            return
        }
        whisperKit = nil
        loadedModelName = nil
        print("\(tag) unloaded model.")
    }

    // MARK: - Helpers

    /// Compute units for WhisperKit's MelSpectrogram model.
    ///
    /// CRASH FIX (2026-09-29). WhisperKit's `ModelComputeOptions` defaults
    /// `melCompute` to `.cpuAndGPU`, and it is the ONLY component of the
    /// Whisper pipeline with the GPU in its compute mask — the audio
    /// encoder and text decoder both default to `.cpuAndNeuralEngine`.
    /// That makes MelSpectrogram the single path from this app into
    /// MetalPerformanceShadersGraph, and on macOS 15.7.9 (Mac16,8,
    /// AGXMetalG16X, MPSGraph 5.6.2) the mel filterbank matmul trips a
    /// Metal assertion while MPSGraph specializes the graph:
    ///
    ///     __assert_rtn → MTLReportFailure
    ///     → GPU::MatMulOpHandler::getQuantizationParameters(...)
    ///     → GPU::MatMulOpHandler::postInitializeHook()
    ///     → GPURegionRuntime::initializeOps()
    ///     → -[MPSGraphExecutable specializeWithDevice:...]
    ///     → E5RT::Ops::MpsGraphInferenceOperation::...SubmitWorkToMpsGraph
    ///     → -[MLE5Engine _predictionFromFeatures:options:completionHandler:]
    ///
    /// on `com.apple.coreml.DefaultAsyncPredictionQueue`. It is an abort
    /// inside Apple's stack, not a Swift error, so there is nothing to
    /// catch — the process dies on the first mel prediction of the first
    /// session. Observed on a fleet machine (1.1.5 build 58); not
    /// reproducible on macOS 26.x, which is why it never showed up in
    /// development.
    ///
    /// `.cpuOnly` removes the GPU from the mask and takes MPSGraph out of
    /// the pipeline entirely. The cost is negligible: MelSpectrogram is a
    /// single 373 KB filterbank matmul against the STFT magnitudes, low
    /// single-digit milliseconds per 30 s window on CPU, against an
    /// encoder+decoder that are three orders of magnitude larger and stay
    /// on the ANE. Argmax's own benchmarks put mel at ~1–3% of pipeline
    /// time even on the GPU.
    ///
    /// Applied unconditionally rather than gated on `ProcessInfo`'s OS
    /// version: we know the GPU path aborts on at least one shipping
    /// macOS, we have no way to enumerate which GPU/OS pairs are
    /// affected, and the thing we would be buying back is a couple of
    /// milliseconds. If mel ever becomes a measured bottleneck, gate it
    /// on `if #available(macOS 26, *)` and keep `.cpuOnly` below that.
    private static let melComputeUnits: MLComputeUnits = .cpuOnly

    /// Maps our `ComputeUnits` hint to `MLComputeUnits`. Returns nil for
    /// `.auto`, meaning "leave WhisperKit's own encoder/decoder routing
    /// alone." (Note this no longer means "pass no `computeOptions`" —
    /// we always pass one now in order to pin `melCompute`; the nil case
    /// just omits the encoder/decoder overrides, which restores the
    /// library defaults for those two exactly.)
    private var mlComputeUnits: MLComputeUnits? {
        switch computeUnits {
        case .auto:                return nil
        case .cpuOnly:             return .cpuOnly
        case .cpuAndGPU:           return .cpuAndGPU
        case .cpuAndNeuralEngine:  return .cpuAndNeuralEngine
        case .all:                 return .all
        }
    }

    static func shortName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "openai_whisper-", with: "")
    }
}
