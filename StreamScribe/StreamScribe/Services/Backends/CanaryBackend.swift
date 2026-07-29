import Foundation
import CoreML
import FluidAudio

/// Transcription backend for NVIDIA Canary-1B v2 (FluidAudio CoreML,
/// int4) — **batch-only** since the streaming rewrite's post-mortem.
///
/// The original integration wrapped the fork's sliding-window
/// streaming API: 15s windows advancing 2s, meaning every second of
/// audio was decoded ~7x, with overlap dedup that truncation
/// artifacts routinely defeated (duplicated text) — slow AND wrong.
/// Batch mode transcribes non-overlapping 15s windows: each second
/// decoded exactly once, no dedup existing to fail.
///
/// **Where Canary belongs:** the REFINED slot and static-file mode —
/// accuracy is its case (attention encoder-decoder, ~2.1% WER), and
/// batch throughput is ample there. The raw slot works but wastes
/// cycles (5s chunks zero-pad to 15s windows); prefer Parakeet raw.
///
/// **Segment times:** the model emits no token timestamps, so each
/// 15s window's text splits into sentences with times interpolated by
/// character position within the window — same philosophy as
/// `TranscriptSegment.time(atCharacterOffset:)`, and granular enough
/// for diarizer speaker attribution.
actor CanaryBackend: TranscriptionBackend {

    private var manager: CanaryManager?

    private static let windowSeconds: TimeInterval = 15.0

    func loadingDescription() -> String {
        "Loading Canary 1B v2 (CoreML)…"
    }

    /// Disk probe for the sidebar status row — true when the full
    /// required set is present.
    nonisolated static func isModelCached() -> Bool {
        let repoDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FluidAudio")
            .appendingPathComponent("canary-1b-v2-coreml")
        return requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: repoDir.appendingPathComponent($0).path)
        }
    }

    /// Public entry for the sidebar's manual download button — same
    /// bundle flow prepare() uses, runnable without starting a session
    /// so download and load can be tested separately.
    static func downloadModels() async throws {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try await ensureModelBundle(fluidAudioDir: appSupport.appendingPathComponent("FluidAudio"))
    }

    func prepare() async throws {
        guard manager == nil else { return }

        ModelRegistry.baseURL = FluidAudioBackend.resolvedMirrorURL
        print("[Canary] Model registry: \(ModelRegistry.baseURL)")

        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let fluidAudioDir = appSupport.appendingPathComponent("FluidAudio")
        let dir = fluidAudioDir.appendingPathComponent("canary")

        // Model delivery via the app's R2 TARBALL flow — NOT
        // FluidAudio's HuggingFace-shaped downloader (plain R2 object
        // storage answers its /resolve/ and /api/ URLs with HTML
        // error pages).
        try await Self.ensureModelBundle(fluidAudioDir: fluidAudioDir)

        let models = try await CanaryModels.load(from: dir)
        let m = CanaryManager()
        m.initialize(models: models)
        self.manager = m
        print("[Canary] Models loaded (batch mode).")
    }

    func transcribe(samples: [Float], chunkStartTime: TimeInterval) async throws -> TranscriptionResult {
        guard let manager else {
            throw NSError(domain: "CanaryBackend", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Canary backend not prepared"])
        }

        let windowTexts = try await manager.transcribeBatch(samples)
        var segments: [TranscriptSegment] = []

        for (i, text) in windowTexts.enumerated() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let windowStart = chunkStartTime + Double(i) * Self.windowSeconds
            // Final window may be zero-padded; clamp its end to the
            // real audio extent.
            let windowEnd = min(
                windowStart + Self.windowSeconds,
                chunkStartTime + Double(samples.count) / 16_000.0
            )
            segments.append(contentsOf: Self.sentenceSegments(
                from: trimmed, windowStart: windowStart, windowEnd: windowEnd
            ))
        }

        return TranscriptionResult(segments: segments, detectedLanguage: "en")
    }

    /// Split a window's text into sentence-ish segments with times
    /// interpolated by character position — no token timestamps
    /// exist, and 15s single segments are too coarse for speaker
    /// attribution.
    private static func sentenceSegments(
        from text: String, windowStart: TimeInterval, windowEnd: TimeInterval
    ) -> [TranscriptSegment] {
        let duration = max(windowEnd - windowStart, 0.001)
        let totalChars = max(text.count, 1)

        // Sentence boundaries: ., !, ? followed by a space.
        var pieces: [(text: String, startChar: Int)] = []
        var current = ""
        var currentStart = 0
        var charIndex = 0
        var previous: Character? = nil
        for ch in text {
            if let p = previous, ".!?".contains(p), ch == " " {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { pieces.append((trimmed, currentStart)) }
                current = ""
                currentStart = charIndex + 1
            }
            current.append(ch)
            previous = ch
            charIndex += 1
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { pieces.append((tail, currentStart)) }

        return pieces.enumerated().map { (i, piece) in
            let startFrac = Double(piece.startChar) / Double(totalChars)
            let endChar = (i + 1 < pieces.count) ? pieces[i + 1].startChar : totalChars
            let endFrac = Double(endChar) / Double(totalChars)
            return TranscriptSegment(
                text: piece.text,
                start: windowStart + duration * startFrac,
                end: windowStart + duration * endFrac,
                speaker: nil,
                isFinalized: true
            )
        }
    }

    func reset() async {
        manager?.reset()
    }

    func unload() async {
        manager = nil
    }

    // MARK: - Model bundle delivery (R2 tarball)

    /// Every file the loader reads. Any shortfall wipes the directory
    /// and re-extracts fresh.
    private static let requiredFiles = [
        "Preprocessor.mlmodelc", "EncoderInt4.mlmodelc", "DecoderInt4.mlmodelc",
        "vocab.json", "projection_weights.bin", "projection_bias.bin",
    ]

    private static func ensureModelBundle(fluidAudioDir: URL) async throws {
        let repoDir = fluidAudioDir.appendingPathComponent("canary-1b-v2-coreml")
        let missing = requiredFiles.filter {
            !FileManager.default.fileExists(atPath: repoDir.appendingPathComponent($0).path)
        }
        if missing.isEmpty { return }
        if FileManager.default.fileExists(atPath: repoDir.path) {
            print("[Canary] Cache incomplete (missing: \(missing.joined(separator: ", "))) — re-downloading bundle.")
            try? FileManager.default.removeItem(at: repoDir)
        }

        var base = FluidAudioBackend.resolvedMirrorURL
        if !base.hasSuffix("/") { base += "/" }
        guard let url = URL(string: base + "canary-1b-v2-coreml.tar.gz") else {
            throw NSError(domain: "CanaryBackend", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Bad mirror URL"])
        }
        print("[Canary] Downloading model bundle: \(url.absoluteString)")
        let (tmp, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "CanaryBackend", code: -3, userInfo: [
                NSLocalizedDescriptionKey:
                    "Canary bundle download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)) — is canary-1b-v2-coreml.tar.gz uploaded to the mirror root?"
            ])
        }

        try FileManager.default.createDirectory(at: fluidAudioDir, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = ["-xzf", tmp.path, "-C", fluidAudioDir.path]
        try proc.run()
        proc.waitUntilExit()
        let stillMissing = requiredFiles.filter {
            !FileManager.default.fileExists(atPath: repoDir.appendingPathComponent($0).path)
        }
        guard proc.terminationStatus == 0, stillMissing.isEmpty else {
            throw NSError(domain: "CanaryBackend", code: -4, userInfo: [
                NSLocalizedDescriptionKey:
                    "Canary bundle extraction incomplete — tarball is missing: \(stillMissing.joined(separator: ", ")). Re-run stage_canary.py and re-upload."
            ])
        }
        print("[Canary] Model bundle extracted to \(repoDir.path)")
    }
}
