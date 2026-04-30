import Foundation
import AVFoundation

/// Tiny reference-typed wrapper around `Data` so it can be mutated by closures captured
/// across multiple readability-handler invocations. Used to accumulate raw bytes from
/// ffmpeg's stdout pipe across calls and only emit complete Float32 samples downstream.
private final class MutableByteBuffer {
    var bytes = Data()
}

/// Reference-typed counters for audio delivery rate logging. The
/// `readabilityHandler` closures run on Foundation's background queue and
/// share no actor context, so we use a class with an `NSLock` rather than
/// actor-isolated state. Cheap: lock contention is sub-microsecond and the
/// handler fires at most ~100x/sec.
///
/// Tracks total bytes received from ffmpeg over the whole process lifetime,
/// plus the snapshot at the last log emission so we can compute a rolling
/// "bytes/sec since last log" without keeping a sliding window.
private final class AudioRateStats {
    let lock = NSLock()
    var totalBytes: Int = 0
    var bytesAtLastLog: Int = 0
    var lastLogAt: Date = Date()
}

/// Pulls audio from a remote URL (YouTube, HLS, or direct file) and emits 16 kHz mono Float32 PCM.
///
/// Strategy:
/// - YouTube  → resolve a streaming audio URL via `yt-dlp` (must be installed), then pipe through ffmpeg.
/// - HLS      → use ffmpeg directly (handles `.m3u8` better than AVFoundation for arbitrary streams).
/// - Direct   → ffmpeg as well, for uniform PCM output.
///
/// We shell out to ffmpeg because it normalizes everything to 16 kHz mono Float32 — exactly what
/// WhisperKit expects. The samples are streamed back via an AsyncStream so the consumer can
/// chunk them however it wants.
actor AudioStreamExtractor {

    enum ExtractorError: LocalizedError {
        case ytDlpMissing
        case ffmpegMissing
        /// yt-dlp couldn't resolve the URL. The first associated value is the
        /// source label ("YouTube", "Twitter / X") for user-facing messages; the
        /// second is the underlying error text from yt-dlp's stderr.
        case ytDlpResolutionFailed(String, String)
        case processFailed(Int32, String)
        case invalidURL

        var errorDescription: String? {
            switch self {
            case .ytDlpMissing:
                return "yt-dlp could not be downloaded. Check your network connection and try again."
            case .ffmpegMissing:
                return "ffmpeg binary missing from app bundle. The build is incomplete — see SETUP.md for how to add it to Resources."
            case .ytDlpResolutionFailed(let label, let msg):
                return "Could not resolve \(label) audio: \(msg)"
            case .processFailed(let code, let msg):
                return "Audio process failed (\(code)): \(msg)"
            case .invalidURL:
                return "Invalid URL"
            }
        }
    }

    static let sampleRate: Double = 16_000

    /// Bytes-per-second of audio at the realtime rate. Used by the audio
    /// delivery-rate logging to compute "realtime multiple" — total bytes
    /// received divided by elapsed wall-clock divided by this gives us
    /// "audio seconds delivered per second of wall-clock." 1.0× means
    /// realtime, >1× means downloading-faster-than-realtime (typical for
    /// VOD), <1× means upstream is throttling.
    ///
    /// 16000 Hz × 4 bytes/sample (Float32) × 1 channel = 64000 bytes/sec.
    static let bytesPerSecondRealtime: Int = Int(sampleRate) * 4

    private var ffmpegProcess: Process?
    private var stderrPipe: Pipe?
    private var continuation: AsyncStream<[Float]>.Continuation?

    /// When the extractor takes the download-then-decode path (yt-dlp static
    /// VOD mode), this points at the temporary file yt-dlp wrote. Stored on
    /// the actor so `stop()` can delete it on session teardown.
    ///
    /// nil when the extractor is on the stream-through-ffmpeg path (live
    /// mode, local files, direct HTTP audio).
    private var tempDownloadedFile: URL?

    /// When the download-then-decode path is in flight, this is the yt-dlp
    /// process doing the actual download. We track it separately from
    /// `ffmpegProcess` because the two phases are sequential: yt-dlp runs to
    /// completion, then ffmpeg processes the resulting file. Both need to be
    /// killable by `stop()` since either may be in flight at teardown.
    private var ytDlpDownloadProcess: Process?

    /// When the live-pipe path is in flight, this is the yt-dlp process
    /// streaming its container output to ffmpeg's stdin via a Pipe. Unlike
    /// `ytDlpDownloadProcess`, this one runs concurrently with ffmpeg for the
    /// entire session — they're a pair, both killed together on `stop()`.
    /// Kept distinct from the download tracker so the two lifecycles don't
    /// get tangled (a stale download-tracker pointer would never matter
    /// here, but separation makes the code easier to reason about).
    private var ytDlpStreamProcess: Process?

    /// Accumulated stderr output from the live-pipe yt-dlp process. Used
    /// by the retry logic in `streamViaYTDlpPipe` to detect the known
    /// `--live-from-start` failure pattern ("No video formats found") so
    /// we can retry without that flag. Cleared on `stop()` and between
    /// retry attempts.
    private var ytDlpStreamStderr: MutableByteBuffer?

    /// Callback used to report download progress to the engine during the
    /// pre-decode yt-dlp phase. The engine wires this to its preparing-state
    /// status text so the user sees "Downloading audio (47%)…" instead of an
    /// opaque hang. Nil when not on the download path or no callback was
    /// supplied.
    ///
    /// Invoked off the actor (on whichever queue parses yt-dlp stderr), so
    /// the callback itself must be Sendable + safe to call from any thread —
    /// typically a closure that hops to MainActor.
    private var downloadProgressCallback: (@Sendable (Double, String) -> Void)?

    /// Captured from `start(...)` so the various dispatch paths
    /// (`downloadViaYTDlp`, `streamViaYTDlpPipe`, direct-URL resolution)
    /// can read it without each carrying a parameter through. Decides:
    ///   - yt-dlp's `-f` selector: `best[height<=480]/...` (with video)
    ///     vs `bestaudio/best` (audio-only).
    ///   - ffmpeg's cache output: include `-map 0:v? -c:v copy` (video)
    ///     vs omit those (audio-only mp4).
    /// Defaults to `true` for backward compatibility with callers that
    /// don't set it.
    private var wantsVideoInCacheFlag: Bool = true

    /// Begin extracting audio. Returns a stream of Float32 PCM frame arrays at 16 kHz mono.
    ///
    /// `useFastDownload`: when true AND the source requires yt-dlp resolution,
    /// the extractor downloads the entire audio to a temp file first (with
    /// yt-dlp's parallelism flags enabled), then runs ffmpeg on the local
    /// file. This is the fast path for static-mode VOD URLs — bypasses the
    /// per-connection CDN throttling that limits direct streaming to ~0.5x
    /// realtime. When false (or the source doesn't need yt-dlp), behavior is
    /// the original stream-through-ffmpeg flow.
    ///
    /// `progressCallback`: optional, called from the download path with
    /// (fraction 0...1, human-readable status string) as yt-dlp progresses.
    /// Engine wires this to the preparing-state UI so the user sees progress.
    func start(
        url: URL,
        source: StreamSource,
        useFastDownload: Bool = false,
        progressCallback: (@Sendable (Double, String) -> Void)? = nil,
        cacheOutputPath: String? = nil,
        wantsVideoInCache: Bool = true
    ) async throws -> AsyncStream<[Float]> {
        // Resolve ffmpeg path once up-front; cleaner error path if missing.
        let ffmpeg = try Self.requireFFmpegPath()

        // Cache the progress callback so `downloadViaYTDlp` (which runs as
        // a private method on the actor) can find it without threading it
        // through every parameter.
        self.downloadProgressCallback = progressCallback
        self.wantsVideoInCacheFlag = wantsVideoInCache

        let inputURL: String
        let inputIsLocalFile: Bool
        // When the live-pipe path is chosen, we set up a yt-dlp process
        // writing its container output to stdout, captured into this Pipe,
        // and pass the Pipe to spawnFFmpeg so ffmpeg reads from stdin. The
        // alternative paths (download-to-file, resolve-to-direct-URL,
        // local-file, direct-network-URL) leave this nil and spawnFFmpeg
        // takes the URL/path code path.
        var ytDlpStdinPipe: Pipe? = nil

        // Pivot on whether the source needs yt-dlp resolution rather than enumerating
        // every case explicitly — keeps the extractor decoupled from the StreamSource
        // case list, so adding a new yt-dlp-supported site (Apple Podcasts, SoundCloud,
        // future ones) is a one-line change in StreamSource.swift.
        if source.requiresYTDlp {
            if useFastDownload {
                // Static-mode VOD path: download to a temp file with
                // parallelism flags, then process the local file. The
                // download phase is where the big speedup happens — see
                // `downloadViaYTDlp` for the flag set.
                print("[Extractor] Static-mode fast download via yt-dlp (parallel)…")
                let downloaded = try await downloadViaYTDlp(url, source: source, ffmpegPath: ffmpeg)
                self.tempDownloadedFile = downloaded
                inputURL = downloaded.path
                inputIsLocalFile = true
                print("[Extractor] Download complete: \(downloaded.lastPathComponent)")
            } else {
                // Live-mode path: pipe yt-dlp's stdout directly into ffmpeg's
                // stdin, with yt-dlp running with `-N 8` for concurrent
                // fragment fetch. For genuine live streams this beats the
                // per-connection CDN throttling on the catch-up window
                // (segments already in the DVR window can be pulled in
                // parallel; the live edge still arrives at 1× realtime by
                // definition). For VOD-misclassified-as-Live (probe failed
                // to determine duration), this gets the same speedup as the
                // static-mode fast-download path without the up-front wait.
                //
                // Strict architectural improvement over the previous "resolve
                // to direct URL, ffmpeg streams from it" path — yt-dlp's HLS
                // handler is segment-aware and reorders fragments before
                // emitting them on stdout, so we get parallel pulls without
                // breaking the sequential-audio guarantee ffmpeg expects.
                print("[Extractor] Live-mode pipe via yt-dlp (parallel fragments)…")
                let pipe = try await streamViaYTDlpPipe(url, source: source, ffmpegPath: ffmpeg)
                ytDlpStdinPipe = pipe
                inputURL = "-"
                inputIsLocalFile = false
            }
        } else if source == .localFile {
            inputURL = url.path
            inputIsLocalFile = true
            print("[Extractor] Local file: \(inputURL)")
        } else {
            // .hls, .directAudio — fetch directly with ffmpeg, no extractor
            // middleware. (`.unknown` used to land here as a best-effort
            // fallback but now routes through yt-dlp's generic extractor so
            // arbitrary HTML pages with embedded HLS — Senate hearings,
            // many news sites, podcast directory pages — work without us
            // needing site-specific scrapers.)
            inputURL = url.absoluteString
            inputIsLocalFile = false
            print("[Extractor] Direct URL: \(inputURL)")
        }

        let stream = AsyncStream<[Float]> { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                print("[Extractor] AsyncStream terminated.")
                Task { await self?.stop() }
            }

            do {
                try self.spawnFFmpeg(
                    ffmpegPath: ffmpeg,
                    inputURL: inputURL,
                    // Under fast-download, ffmpeg's actual input is a local
                    // temp file even though `source` is YouTube/Twitter. The
                    // `-reconnect*` flags only apply to network inputs and
                    // some ffmpeg builds error on them for file:// inputs.
                    // `inputIsLocalFile` captures this correctly across both
                    // the static-VOD-fast-download path and the
                    // user-supplied-local-file path.
                    isNetworkInput: !inputIsLocalFile,
                    stdinPipe: ytDlpStdinPipe,
                    cacheOutputPath: cacheOutputPath,
                    continuation: continuation
                )
                print("[Extractor] ffmpeg process spawned.")
            } catch {
                print("[Extractor] Failed to spawn ffmpeg: \(error)")
                continuation.finish()
            }
        }

        return stream
    }

    func stop() {
        if let p = ffmpegProcess, p.isRunning {
            p.terminate()
        }
        ffmpegProcess = nil

        // Kill the yt-dlp download if it's still in flight (user hit stop
        // during the pre-decode download phase). Terminating yt-dlp will
        // leave a partial file at `tempDownloadedFile` which we remove
        // below.
        if let p = ytDlpDownloadProcess, p.isRunning {
            p.terminate()
        }
        ytDlpDownloadProcess = nil

        // Kill the yt-dlp stream if it's running. For the live-pipe path
        // yt-dlp is a long-running peer of ffmpeg; both need to die together.
        if let p = ytDlpStreamProcess, p.isRunning {
            p.terminate()
        }
        ytDlpStreamProcess = nil
        ytDlpStreamStderr = nil

        // Best-effort delete of the temp downloaded file. The file lives
        // under NSTemporaryDirectory so the OS will eventually reclaim it
        // anyway, but explicit cleanup avoids accumulating ~50MB-per-session
        // turds in /tmp across heavy use.
        if let tempFile = tempDownloadedFile {
            try? FileManager.default.removeItem(at: tempFile)
            tempDownloadedFile = nil
        }

        downloadProgressCallback = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - FFmpeg wiring

    private func spawnFFmpeg(
        ffmpegPath: String,
        inputURL: String,
        isNetworkInput: Bool,
        stdinPipe: Pipe? = nil,
        cacheOutputPath: String? = nil,
        continuation: AsyncStream<[Float]>.Continuation
    ) throws {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: ffmpegPath)

        // Build argument list. Three input modes change which flags apply:
        //
        //   - Network input (HTTP/HTTPS URL): include `-reconnect*` family so
        //     transient drops don't kill the stream. Keep `-nostdin` so ffmpeg
        //     doesn't try to read from our process's stdin (which is the
        //     terminal/launcher stdin, not anything we control).
        //   - Local file input: omit reconnect flags (some ffmpeg builds
        //     reject them on file:// URLs). Keep `-nostdin`.
        //   - Stdin input (`stdinPipe != nil`): drop `-nostdin` (we WANT
        //     stdin), drop `-reconnect*` (not applicable), and rewrite the
        //     `-i` value to `-`. Used by the live-mode yt-dlp pipe path —
        //     yt-dlp writes the container stream to its stdout, which is
        //     hooked up to ffmpeg's stdin via the supplied Pipe.
        //
        // **Cache output.** When `cacheOutputPath` is non-nil we add a
        // SECOND output to the same ffmpeg invocation: video+audio
        // copied (no re-encode) into a fragmented MP4 container. This is
        // the miniplayer cache. Using a single ffmpeg with two outputs is
        // strictly better than two parallel ffmpegs because the input
        // is decoded once and demuxed once — zero extra CPU, zero extra
        // network bandwidth. MP4 is chosen over Matroska because
        // AVPlayer (the miniplayer's backbone) supports mp4 natively on
        // macOS while Matroska needs third-party components. The
        // fragmented-MP4 flags below ensure the file stays playable
        // even if ffmpeg is killed mid-stream. Local-file mode skips
        // the cache output (the original file is already playable).
        let useStdin = stdinPipe != nil
        var args: [String] = []
        if !useStdin {
            args.append(contentsOf: ["-nostdin", "-loglevel", "warning"])
        } else {
            args.append(contentsOf: ["-loglevel", "warning"])
        }
        if isNetworkInput && !useStdin {
            args.append(contentsOf: [
                "-reconnect", "1",
                "-reconnect_streamed", "1",
                "-reconnect_delay_max", "5",
            ])
        }
        args.append(contentsOf: [
            "-i", useStdin ? "-" : inputURL,
        ])
        // First output: 16 kHz mono PCM on stdout, for the transcription
        // engine. Mapping is implicit (ffmpeg picks audio stream 0 by
        // default when `-vn` is in effect or no `-map` is given), but
        // when a second output asks for video too, we need an explicit
        // `-map 0:a:0` to make sure THIS output stays audio-only.
        let outputsHaveVideo = cacheOutputPath != nil
        if outputsHaveVideo {
            args.append(contentsOf: ["-map", "0:a:0"])
        } else {
            args.append("-vn")  // drop video for audio-only ffmpeg invocations
        }
        args.append(contentsOf: [
            "-ac", "1",                               // mono
            "-ar", String(Int(Self.sampleRate)),      // 16 kHz
            "-f", "f32le",                            // raw 32-bit float little-endian
            "-acodec", "pcm_f32le",
            "-",                                       // pipe to stdout
        ])
        // Second output: audio re-encoded to AAC + (optionally) video
        // stream-copied, into a fragmented MP4 container.
        //
        // **Audio re-encode** (`-c:a aac -b:a 128k`). mp4 muxing of
        // stream-copied AAC is fragile: many YouTube/HLS sources
        // deliver AAC frames that lack the codec-private-data
        // (`ESDS`/`DecoderSpecificInfo`) AVFoundation needs to play
        // the resulting file. Bitstream filters like `aac_adtstoasc`
        // fix some cases but not all; re-encoding eliminates the
        // entire class of problem. CPU cost is minor (~5-10% of one
        // core, briefly) and 128 kbps AAC is fine for speaker-ID
        // purposes.
        //
        // **Video** depends on `wantsVideoInCacheFlag` (from the user's
        // miniplayer-cache preference, set in Settings). When true,
        // we `-c:v copy` the original video — no re-encode cost, full
        // visual quality preserved for speaker identification. When
        // false, we omit the video map entirely; the result is an
        // audio-only mp4 (still plays in the miniplayer as audio
        // only), and we never asked yt-dlp for video in the first
        // place so this just keeps the ffmpeg args consistent.
        //
        // `-movflags +faststart+frag_keyframe+empty_moov` produces a
        // FRAGMENTED mp4. Why fragmented: a normal mp4's moov atom
        // (index/metadata) is written at the END of the file, which
        // requires ffmpeg to seek back to the start when finalizing.
        // If ffmpeg is killed mid-stream (cancellation path), the
        // moov atom never gets written and the file is unplayable.
        // Fragmented mp4 writes the moov at the START with empty
        // tracks, then appends self-contained "moof" fragments as
        // data arrives — the file is playable from any point, even
        // if writing was interrupted.
        if let cachePath = cacheOutputPath {
            var cacheArgs: [String] = []
            if wantsVideoInCacheFlag {
                cacheArgs.append(contentsOf: ["-map", "0:v?"])
            }
            cacheArgs.append(contentsOf: [
                "-map", "0:a:0",
            ])
            if wantsVideoInCacheFlag {
                cacheArgs.append(contentsOf: ["-c:v", "copy"])
            }
            cacheArgs.append(contentsOf: [
                "-c:a", "aac",
                "-b:a", "128k",
                "-f", "mp4",
                "-movflags", "+faststart+frag_keyframe+empty_moov",
                "-y",
                cachePath,
            ])
            args.append(contentsOf: cacheArgs)
        }
        process.arguments = args
        process.standardOutput = outPipe
        process.standardError = errPipe
        if let stdinPipe {
            process.standardInput = stdinPipe
        }

        // ffmpeg writes Float32 little-endian PCM. The pipe doesn't preserve frame
        // boundaries — `availableData` may return any number of bytes, including ones
        // that don't divide evenly into 4-byte float boundaries. We buffer leftovers
        // across reads so floats are never split. Without this, every fourth float
        // ends up with bytes from two consecutive samples and the audio becomes noise.
        //
        // The class is a Swift class wrapper around a Data buffer so the closure can
        // mutate it across calls. Using a plain `var` captured by the closure works
        // too, but the class makes the intent (shared mutable state) explicit.
        let pendingBytes = MutableByteBuffer()

        // Audio delivery rate instrumentation. ffmpeg's `readabilityHandler`
        // fires whenever the OS has bytes buffered for us to read; the rate
        // at which those bytes arrive tells us whether the bottleneck is
        // upstream (network/server throttling, ffmpeg pacing) vs downstream
        // (consumer not pulling fast enough → ffmpeg blocks on pipe write).
        //
        // Tracked across the entire ffmpeg process lifetime. Logged every
        // ~5s of wall-clock. Sample rate is 16000 Hz × 4 bytes/sample =
        // 64000 bytes/sec for 1× realtime — we compute and report a
        // realtime-multiple so the meaning is obvious in the log. A steady
        // 1.0× means audio is arriving at exactly realtime (typical for
        // live streams); >>1× means VOD downloading as fast as the network
        // allows; <1× means something is throttling supply.
        //
        // Implementation detail: actor-isolated counters would be cleaner,
        // but `readabilityHandler` runs on a Foundation background queue
        // and the closures don't have actor context. Using simple locked
        // counters keeps the logging cheap.
        let rateStats = AudioRateStats()
        rateStats.lastLogAt = Date()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }

            // Rate stats: count bytes delivered, periodically log the
            // realtime-multiple. We log inside the readability handler so
            // the cadence is driven by actual ffmpeg output activity (no
            // periodic log if ffmpeg is silent — which is itself useful
            // signal).
            rateStats.lock.lock()
            rateStats.totalBytes += data.count
            let now = Date()
            let sinceLastLog = now.timeIntervalSince(rateStats.lastLogAt)
            let shouldLog = sinceLastLog >= 5.0
            var totalForLog: Int = 0
            var bytesSinceLastLog: Int = 0
            if shouldLog {
                totalForLog = rateStats.totalBytes
                bytesSinceLastLog = rateStats.totalBytes - rateStats.bytesAtLastLog
                rateStats.bytesAtLastLog = rateStats.totalBytes
                rateStats.lastLogAt = now
            }
            rateStats.lock.unlock()

            if shouldLog {
                let secondsOfAudio = Double(bytesSinceLastLog) / Double(Self.bytesPerSecondRealtime)
                let realtimeRatio = secondsOfAudio / sinceLastLog
                let totalSeconds = Double(totalForLog) / Double(Self.bytesPerSecondRealtime)
                print(String(format: "[Extractor] Audio rate: %.2fx realtime over last %.1fs (%.1fs audio / %.1fs wall). Total: %.1fs audio delivered.",
                             realtimeRatio, sinceLastLog, secondsOfAudio, sinceLastLog, totalSeconds))
            }

            pendingBytes.bytes.append(data)

            // Extract as many whole-Float32 samples as we can; keep any remainder.
            let totalBytes = pendingBytes.bytes.count
            let alignedBytes = totalBytes - (totalBytes % 4)
            guard alignedBytes > 0 else { return }

            let aligned = pendingBytes.bytes.prefix(alignedBytes)
            let floats = aligned.withUnsafeBytes { raw -> [Float] in
                let buf = raw.bindMemory(to: Float.self)
                return Array(buf)
            }
            pendingBytes.bytes.removeSubrange(0..<alignedBytes)
            continuation.yield(floats)
        }

        // Drain stderr so the buffer doesn't fill up; useful for debugging.
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let line = String(data: data, encoding: .utf8) {
                FileHandle.standardError.write(("[ffmpeg] " + line).data(using: .utf8) ?? Data())
            }
        }

        process.terminationHandler = { proc in
            print("[Extractor] ffmpeg exited with code \(proc.terminationStatus)")

            // Drain any remaining buffered stdout before tearing down the readability
            // handler. Append it to the pending bytes so we can apply the same
            // alignment logic — handles small local files where ffmpeg may exit before
            // the readability handler has flushed everything.
            outPipe.fileHandleForReading.readabilityHandler = nil
            let remaining = outPipe.fileHandleForReading.readDataToEndOfFile()
            if !remaining.isEmpty {
                pendingBytes.bytes.append(remaining)
            }

            let totalBytes = pendingBytes.bytes.count
            let alignedBytes = totalBytes - (totalBytes % 4)
            if alignedBytes > 0 {
                let aligned = pendingBytes.bytes.prefix(alignedBytes)
                let floats = aligned.withUnsafeBytes { raw -> [Float] in
                    let buf = raw.bindMemory(to: Float.self)
                    return Array(buf)
                }
                print("[Extractor] Drained \(floats.count) trailing samples after exit.")
                continuation.yield(floats)
            }
            // Any final 1–3 trailing bytes are dropped — they can't form a sample.

            errPipe.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
        }

        try process.run()
        self.ffmpegProcess = process
        self.stderrPipe = errPipe
    }

    // MARK: - yt-dlp download (fast path)

    /// Download an audio-only file for a yt-dlp source to a temp location,
    /// using yt-dlp's built-in parallelism flags so we beat the per-connection
    /// throttling that limits direct streaming to ~0.5x realtime. Returns the
    /// URL of the downloaded file once complete.
    ///
    /// Used only on the static-mode VOD fast path. Live streams (genuine
    /// or VOD-misclassified) now go through `streamViaYTDlpPipe`, which
    /// runs yt-dlp as a long-running peer of ffmpeg with the same
    /// parallelism flags but piped through stdout. The old
    /// `resolveViaYTDlp` (resolve URL → ffmpeg streams directly from CDN)
    /// is kept in the file as dead code for reference but is no longer
    /// reached at runtime — it hit YouTube's per-connection throttling
    /// at ~0.4-0.5× realtime and there's no case where that's the right
    /// choice anymore.
    ///
    /// Parallelism strategy: yt-dlp tries multiple paths and we enable all of
    /// them. Whichever applies to the format yt-dlp selects is the one that
    /// kicks in:
    ///   - `-N 8` / `--concurrent-fragments 8`: parallel segment download for
    ///     fragmented formats (HLS/DASH). YouTube typically serves
    ///     fragmented audio on the m4a-DASH or webm-DASH formats. 8 fragments
    ///     concurrent is the common sweet spot — beyond ~16 some CDNs start
    ///     rate-limiting the parent IP rather than each connection.
    ///   - `--http-chunk-size 10M`: forces yt-dlp to use HTTP range requests
    ///     in 10MB chunks for non-fragmented downloads. This isn't true
    ///     parallelism but does work around some YouTube throttling that
    ///     applies per-request rather than per-connection.
    ///   - `--no-part`: write directly to the final file instead of *.part
    ///     and renaming on completion. We don't need crash-recovery semantics
    ///     for ephemeral temp files; this avoids one filesystem dance and
    ///     simplifies the cleanup path.
    ///
    /// Format selection: `-f bestaudio/best`, same as the streaming path.
    /// Reuses the same cookies-from-browser + Deno-runtime configuration so
    /// authenticated/age-gated/n-challenge content works the same.
    ///
    /// Progress reporting: parses yt-dlp's `--progress --newline` output for
    /// lines like `[download]  47.3% of ~ 32.45MiB at  4.21MiB/s ETA 00:08`
    /// and invokes `self.downloadProgressCallback` with (fraction, label).
    /// We don't gate on the callback being set — the parse runs regardless,
    /// and the conditional invocation is cheap when callback is nil.
    private func downloadViaYTDlp(_ url: URL, source: StreamSource, ffmpegPath: String) async throws -> URL {
        let tools = try await Self.resolveYTDlpTools()
        let sourceLabel = source.rawValue

        // Build the temp file path. We let yt-dlp decide the extension based
        // on the format it picks (m4a, webm, mp4, etc.) by passing a path
        // *without* extension and letting yt-dlp append one. `-o` template
        // syntax: `%(ext)s` substitutes the format's container extension.
        let tempDir = FileManager.default.temporaryDirectory
        let baseFilename = "streamscribe-yt-\(UUID().uuidString)"
        let outputTemplate = tempDir.appendingPathComponent("\(baseFilename).%(ext)s").path

        // Capture the progress callback locally so the readability handler
        // (which runs off-actor) can use it without crossing the actor
        // boundary on every progress line.
        let progressCb = self.downloadProgressCallback

        // We need to know the final filename after yt-dlp picks an
        // extension. `--print after_move:filepath` prints the post-rename
        // path to stdout on success.
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let process = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: tools.ytDlpPath)
            // Apply SSL_CERT_FILE override (if user-configured or
            // auto-detected) so yt-dlp's TLS stack trusts the user's
            // custom CA bundle. nil means "inherit parent env unchanged"
            // — the existing behavior when no override is set.
            if let env = tools.childEnvironment {
                process.environment = env
            }

            var args: [String] = []
            if let browserArg = tools.cookieBrowser.ytDlpArgument {
                args.append(contentsOf: ["--cookies-from-browser", browserArg])
            }
            // Optional: skip TLS certificate validation. The toggle in
            // the Tools sidebar surfaces this for users on corporate
            // networks that do TLS interception with a private root
            // certificate not in the system trust store. Default off
            // — weakening TLS validation is a real security tradeoff
            // and we want it to be an explicit user choice.
            if tools.disableTLSCheck {
                args.append("--no-check-certificate")
            }
            // Pass `--impersonate chrome` ONLY for sources that
            // benefit. Facebook + Instagram fingerprint TLS and
            // serve unparseable responses to plain yt-dlp; the
            // chrome impersonation bypasses that detection.
            //
            // **Why not always-on.** YouTube's bot detection is
            // sophisticated enough that the chrome TLS fingerprint
            // WITHOUT matching browser-realistic behavior (JS
            // engine, real session, timing) triggers HARDER
            // challenges than plain yt-dlp does — empirically
            // produces "Sign in to confirm you're not a bot"
            // errors that don't appear without it. So we gate
            // impersonation on a per-source benefits-list.
            if source.benefitsFromImpersonation {
                args.append(contentsOf: ["--impersonate", "chrome"])
            }
            if let denoPath = tools.denoPath {
                args.append(contentsOf: ["--js-runtimes", "deno:\(denoPath)"])
            }
            // Format selector chosen by the user's miniplayer-cache
            // preference. The selectors below are stacked in priority
            // order; yt-dlp tries each and picks the first that
            // resolves.
            //
            // **AVPlayer-compatible codec preference.** AVFoundation
            // (which our miniplayer wraps via AVPlayerView) decodes a
            // bounded set of codec+container combinations natively. It
            // doesn't decode WebM (VP8/VP9), MKV (mostly), or Opus
            // audio. yt-dlp's unconstrained "best" on YouTube very
            // often picks VP9 video + Opus audio merged into WebM —
            // unplayable in the miniplayer. To avoid this, the selector
            // prefers H.264 video (vcodec*=avc matches "avc1", "avc3")
            // and AAC audio (acodec*=mp4a) — the universally-decodable
            // combo — falling back step by step to less-constrained
            // options when the source doesn't offer H.264/AAC.
            //
            // **The fallback chain** (top to bottom):
            //   1. H.264 video ≤480p + AAC audio, merged
            //   2. Combined MP4 ≤480p (single-file H.264+AAC, no merge)
            //   3. Any combined ≤480p (may be WebM/MKV — last resort
            //      for video sources that don't offer MP4 at all)
            //   4. Any bestvideo+bestaudio merge
            //   5. Anything at all
            //
            // **--merge-output-format mp4** forces the merged container
            // to MP4 when yt-dlp combines separate streams. Without
            // this, yt-dlp picks the container based on the input
            // codecs — VP9+Opus default to WebM, which then needs
            // re-muxing (or worse, gets shipped unplayable). With this
            // flag and the H.264/AAC preference above, the merge can
            // always produce playable MP4.
            //
            // For audio-only (wantsVideo=false), prefer AAC similarly.
            // YouTube's "bestaudio" without constraint is usually Opus
            // in WebM (acodec=opus), unplayable in the miniplayer.
            // m4a/AAC is the safe fallback every major source offers.
            let formatSelector = wantsVideoInCacheFlag
                ? "bestvideo[height<=480][vcodec*=avc]+bestaudio[acodec*=mp4a]/best[height<=480][ext=mp4]/best[height<=480]/bestvideo+bestaudio/best"
                : "bestaudio[acodec*=mp4a]/bestaudio[ext=m4a]/bestaudio/best"
            args.append(contentsOf: [
                "-f", formatSelector,
                "--merge-output-format", "mp4",     // force MP4 container on merge
                "-N", "8",                          // parallel fragments where applicable
                "--http-chunk-size", "10M",         // range-request chunking for non-fragmented
                "--no-part",                        // skip .part tempfile dance
                "--progress",                       // emit progress lines on stderr
                "--newline",                        // one progress line per update, not \r overwrites
                // **`--ffmpeg-location`**: critical for sources that
                // serve separate audio+video streams (e.g. Fox News
                // HLS, many news sites). When yt-dlp picks
                // `bestvideo+bestaudio` from the format selector,
                // it downloads both streams separately and then
                // needs ffmpeg to merge them into the final file.
                // Without this flag, yt-dlp searches `$PATH` for
                // ffmpeg — which DOESN'T include the location of
                // our bundled binary — and silently skips the
                // merge with a WARNING. The download completes (exit 0)
                // but the templated output path doesn't exist;
                // instead two intermediate files are left in the
                // temp dir with extensions like `.fhls-557.mp4` and
                // `.fhls-audio-0-en__Main_.mp4`. The fix is to
                // explicitly tell yt-dlp where our bundled ffmpeg
                // lives. (Mirrors what the live-pipe path already
                // does.)
                "--ffmpeg-location", ffmpegPath,
                // Note: previously had `--no-warnings` here. Removed
                // because warnings are often the ONLY indication of
                // post-process failures, format-merge issues, or
                // extractor-specific quirks (e.g. Fox News serving
                // formats whose container doesn't match the
                // `%(ext)s` template). Suppressing them turned
                // diagnostic failures into silent ones.
                "-o", outputTemplate,
                "--print", "after_move:filepath",   // emit final filepath after download
                url.absoluteString
            ])
            process.arguments = args

            let printableArgs = args.map { arg -> String in
                if let u = URL(string: arg), u.scheme != nil {
                    return "\(u.scheme ?? "")://\(u.host ?? "")\(u.path)"
                }
                return arg
            }.joined(separator: " ")
            print("[yt-dlp] Invoking (download): yt-dlp \(printableArgs)")

            process.standardOutput = outPipe
            process.standardError = errPipe

            // Parse progress lines off-thread. yt-dlp's `--progress --newline`
            // emits one progress line per update; format is roughly:
            //   [download]  12.3% of ~ 15.42MiB at 3.21MiB/s ETA 00:08
            //   [download]  100% of 15.42MiB in 00:05
            // We extract the percentage with a tolerant regex (the surrounding
            // text varies between yt-dlp versions and download paths) and
            // forward it to the engine for status display. Anything that
            // doesn't parse just gets logged.
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                // yt-dlp may emit several lines per readability event.
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                    // Match `[download]  NN.N%` or `[download]  NNN%`
                    if trimmed.hasPrefix("[download]") {
                        // Find the first "%" and walk backwards over digits/.
                        if let pctIdx = trimmed.firstIndex(of: "%") {
                            var i = pctIdx
                            while i > trimmed.startIndex {
                                let prev = trimmed.index(before: i)
                                let c = trimmed[prev]
                                if c.isNumber || c == "." { i = prev } else { break }
                            }
                            if i < pctIdx {
                                let pctStr = String(trimmed[i..<pctIdx])
                                if let pct = Double(pctStr), pct >= 0, pct <= 100 {
                                    progressCb?(pct / 100.0, trimmed)
                                    continue
                                }
                            }
                        }
                    }
                    // Anything else (warnings, errors) → just log.
                    print("[yt-dlp stderr] \(trimmed)")
                }
            }

            process.terminationHandler = { [weak self] proc in
                errPipe.fileHandleForReading.readabilityHandler = nil

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: outData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                // Clear the actor-tracked process pointer on completion. Done
                // via a Task→actor hop because terminationHandler runs on a
                // background queue and we can't synchronously mutate actor
                // state from there.
                Task { [weak self] in
                    await self?.clearYTDlpDownloadProcess()
                }

                if proc.terminationStatus != 0 {
                    cont.resume(throwing: ExtractorError.ytDlpResolutionFailed(
                        sourceLabel,
                        "yt-dlp download exited with \(proc.terminationStatus)"
                    ))
                    return
                }

                // Always log what yt-dlp wrote to stdout — it's the
                // post-success `--print` output. Helps diagnose "yt-dlp
                // says success but the file isn't where we thought"
                // cases (Fox News and other generic-extractor sites
                // sometimes pick formats whose container differs from
                // what `%(ext)s` resolves to, or run a post-process
                // that moves the file after `after_move:filepath`
                // fires).
                if !out.isEmpty {
                    for line in out.split(separator: "\n") {
                        print("[yt-dlp stdout] \(line)")
                    }
                }

                // `after_move:filepath` is the last --print line emitted; if
                // multiple --print lines exist take the last. yt-dlp prints
                // this to stdout in addition to its progress lines on stderr.
                let lastLine = out.split(separator: "\n").map(String.init).last ?? out
                let finalPath = lastLine.trimmingCharacters(in: .whitespaces)

                // **Primary path.** Trust yt-dlp's reported path when
                // the file is actually there.
                if !finalPath.isEmpty,
                   FileManager.default.fileExists(atPath: finalPath) {
                    cont.resume(returning: URL(fileURLWithPath: finalPath))
                    return
                }

                // **Fallback.** yt-dlp claimed a path but the file
                // isn't there (or didn't claim one at all). Scan the
                // temp dir for any file matching our UUID base —
                // sometimes yt-dlp's post-processor lands the file
                // at a different extension than what
                // `after_move:filepath` reported (typical with
                // generic-extractor sites where the muxer changes
                // the container).
                let tempDirURL = FileManager.default.temporaryDirectory
                let matches: [String] = {
                    guard let names = try? FileManager.default
                        .contentsOfDirectory(atPath: tempDirURL.path) else { return [] }
                    return names.filter { $0.hasPrefix(baseFilename) }
                }()

                if matches.count == 1 {
                    let resolved = tempDirURL.appendingPathComponent(matches[0])
                    print("[Extractor] yt-dlp reported '\(finalPath)' but file is at '\(resolved.path)'; using fallback path.")
                    cont.resume(returning: resolved)
                    return
                }

                // Couldn't find a usable file. Include diagnostic
                // detail in the error: what yt-dlp claimed, what we
                // found in temp dir, and a sample of the captured
                // stdout (truncated if huge).
                let stdoutPreview: String = {
                    let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { return "<empty>" }
                    if trimmed.count <= 500 { return trimmed }
                    return String(trimmed.prefix(500)) + "… (truncated)"
                }()
                let matchSummary = matches.isEmpty
                    ? "no matching files in temp dir"
                    : "found \(matches.count) candidate(s): \(matches.joined(separator: ", "))"
                cont.resume(throwing: ExtractorError.ytDlpResolutionFailed(
                    sourceLabel,
                    "yt-dlp finished (exit 0) but no output file is on disk. Reported path: \(finalPath.isEmpty ? "<none>" : finalPath). Temp dir scan: \(matchSummary). yt-dlp stdout: \(stdoutPreview)"
                ))
            }

            do {
                try process.run()
                // Track the process so stop() can kill it mid-download.
                // Direct assignment is OK here — we're already inside the
                // actor's `start()` method when this closure ran, and
                // `withCheckedThrowingContinuation` doesn't introduce a
                // thread hop.
                self.ytDlpDownloadProcess = process
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    /// Helper called from `downloadViaYTDlp`'s terminationHandler to clear
    /// the actor-tracked process pointer once the download finishes. Needs
    /// to be an actor method because terminationHandler runs off-actor.
    private func clearYTDlpDownloadProcess() {
        self.ytDlpDownloadProcess = nil
    }

    // MARK: - yt-dlp live pipe (fast streaming path)

    /// Spawn yt-dlp with parallelism flags writing its container output to
    /// stdout, captured into a `Pipe` that the caller hooks up to ffmpeg's
    /// stdin. Returns the Pipe; yt-dlp continues running in the background
    /// for the entire session and is tracked on the actor as
    /// `ytDlpStreamProcess` so `stop()` can kill it.
    ///
    /// Why this path exists: the previous live-mode flow (resolve URL via
    /// yt-dlp, hand it to ffmpeg, let ffmpeg connect directly) hits
    /// YouTube's per-connection CDN throttling at ~0.4-0.5× realtime.
    /// Concretely, on a 90-minute hearing video the pipeline fell ~1:00
    /// behind per minute of audio. The piped path lets yt-dlp's HLS handler
    /// do the actual fetching with `-N 8` (concurrent fragments), which
    /// beats per-connection throttling on at least the fragmented-DASH
    /// formats YouTube serves for live and former-live URLs.
    ///
    /// For genuine live streams, the speedup applies to the catch-up
    /// window (DVR segments already published); once we hit the live edge,
    /// segments only appear at 1× realtime by definition. For
    /// VOD-misclassified-as-Live (probe couldn't determine duration), this
    /// gets us the same speedup as the static-mode fast-download path.
    ///
    /// What we explicitly DON'T do: try to parse a download percentage or
    /// emit progress callbacks. For live streams there's no fixed 100% to
    /// progress toward; for VOD-as-Live yt-dlp doesn't know the duration
    /// either. yt-dlp's stderr is logged verbatim for debug.
    ///
    /// Flag setup mirrors `downloadViaYTDlp` (same cookies, Deno, format
    /// selection, parallelism knobs) so what works in static mode keeps
    /// working here.
    ///
    /// True-live HLS specifics: YouTube serves genuine live broadcasts as
    /// HLS (e.g. format 95 for audio). When yt-dlp downloads HLS to stdout
    /// it can't use its native HLS downloader — that path writes to a file
    /// and uses the .ts → mp4 remux flow which doesn't work mid-stream.
    /// Instead yt-dlp invokes ffmpeg as a sub-downloader to do the actual
    /// pulling, and ffmpeg writes a streamable container to stdout that our
    /// own consumer-side ffmpeg can demux. This needs three extra flags
    /// beyond the VOD-as-Live case:
    ///   - `--ffmpeg-location` so yt-dlp's child process can find the
    ///     bundled ffmpeg. The app's child processes inherit a sparse env
    ///     (no shell PATH additions on macOS), so without this yt-dlp will
    ///     log "m3u8 download detected but ffmpeg could not be found" on
    ///     stderr and exit with code 1. That's the only thing that fails
    ///     for true-live where VOD-as-Live succeeds, because non-fragmented
    ///     audio containers (DASH m4a/webm) can be streamed to stdout via
    ///     yt-dlp's native HTTP downloader without ffmpeg in the loop.
    ///   - `--hls-use-mpegts` so the container ffmpeg writes to stdout is
    ///     mpegts (streamable: no moov atom at end, frame-aligned, ffmpeg
    ///     can start consuming bytes immediately). Default-on for live
    ///     downloads to a file but explicit is safer for the stdout path.
    ///   - `--live-from-start` is intentionally NOT included despite the
    ///     user preference for from-start replay. yt-dlp has a known bug
    ///     (issues #16497, #16673, #15274) where `--live-from-start`
    ///     causes "No video formats found!" on YouTube live streams. The
    ///     bug is present in all stable and nightly builds as of May 2026.
    ///     Without it, yt-dlp follows the live edge — transcription starts
    ///     from "now" rather than the broadcast's beginning. When the
    ///     upstream fix ships, add `--live-from-start` back to the args.
    /// The two active flags are no-ops on the VOD-as-Live case: there's
    /// no HLS sub-downloader (VOD audio is non-fragmented) and
    /// `--hls-use-mpegts` only applies to HLS. So adding them doesn't
    /// regress the working path.
    ///
    /// **Retry strategy for `--live-from-start`:** yt-dlp has a known bug
    /// (yt-dlp/yt-dlp#16497, #16673, #15274) where `--live-from-start`
    /// combined with cookies causes "No video formats found!" on YouTube
    /// live streams. The bug is present in all builds as of May 2026 and
    /// hasn't been fixed upstream. Rather than unconditionally dropping
    /// the flag (which loses DVR replay), we try the aggressive strategy
    /// first (with `--live-from-start` and cookies) and detect failure:
    /// yt-dlp exits with a non-zero code and the specific error on stderr.
    /// On that pattern, we tear down and retry without `--live-from-start`
    /// and without cookies, which follows the live edge and works reliably.
    ///
    /// The failure timing is not "fast": cookie extraction from Firefox
    /// triggers a macOS Keychain prompt that can take 5-7s, then yt-dlp
    /// downloads the YouTube webpage (~1s) and the player API JSON (~1s),
    /// THEN it errors. Total to-failure is ~10-12s. Our wait timeout has
    /// to comfortably exceed that or we'll treat the slow-failing case as
    /// success and never trigger the retry. 20s is the budget — if yt-dlp
    /// is still running at 20s it's actively streaming HLS fragments and
    /// is genuinely working.
    private func streamViaYTDlpPipe(_ url: URL, source: StreamSource, ffmpegPath: String) async throws -> Pipe {
        let sourceLabel = source.rawValue
        let tools = try await Self.resolveYTDlpTools()
        let hasCookies = tools.cookieBrowser.ytDlpArgument != nil

        // First attempt: --live-from-start with cookies (if configured).
        // This gives the best result (DVR replay from broadcast start)
        // but triggers the known yt-dlp bug on some YouTube live streams.
        let firstPipe = try spawnYTDlpPipeProcess(
            url: url,
            source: source,
            sourceLabel: sourceLabel,
            ffmpegPath: ffmpegPath,
            tools: tools,
            useLiveFromStart: true,
            useCookies: true
        )

        // Wait for yt-dlp to either start producing output or die. The
        // timeout has to exceed cookie-extraction-prompt + webpage-fetch
        // + player-API-fetch time (~10-12s in practice for the failing
        // path), otherwise the slow-failing case gets treated as success.
        let failedWithKnownBug = await waitForEarlyFailure(
            timeout: 20.0,
            errorPattern: "No video formats found"
        )

        if failedWithKnownBug {
            print("[Extractor] yt-dlp --live-from-start failed with known formats bug. Retrying without --live-from-start\(hasCookies ? " and without cookies" : "")…")

            // Clean up the failed process (terminationHandler already
            // cleared ytDlpStreamProcess, but belt-and-suspenders).
            if let p = ytDlpStreamProcess, p.isRunning { p.terminate() }
            ytDlpStreamProcess = nil
            ytDlpStreamStderr = nil

            // Second attempt: no --live-from-start, no cookies. Follows
            // the live edge — we lose DVR history but transcription works.
            let retryPipe = try spawnYTDlpPipeProcess(
                url: url,
                source: source,
                sourceLabel: sourceLabel,
                ffmpegPath: ffmpegPath,
                tools: tools,
                useLiveFromStart: false,
                useCookies: false
            )
            return retryPipe
        }

        return firstPipe
    }

    /// Spawn a single yt-dlp pipe process with the given flag configuration.
    /// Factored out of `streamViaYTDlpPipe` so the retry path can call it
    /// twice with different flags without duplicating the arg-building and
    /// process-setup code.
    private func spawnYTDlpPipeProcess(
        url: URL,
        source: StreamSource,
        sourceLabel: String,
        ffmpegPath: String,
        tools: (
            ytDlpPath: String,
            denoPath: String?,
            cookieBrowser: CookieBrowser,
            disableTLSCheck: Bool,
            childEnvironment: [String: String]?
        ),
        useLiveFromStart: Bool,
        useCookies: Bool
    ) throws -> Pipe {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tools.ytDlpPath)
        if let env = tools.childEnvironment {
            process.environment = env
        }

        var args: [String] = []
        if useCookies, let browserArg = tools.cookieBrowser.ytDlpArgument {
            args.append(contentsOf: ["--cookies-from-browser", browserArg])
        }
        // Optional --no-check-certificate; see download-path comment
        // for the rationale. Same toggle drives all yt-dlp
        // invocations.
        if tools.disableTLSCheck {
            args.append("--no-check-certificate")
        }
        // --impersonate chrome ONLY for sites that benefit (Facebook,
        // Instagram). See download-path comment for why this is gated
        // — YouTube specifically fails harder WITH impersonation than
        // without.
        if source.benefitsFromImpersonation {
            args.append(contentsOf: ["--impersonate", "chrome"])
        }
        if let denoPath = tools.denoPath {
            args.append(contentsOf: ["--js-runtimes", "deno:\(denoPath)"])
        }
        // Format selector: with video, a single muxed format yt-dlp
        // can stream on stdout (it can't merge separate streams when
        // piping). Without video, plain bestaudio — audio-only.
        //
        // Codec/container preference is less critical here than on the
        // static-download path because ffmpeg re-encodes the audio to
        // AAC for the cache file (see spawnFFmpeg cache-output args),
        // so Opus-in-WebM input still produces AAC-in-MP4 output.
        // The remaining concern is the VIDEO codec: with `-c:v copy`
        // in the cache encoder, the output video stays in whatever
        // codec the source served. VP9-in-MP4 mostly works on
        // M-series Macs via VideoToolbox, but AVPlayer's behavior is
        // version-dependent enough that we still prefer ext=mp4 here
        // when it's available — that biases yt-dlp toward H.264
        // muxed streams (e.g. YouTube format 18 = 360p H.264+AAC).
        // Falls back to anything muxed when no MP4 is offered.
        let liveFormatSelector = wantsVideoInCacheFlag
            ? "best[height<=480][ext=mp4]/best[height<=480]/best"
            : "bestaudio[acodec*=mp4a]/bestaudio[ext=m4a]/bestaudio/best"
        // HLS / fragmented-stream staging directory. yt-dlp's HLS
        // native downloader writes each fragment to disk before
        // merging and emitting the muxed result to stdout. With
        // `-o -` (pipe mode) and no directory in the output
        // template, those fragment files land in the process CWD —
        // which for a .app bundle launched from Finder defaults to
        // `/`, the read-only system volume since macOS Catalina's
        // SIP-protected system volume. Every fragment write then
        // fails with "Errno 30 Read-only file system" and the
        // whole stream comes up empty.
        //
        // `--paths temp:<dir>` redirects fragment scratch space to
        // an explicit, writable location independent of the output
        // template. Use the same /tmp/streamscribe-yt-<uuid>-frags
        // subdirectory we already create for static-mode staging
        // (cleaned up by the OS at boot, so no lifecycle concerns).
        //
        // The setting is also a no-op for non-HLS streams, so it's
        // safe to apply unconditionally to live mode.
        let fragmentScratchDir = NSTemporaryDirectory().appending("streamscribe-yt-frags-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: fragmentScratchDir, withIntermediateDirectories: true)
        args.append(contentsOf: [
            "-f", liveFormatSelector,
            "-N", "8",
            "--http-chunk-size", "10M",
            "--no-part",
            "--no-warnings",
            "--ffmpeg-location", ffmpegPath,
            "--hls-use-mpegts",
            "--paths", "temp:\(fragmentScratchDir)",
        ])
        if useLiveFromStart {
            args.append("--live-from-start")
        }
        args.append(contentsOf: ["-o", "-", url.absoluteString])
        process.arguments = args

        let printableArgs = args.map { arg -> String in
            if let u = URL(string: arg), u.scheme != nil {
                return "\(u.scheme ?? "")://\(u.host ?? "")\(u.path)"
            }
            return arg
        }.joined(separator: " ")
        print("[yt-dlp] Invoking (pipe): yt-dlp \(printableArgs)")

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Accumulate stderr into a buffer so the retry logic can inspect
        // it for the known error pattern after the process exits. Also
        // log each line for debug visibility.
        let stderrBuffer = MutableByteBuffer()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrBuffer.bytes.append(data)
            if let text = String(data: data, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    print("[yt-dlp stderr] \(trimmed)")
                }
            }
        }
        self.ytDlpStreamStderr = stderrBuffer

        process.terminationHandler = { [weak self] proc in
            // Disable the readability handler FIRST — Foundation owns the
            // dispatch source for this file descriptor while a handler is
            // set, and calling readDataToEndOfFile() concurrently with an
            // active handler is undefined (may block forever). Once the
            // handler is nil'd, we own the fd exclusively and can drain.
            stderrPipe.fileHandleForReading.readabilityHandler = nil

            // Now drain any bytes that arrived after the last handler
            // invocation but before the process exited. This is where the
            // final error line ("No video formats found") typically lives.
            let remaining = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            if !remaining.isEmpty {
                stderrBuffer.bytes.append(remaining)
                if let text = String(data: remaining, encoding: .utf8) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        print("[yt-dlp stderr] \(trimmed)")
                    }
                }
            }
            print("[Extractor] yt-dlp stream process exited with code \(proc.terminationStatus).")
            Task { [weak self] in
                await self?.clearYTDlpStreamProcess()
            }
        }

        self.ytDlpStreamProcess = process
        do {
            try process.run()
        } catch {
            self.ytDlpStreamProcess = nil
            self.ytDlpStreamStderr = nil
            throw ExtractorError.ytDlpResolutionFailed(
                sourceLabel,
                "Failed to spawn yt-dlp for stream pipe: \(error.localizedDescription)"
            )
        }
        return stdoutPipe
    }

    /// Wait up to `timeout` seconds for the current `ytDlpStreamProcess`
    /// to exit. Returns true if the process exited with a non-zero code
    /// AND its stderr contains `errorPattern`. Returns false if the
    /// process is still running after the timeout (success — it's
    /// streaming audio) or if it exited for a different reason.
    /// Wait up to `timeout` seconds for the current `ytDlpStreamProcess`
    /// to either:
    ///   - exit with a non-zero code AND stderr matches `errorPattern` → returns true (failure, retry)
    ///   - exit with a non-zero code but stderr does NOT match → returns false (other failure, don't retry)
    ///   - emit one of `successPatterns` on stderr → returns false (success, exit wait early)
    ///   - timeout while still running → returns false (assumed success)
    ///
    /// The success-pattern early-exit matters because the failing path
    /// can take 10-12s (Keychain prompt + webpage download), and we don't
    /// want a long blanket timeout that delays the successful case. Once
    /// we see yt-dlp's HLS downloader engage ("[hlsnative]") or fragment
    /// download activity, we know it's working and can return immediately
    /// so ffmpeg starts consuming the pipe.
    private func waitForEarlyFailure(timeout: TimeInterval, errorPattern: String) async -> Bool {
        let successPatterns = ["[hlsnative]", "[download] Destination:", "Downloading m3u8"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let stderr = ytDlpStreamStderr.flatMap {
                String(data: $0.bytes, encoding: .utf8)
            } ?? ""

            // Success signal: yt-dlp's HLS downloader is fetching segments.
            // The pipe is filling with audio data; ffmpeg should start
            // consuming it ASAP.
            for pattern in successPatterns where stderr.contains(pattern) {
                print("[Extractor] yt-dlp emitted success signal '\(pattern)' — proceeding to ffmpeg.")
                return false
            }

            // Process exited.
            if let proc = ytDlpStreamProcess, !proc.isRunning {
                print("[Extractor] yt-dlp exited early (code \(proc.terminationStatus)), stderr length: \(stderr.count) bytes")
                if proc.terminationStatus != 0 && stderr.contains(errorPattern) {
                    return true
                }
                return false
            }
            if ytDlpStreamProcess == nil {
                print("[Extractor] yt-dlp process pointer cleared, stderr length: \(stderr.count) bytes")
                return stderr.contains(errorPattern)
            }

            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        // Timeout while still running. yt-dlp may not have emitted a
        // recognizable success pattern yet, but it's alive and the
        // downstream ffmpeg will surface any real problem from the byte
        // stream. Treat as success.
        print("[Extractor] yt-dlp still running after \(timeout)s — treating as success.")
        return false
    }

    /// Companion to `clearYTDlpDownloadProcess` for the live-pipe path.
    private func clearYTDlpStreamProcess() {
        self.ytDlpStreamProcess = nil
    }

    // MARK: - yt-dlp resolution

    /// Use yt-dlp to resolve a watchable-page URL (YouTube, Twitter/X, etc.) to a
    /// direct media URL that ffmpeg can read. yt-dlp picks the right site-specific
    /// extractor based on the input URL's host — we don't have to dispatch on
    /// `sourceLabel`, that's just used for user-facing error messages.
    ///
    /// `-f bestaudio` selects an audio-only stream when available, falling back to
    /// a muxed video stream when the site doesn't expose audio-only renditions
    /// (which is typical for Twitter — most tweet videos are H.264/AAC mp4).
    /// ffmpeg pulls audio out of the muxed stream regardless.
    private static func resolveViaYTDlp(_ url: URL, sourceLabel: String, wantsVideo: Bool) async throws -> String {
        let tools = try await resolveYTDlpTools()

        return try await withCheckedThrowingContinuation { cont in
            let process = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: tools.ytDlpPath)
            if let env = tools.childEnvironment {
                process.environment = env
            }
            // Build args. Cookie flag goes first so it's clearly visible in the
            // logged command line, before the format/extraction flags.
            //
            // -f bestaudio/best : prefer audio-only, fall back to best muxed track.
            //                     Twitter rarely offers separate audio renditions,
            //                     so the fallback is what actually fires there.
            // -g                : print the resolved direct media URL and exit
            //                     (no download). One URL per format on stdout.
            // --cookies-from-browser <name>
            //                   : present when the user picks a browser. Passes
            //                     real session cookies so YouTube live, age-gated,
            //                     and members-only content extraction works. Costs
            //                     the user a Keychain access prompt the first time.
            //                     yt-dlp will error if the named browser isn't
            //                     installed; we surface that error verbatim via the
            //                     stderr logging added in this same change.
            // --js-runtimes deno:<path>
            //                   : tells yt-dlp where to find our auto-downloaded
            //                     Deno binary so it can solve YouTube's n-param
            //                     JavaScript challenges. Without this, late-2025+
            //                     YouTube extraction fails with "No video formats
            //                     found" or "n challenge solving failed" warnings.
            var args: [String] = []
            if let browserArg = tools.cookieBrowser.ytDlpArgument {
                args.append(contentsOf: ["--cookies-from-browser", browserArg])
            }
            // Optional --no-check-certificate; see download-path comment
            // above for the rationale. Same toggle drives all yt-dlp
            // invocations.
            if tools.disableTLSCheck {
                args.append("--no-check-certificate")
            }
            // Note: no `--impersonate` here. This static helper is
            // not called from any live code path, but if it were
            // revived it should be passed the source so impersonation
            // can be gated the same way as the download/live-pipe
            // paths.
            if let denoPath = tools.denoPath {
                args.append(contentsOf: ["--js-runtimes", "deno:\(denoPath)"])
            }
            // Mirrors the live-pipe format selector — single muxed
            // container at ≤480p with audio-only fallback when video
            // is wanted, plain bestaudio when not. -g returns the
            // resolved direct URL which then gets fed to ffmpeg
            // directly.
            let resolveFormatSelector = wantsVideo
                ? "best[height<=480]/bestaudio/best"
                : "bestaudio/best"
            args.append(contentsOf: [
                "-f", resolveFormatSelector,
                "-g", url.absoluteString,
            ])
            process.arguments = args

            // Log the invocation so the user (and us during debugging) can see
            // exactly what yt-dlp is being asked to do. We strip any URL query
            // string from the printed args because tweet-style URLs sometimes
            // include access tokens we shouldn't log; the URL host + path is
            // enough to identify the request.
            let printableArgs = args.map { arg -> String in
                if let u = URL(string: arg), u.scheme != nil {
                    return "\(u.scheme ?? "")://\(u.host ?? "")\(u.path)"
                }
                return arg
            }.joined(separator: " ")
            print("[yt-dlp] Invoking: yt-dlp \(printableArgs)")

            process.standardOutput = outPipe
            process.standardError = errPipe

            process.terminationHandler = { proc in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: outData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""

                // Always surface yt-dlp's stderr to the log, even on success. yt-dlp
                // emits informational warnings on stderr that don't cause non-zero
                // exit but do indicate the extracted URL may be problematic — e.g.
                // "GVS PO Token required for this client; formats may yield 403",
                // "Some formats are unavailable", anti-bot challenge notices. Without
                // this, those warnings only surface when the user happens to run
                // yt-dlp from terminal, which makes "why is my live stream 403ing?"
                // very hard to diagnose.
                let trimmedErr = err.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedErr.isEmpty {
                    print("[yt-dlp stderr]\n\(trimmedErr)")
                }

                if proc.terminationStatus != 0 || out.isEmpty {
                    cont.resume(throwing: ExtractorError.ytDlpResolutionFailed(
                        sourceLabel,
                        err.isEmpty ? "exit \(proc.terminationStatus)" : err
                    ))
                } else {
                    // Take first line — yt-dlp may print video+audio URLs separately
                    // when it falls back to non-audio-only formats. The first line
                    // is the highest-priority match for our format spec.
                    let firstLine = out.split(separator: "\n").first.map(String.init) ?? out
                    cont.resume(returning: firstLine)
                }
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    // MARK: - Concurrent tool resolution

    /// Resolves yt-dlp path, Deno path, and the cookie browser setting
    /// concurrently. yt-dlp and Deno both trigger a download on first use
    /// (~25MB and ~30MB respectively); running them in parallel roughly
    /// halves the wait vs. the sequential pattern. The cookie read is
    /// trivially fast but rides along for free.
    ///
    /// yt-dlp is mandatory (throws on failure after fallback-to-PATH).
    /// Deno is best-effort (nil on failure — Twitter/non-YouTube sources
    /// don't need it). Cookie browser is always available (enum read).
    private static func resolveYTDlpTools() async throws -> (
        ytDlpPath: String,
        denoPath: String?,
        cookieBrowser: CookieBrowser,
        disableTLSCheck: Bool,
        childEnvironment: [String: String]?
    ) {
        async let ytDlp = requireYTDlpPath()
        async let deno = optionalDenoPath()
        async let cookie: CookieBrowser = MainActor.run { ToolManager.shared.cookieBrowser }
        async let tlsCheck: Bool = MainActor.run { ToolManager.shared.disableTLSCheck }
        async let childEnv: [String: String]? = MainActor.run { ToolManager.shared.ytDlpChildEnvironment() }

        let ytDlpPath = try await ytDlp
        let denoPath = await deno
        let cookieBrowser = await cookie
        let disableTLSCheck = await tlsCheck
        let childEnvironment = await childEnv
        return (ytDlpPath, denoPath, cookieBrowser, disableTLSCheck, childEnvironment)
    }

    /// Best-effort Deno resolution. Returns nil on any failure — Deno is
    /// only needed for YouTube's n-param challenges; other sources (Twitter,
    /// SoundCloud, etc.) work without it. Factored out as a static so
    /// `async let` in `resolveYTDlpTools` can call it without a closure.
    private static func optionalDenoPath() async -> String? {
        do {
            return try await ToolManager.shared.ensureDenoAvailable()
        } catch {
            print("[Extractor] Could not obtain Deno: \(error.localizedDescription). Proceeding without; YouTube extraction may fail.")
            return nil
        }
    }

    // MARK: - Tool discovery

    /// Path to the bundled ffmpeg binary. Throws if the bundle is missing it.
    private static func requireFFmpegPath() throws -> String {
        if let path = ToolManager.shared.ffmpegPath,
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fallback: PATH scan, in case someone built the project without bundling ffmpeg
        // and still has it via Homebrew. Explicit fallback so dev workflow doesn't break.
        if let path = locate(executable: "ffmpeg") {
            return path
        }
        throw ExtractorError.ffmpegMissing
    }

    /// Path to yt-dlp managed by ToolManager. Triggers a download on first use.
    private static func requireYTDlpPath() async throws -> String {
        do {
            return try await ToolManager.shared.ensureYTDlpAvailable()
        } catch {
            // If managed download failed but a system yt-dlp exists, use that instead.
            if let path = locate(executable: "yt-dlp") {
                return path
            }
            throw ExtractorError.ytDlpMissing
        }
    }

    /// PATH scan, used only as a dev-mode fallback.
    private static func locate(executable name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }
}
