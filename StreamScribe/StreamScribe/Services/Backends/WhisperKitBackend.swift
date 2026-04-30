import Foundation
import CoreML
import WhisperKit

/// WhisperKit-backed transcription. Same path we've been using since v1 — CoreML Whisper with
/// the encoder typically routed to the Apple Neural Engine and the decoder to CPU/GPU.
actor WhisperKitBackend: TranscriptionBackend {

    private var whisperKit: WhisperKit?
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

        // Phase 7: optional compute unit override. `.auto` skips
        // `computeOptions` entirely (WhisperKit's defaults apply) — that's
        // the no-op shipping default. Non-auto values map to MLComputeUnits
        // and we pass the same selection to both encoder and decoder. We
        // never apply non-auto to the prefill/melSpectrogram components
        // because those are tiny and rarely the bottleneck; keeping their
        // routing on library defaults reduces the surface area of "did our
        // override break something."
        let computeOptions: ModelComputeOptions? = {
            guard let mlUnits = self.mlComputeUnits else { return nil }
            return ModelComputeOptions(
                audioEncoderCompute: mlUnits,
                textDecoderCompute: mlUnits
            )
        }()

        let config = WhisperKitConfig(
            model: modelName,
            modelFolder: bundledFolder,             // nil = HF cache; non-nil = bundle
            computeOptions: computeOptions,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: bundledFolder == nil          // skip the download path when bundled
        )
        whisperKit = try await WhisperKit(config)
        loadedModelName = modelName

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

    /// Whether a downloaded copy of `modelName` exists in any of the cache
    /// locations WhisperKit is known to use. Returns true if any candidate
    /// path exists as a directory containing at least one file (an empty
    /// directory left behind by a failed earlier download shouldn't count
    /// as "cached"). Used by `ModelDownloadManager` to drive the sidebar's
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
        let fm = FileManager.default
        for path in cacheCandidatePaths(modelName: modelName) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            // Non-empty check — empty cache dirs do exist after failed pulls.
            if let contents = try? fm.contentsOfDirectory(atPath: path), !contents.isEmpty {
                return true
            }
        }
        return false
    }

    /// Possible disk locations where WhisperKit might have placed a downloaded
    /// model. The actual location depends on the WhisperKit version — we probe a
    /// few historically-known paths rather than depending on internal API.
    /// Returns absolute paths in priority order.
    ///
    /// Visibility note: was `private` originally — kept internal now so the
    /// `ModelDownloadManager`'s `isModelCached` helper above can reuse the
    /// same path list. No callers outside this module.
    static func cacheCandidatePaths(modelName: String) -> [String] {
        let fm = FileManager.default
        var paths: [String] = []

        // ~/Documents/huggingface/... — observed location for argmax-oss-swift v0.18.0
        // (matches what the user saw in their cache after the test download).
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

    /// Maps our `ComputeUnits` hint to `MLComputeUnits`. Returns nil for
    /// `.auto` — caller should NOT pass `computeOptions` in that case
    /// (`WhisperKitConfig` treats nil as "use the library defaults," which
    /// is what `.auto` means semantically).
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
