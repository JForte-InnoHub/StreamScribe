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
/// Lock-guarded flag shared between the actor and ffmpeg's nonisolated
/// termination handler. During a live escalation respawn, the OLD
/// ffmpeg's exit must NOT finish the AsyncStream continuation — the
/// new yt-dlp/ffmpeg pair keeps feeding the same stream. One-shot:
/// consumed (reset) by the first termination it suppresses.
/// Converts interleaved stereo PCM to mono, choosing HOW based on what
/// the channels actually contain.
///
/// A fixed (L+R)/2 average is wrong for two real-world feed defects:
/// polarity-inverted channels (the average cancels to silence) and
/// audio present on only one channel (the average is 6 dB down and
/// carries the dead channel's noise). Both are common in government
/// and broadcast plant wiring, and both are invisible to a human
/// listening in stereo — which is why they reach us at all.
///
/// Strategy: buffer the opening seconds, measure the normalized
/// correlation between channels, commit to one rule, and keep it for
/// the session. Nothing is emitted until the verdict lands, so the
/// opening audio is downmixed correctly too — on an inverted source
/// a provisional average would have silently destroyed exactly the
/// window we were measuring.
private final class StereoDownmixer {
    enum Mode: String {
        case average    // r ≈ +1 or uncorrelated — ordinary stereo
        case difference // r ≈ -1 — polarity-inverted; (L-R)/2 recovers it
        case left       // right channel effectively dead
        case right      // left channel effectively dead
    }

    /// 3 seconds at 16 kHz. Long enough to contain speech on a hearing
    /// feed, short enough that a wrong opening guess costs little.
    private let framesNeeded = 48_000
    private var pending: [Float] = []
    private var carry: Float?
    private(set) var mode: Mode?

    /// Interleaved stereo in, mono out. Handles an odd float count
    /// across calls — a split L/R pair would otherwise swap the
    /// channels for the remainder of the stream.
    func downmix(_ interleaved: [Float]) -> [Float] {
        var input = interleaved
        if let c = carry {
            input.insert(c, at: 0)
            carry = nil
        }
        if input.count % 2 == 1 {
            carry = input.removeLast()
        }
        guard !input.isEmpty else { return [] }

        if mode == nil {
            pending.append(contentsOf: input)
            guard pending.count >= framesNeeded * 2 else {
                // Emit NOTHING while deciding. An earlier draft returned
                // a provisional average here and ALSO kept the samples
                // buffered, so every sample in the decision window went
                // downstream twice — caught by a chunk-boundary test
                // that compared streamed output against a single-call
                // reference. Holding the window costs ~3s of latency at
                // session start, immaterial against a 10-30s chunker,
                // and it means the opening seconds are downmixed with
                // the CORRECT rule rather than the wrong one.
                return []
            }
            let decided = Self.decide(pending)
            mode = decided
            let flushed = Self.apply(decided, to: pending)
            pending = []
            return flushed
        }
        return Self.apply(mode ?? .average, to: input)
    }

    /// Flush whatever is buffered when the stream ends before the
    /// decision window filled (short clips).
    func drain() -> [Float] {
        guard mode == nil, !pending.isEmpty else { return [] }
        let decided = Self.decide(pending)
        mode = decided
        let out = Self.apply(decided, to: pending)
        pending = []
        return out
    }

    private static func decide(_ interleaved: [Float]) -> Mode {
        var sumLL = 0.0, sumRR = 0.0, sumLR = 0.0
        var i = 0
        while i + 1 < interleaved.count {
            let l = Double(interleaved[i]), r = Double(interleaved[i + 1])
            sumLL += l * l
            sumRR += r * r
            sumLR += l * r
            i += 2
        }
        let energyL = sumLL, energyR = sumRR
        // A channel carrying <1% of the other's energy is dead, not quiet.
        if energyR < energyL * 0.01 { return .left }
        if energyL < energyR * 0.01 { return .right }

        let denom = (sumLL * sumRR).squareRoot()
        guard denom > 0 else { return .average }
        let r = sumLR / denom
        // -0.8 rather than -0.5: only a near-perfect inversion should
        // flip us to subtraction. Genuinely wide stereo can sit mildly
        // negative without the average cancelling anything important.
        return r < -0.8 ? .difference : .average
    }

    private static func apply(_ mode: Mode, to interleaved: [Float]) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(interleaved.count / 2)
        var i = 0
        while i + 1 < interleaved.count {
            let l = interleaved[i], r = interleaved[i + 1]
            switch mode {
            case .average:    out.append((l + r) * 0.5)
            case .difference: out.append((l - r) * 0.5)
            case .left:       out.append(l)
            case .right:      out.append(r)
            }
            i += 2
        }
        return out
    }
}

private final class EscalationFlag {
    let lock = NSLock()
    var suppressFinishOnce = false
}

/// Per-spawn counter for googlevideo fragment 403s. A 403 STORM
/// (2026-07-22 field log: format 94 — an HLS format from the merged
/// client list's non-web clients, which the WebPO-only token provider
/// cannot authorize — 403'd every fragment forever) is starvation
/// with a different face: delivery is zero, but the watchdog's
/// 30s window is the wrong detector shape for an error that
/// announces itself six times in ten seconds. One counter per spawn;
/// handlers of dead spawns keep their own dead counter so residual
/// stderr can never trip the new pipe's threshold.
private final class Error403Counter {
    let lock = NSLock()
    var count = 0
}

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
    /// 16000 Hz × 4 bytes/sample (Float32) × 2 channels = 128000 bytes/sec.
    /// Tracks the `-ac 2` request above — get this wrong and every
    /// "Audio rate: N.NNx realtime" line is off by exactly 2x.
    static let bytesPerSecondRealtime: Int = Int(sampleRate) * 4 * 2

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

    // MARK: Live starvation watchdog (2026-07-21)
    //
    // FIELD FAILURE this exists for: YouTube's PO-token era starves
    // flagged clients per-fragment ("Read timed out.. Retrying
    // (1/inf)" forever) — the stream stays CONNECTED but delivers a
    // trickle, so the early-failure retry never fires and the session
    // sits text-less. The proven manual remedy is rotating the player
    // client (and dropping account cookies, since flags follow the
    // account across clients); this watchdog automates it: sustained
    // under-delivery → kill the yt-dlp/ffmpeg pair → respawn at the
    // live edge with the next escalation step, SAME continuation.
    private var watchdogTask: Task<Void, Never>?
    /// One-shot: set when yt-dlp reports YouTube's bot-check
    /// interstitial. Stops the watchdog and blocks further
    /// escalations — every additional automated attempt against a
    /// bot-walled IP EXTENDS the wall (field lesson 2026-07-21:
    /// probes + pipes + escalations + parallel downloads from one IP
    /// promoted a throttle into a hard interstitial).
    private var botWallDetected = false
    private var escalationAttempt = 0
    private let escalationFlag = EscalationFlag()
    private var current403Counter: Error403Counter?
    /// Index of the NEXT fallback proxy to try (0 = none tried yet;
    /// the session starts on the configured primary proxy or direct).
    private var proxyRotationIndex = 0
    private var currentRateStats: AudioRateStats?
    private var liveEscalationContext: (url: URL, source: StreamSource, sourceLabel: String, ffmpegPath: String, cacheOutputPath: String?)?

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
        if source == .senateGov {
            // Senate.gov path: resolve the page URL (or direct ISVP URL)
            // to its underlying HLS m3u8 via our own extractor, then
            // route through the .hls path. ~500 ms fast path vs ~6-9 s
            // for the yt-dlp + URL-resolution fallback chain.
            //
            // On extractor failure (unknown committee, page structure
            // change, etc.) fall back to yt-dlp's senategov extractor,
            // which keeps pace with senate.gov's CDN changes better than
            // our hardcoded mapping will.
            do {
                let resolved = try await SenateGovExtractor.resolve(url: url)
                print("[Extractor] U.S. Senate: \(resolved.committee)/\(resolved.filename) → \(resolved.m3u8URL.absoluteString)")
                inputURL = resolved.m3u8URL.absoluteString
                inputIsLocalFile = false
            } catch {
                // Fall back to yt-dlp's senategov extractor. Log the
                // direct-extractor failure so we can update the committee
                // mapping if a real-world hearing surfaces a gap.
                print("[Extractor] U.S. Senate direct extractor failed (\(error.localizedDescription)) — falling back to yt-dlp.")
                print("[Extractor] Streaming pipe via yt-dlp (parallel fragments)…")
                // isStaticSession false: the Senate fallback serves live or
                // unknown-duration streams; keep the live hardening.
                let pipe = try await streamViaYTDlpPipe(url, source: .unknown, ffmpegPath: ffmpeg, isStaticSession: false)
                ytDlpStdinPipe = pipe
                inputURL = "-"
                inputIsLocalFile = false
            }
        } else if source == .criticalMention || source == .granicus || source == .iqMedia {
            // Browser-extractor path (Critical Mention + Granicus):
            // both serve pages whose JS player fetches the real HLS
            // URL at runtime — CM a signed assets stream, Granicus a
            // Wowza `playlist.m3u8`. Our WKWebView extractor watches
            // network requests for the m3u8 and returns it. No yt-dlp
            // involvement — neither site has a yt-dlp extractor.
            //
            // Extractor failure (private clip, timeout, page structure
            // change) has no yt-dlp fallback for this source. Surface
            // the error to the user rather than trying an alternate
            // path that would also fail.
            do {
                let resolved = try await CriticalMentionExtractor.resolve(url: url)
                print("[Extractor] Critical Mention → \(resolved.m3u8URL.absoluteString)")
                inputURL = resolved.m3u8URL.absoluteString
                inputIsLocalFile = false
            } catch {
                print("[Extractor] Critical Mention extraction failed: \(error.localizedDescription)")
                throw ExtractorError.ytDlpResolutionFailed("Critical Mention", error.localizedDescription)
            }
        } else if source.requiresYTDlp {
            // Always use the streaming pipe path for yt-dlp sources,
            // regardless of probed session mode. The old branch (when
            // `useFastDownload` was true) downloaded the ENTIRE file to
            // a temp location before ffmpeg read it — fine for short
            // YouTube clips but catastrophic for long content like
            // Senate hearings (50–100 min @ ~5 MB/min = 250–500 MB
            // download before any transcription begins, so the user
            // sees nothing happen for 5–15 minutes). The pipe path
            // streams as fragments arrive, so the first transcribed
            // segment appears within seconds.
            //
            // The miniplayer cache is preserved because it's built by
            // ffmpeg's secondary output (see `startFFmpeg`'s cache
            // output block) — that runs regardless of whether ffmpeg's
            // input is a local file or stdin from the pipe. The
            // miniplayer cache file grows in real time as audio flows
            // through ffmpeg, so playback during transcription works
            // the same way as the direct-HLS path that the user
            // already sees "fires right away."
            //
            // `useFastDownload` parameter retained for API
            // compatibility but no longer used by this code path —
            // could be removed in a follow-up alongside
            // `downloadViaYTDlp` if nothing else depends on them.
            //
            // Direct HLS sources (.hls, .directAudio) and local files
            // still route through their respective branches below;
            // they don't need yt-dlp at all and were never affected
            // by the download-vs-stream choice.
            print("[Extractor] Streaming pipe via yt-dlp (parallel fragments)…")
            // `useFastDownload` is set by the engine as
            // `source.requiresYTDlp && resolvedSessionMode == .static`
            // (TranscriptionEngine.start), so inside this requiresYTDlp
            // branch it is exactly the static-session signal. Sessions
            // whose probe couldn't determine a duration resolve to
            // .live and conservatively keep the hardening.
            let pipe = try await streamViaYTDlpPipe(url, source: source, ffmpegPath: ffmpeg, isStaticSession: useFastDownload)
            ytDlpStdinPipe = pipe
            inputURL = "-"
            inputIsLocalFile = false
            // Live sessions get the starvation watchdog; static
            // sessions don't (finite retries fail fast there, and a
            // static download legitimately idles between chunk
            // bursts, which would false-trip a rate watchdog).
            if !useFastDownload {
                liveEscalationContext = (url, source, "\(source)", ffmpeg, cacheOutputPath)
                escalationAttempt = 0
            } else {
                liveEscalationContext = nil
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
                if ytDlpStdinPipe != nil, self.liveEscalationContext != nil {
                    self.startLiveWatchdog()
                }
            } catch {
                print("[Extractor] Failed to spawn ffmpeg: \(error)")
                continuation.finish()
            }
        }

        return stream
    }

    func stop() {
        watchdogTask?.cancel()
        watchdogTask = nil
        liveEscalationContext = nil
        escalationAttempt = 0
        botWallDetected = false
        current403Counter = nil
        proxyRotationIndex = 0
        ToolManager.sessionProxyOverride = nil
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

    // MARK: - Live starvation watchdog

    private func currentDeliveredBytes() -> Int {
        guard let stats = currentRateStats else { return 0 }
        stats.lock.lock(); defer { stats.lock.unlock() }
        return stats.totalBytes
    }

    /// Arm the watchdog for a live pipe session. Grace period covers
    /// slow live-edge joins; after that, delivery below 0.3x realtime
    /// over a 30s window means the client is being starved (healthy
    /// live delivery is 0.9-1.1x; live-edge jitter is stall-then-burst
    /// which still averages fine over 30s) and triggers escalation.
    private func startLiveWatchdog() {
        watchdogTask?.cancel()
        print("[Watchdog] Armed: grace 30s, then fast-trip check (<0.6x delivered → immediate escalation), then 30s windows at 0.6x threshold.")
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if Task.isCancelled { return }
            // Fast-trip: a session that has delivered essentially
            // nothing by the end of the grace period is starved from
            // birth — don't make the user wait out a full measurement
            // window on top (field feedback 2026-07-21: worst-case
            // first rescue was ~80s of dead air; now ~31s).
            if let self {
                let bytes = await self.currentDeliveredBytes()
                let audioSeconds = Double(bytes) / Double(Self.bytesPerSecondRealtime)
                // Same 0.6x criterion as the rolling windows. Field
                // lesson (2026-07-21): a steady mechanical throttle
                // delivered a rock-solid 0.32x — above the old 0.3
                // threshold, below anything usable. Healthy live is
                // 0.9-1.1x; sustained sub-0.6 is always broken.
                if audioSeconds < 18.0 {
                    print(String(format: "[Watchdog] Fast-trip: only %.1fs audio delivered in the first 30s.", audioSeconds))
                    await self.escalateLivePipe(measuredRatio: audioSeconds / 30.0)
                }
            }
            guard var lastBytes = await self?.currentDeliveredBytes() else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                let now = await self.currentDeliveredBytes()
                let delta = now - lastBytes
                lastBytes = now
                let audioSeconds = Double(delta) / Double(Self.bytesPerSecondRealtime)
                let ratio = audioSeconds / 30.0
                if ratio < 0.6 {
                    await self.escalateLivePipe(measuredRatio: ratio)
                    // Baseline resets with the fresh rateStats of the
                    // respawned ffmpeg.
                    lastBytes = await self.currentDeliveredBytes()
                }
            }
        }
    }

    /// YouTube's bot-check interstitial appeared. Every further
    /// automated attempt from this IP makes the wall last longer, so:
    /// stop the watchdog, block the ladder, kill the processes, end
    /// the session. The remedies are outside the app and time-bound —
    /// say so loudly instead of churning.
    /// Egress rotation (2026-07-23): when IP-scoped enforcement hits
    /// — the bot wall, or a 403 storm surviving the whole client
    /// ladder — advance to the next configured fallback proxy and
    /// restart the pipe through it, with a FRESH client-escalation
    /// ladder (a new IP deserves rung 1 again). Sticky by design: a
    /// proxy that works keeps the rest of the session; rotation only
    /// advances on the next enforcement hit. Returns false when the
    /// list is exhausted (or empty) — callers then fall through to
    /// their loud terminal banners. Field basis: fleet shares
    /// Netskope egress IPs (whole building = one identity to
    /// YouTube); VPN test showed instant recovery on a fresh egress.
    private func rotateEgress(reason: String) async -> Bool {
        let fallbacks = ToolManager.proxyFallbackList()
        guard proxyRotationIndex < fallbacks.count else { return false }
        let next = fallbacks[proxyRotationIndex]
        proxyRotationIndex += 1
        ToolManager.sessionProxyOverride = next
        print("[Egress] \(reason) — rotating to fallback proxy \(proxyRotationIndex)/\(fallbacks.count): \(Self.redactProxyCredentials(next))")
        botWallDetected = false
        escalationAttempt = 0
        await escalateLivePipe(measuredRatio: 0)
        return true
    }

    /// Credentials never go in logs: http://user:pass@host → http://•••@host
    private static func redactProxyCredentials(_ url: String) -> String {
        guard let atIdx = url.lastIndex(of: "@"),
              let schemeRange = url.range(of: "://") else { return url }
        return String(url[..<schemeRange.upperBound]) + "•••" + String(url[atIdx...])
    }

    private func handleBotWall() async {
        guard !botWallDetected else { return }
        botWallDetected = true
        escalationAttempt = Int.max  // silence termination-handler escalation during teardown
        if let p = ytDlpStreamProcess, p.isRunning { p.terminate() }
        if let p = ffmpegProcess, p.isRunning { p.terminate() }
        // Fresh egress beats waiting out the wall — rotation resets
        // the ladder and respawns; the banner is the no-proxies-left
        // path only.
        if await rotateEgress(reason: "Bot wall on current egress IP") { return }
        watchdogTask?.cancel()
        watchdogTask = nil
        print("""
        [BotWall] ==========================================================
        [BotWall] YouTube is serving its "Sign in to confirm you're not a
        [BotWall] bot" interstitial for this IP address. Cookies, player
        [BotWall] clients, and PO tokens do not bypass this tier — it is an
        [BotWall] IP-level block, typically triggered by many rapid
        [BotWall] automated requests, and it is TIME-BOUND (usually clears
        [BotWall] within an hour if the requests stop). StreamScribe has
        [BotWall] stopped retrying so as not to extend it.
        [BotWall] Remedies: wait it out; or use a different network path
        [BotWall] (hotspot, VPN, or the proxy setting in the sidebar).
        [BotWall] ==========================================================
        """)
    }

    /// Six fragment 403s from the CURRENT pipe: this config's media
    /// URLs are unauthorized for us (typically a merged-client-list
    /// format whose client the WebPO provider can't cover). Respond
    /// like starvation, immediately: next ladder rung = fresh
    /// extraction = fresh format choice under new conditions. When
    /// the ladder is already exhausted, stop the session LOUDLY —
    /// an infinite 403 retry loop delivers nothing, burns requests,
    /// and reads as a hang.
    private func handle403Storm(from counter: Error403Counter) async {
        guard counter === current403Counter else { return }  // stale spawn's stderr
        guard !botWallDetected else { return }
        if escalationAttempt >= 3 || watchdogTask == nil {
            if await rotateEgress(reason: "403 storm with client ladder exhausted") { return }
            print("""
            [403Storm] ================================================
            [403Storm] YouTube is rejecting this stream's media URLs
            [403Storm] (HTTP 403) for every client configuration the
            [403Storm] escalation ladder tried. The stream may be
            [403Storm] region- or membership-restricted, or its media
            [403Storm] is enforcement-locked for non-browser clients
            [403Storm] right now. Stopping instead of looping.
            [403Storm] Remedies: the proxy setting (different egress),
            [403Storm] retrying in a while, or capturing via a
            [403Storm] different source for this event.
            [403Storm] ================================================
            """)
            watchdogTask?.cancel()
            watchdogTask = nil
            if let p = ytDlpStreamProcess, p.isRunning { p.terminate() }
            if let p = ffmpegProcess, p.isRunning { p.terminate() }
            return
        }
        print("[403Storm] Fragment 403 storm on the current pipe — escalating immediately instead of waiting out the starvation window.")
        await escalateLivePipe(measuredRatio: 0)
    }

    /// The escalation ladder. Step 1 keeps the configured client but
    /// drops cookies (account-level flags survive client rotation, so
    /// shedding the account is the cheapest first move). Steps 2-3
    /// rotate to clients this session hasn't burned. Rejoin is at the
    /// live edge (no --live-from-start): the starved gap is already
    /// lost either way, and the transcript timeline simply continues —
    /// the discontinuity is logged for the record.
    private func escalateLivePipe(measuredRatio: Double) async {
        guard !botWallDetected else { return }
        guard let ctx = liveEscalationContext, let continuation = continuation else { return }
        let ladder: [(client: String?, label: String)] = [
            (nil, "configured client, cookies dropped"),
            ("web_embedded", "web_embedded, cookies dropped"),
            ("default", "yt-dlp default clients, cookies dropped"),
        ]
        escalationAttempt += 1
        guard escalationAttempt <= ladder.count else {
            print("[Watchdog] Starvation persists after full escalation ladder — leaving the current pipe to ride yt-dlp's retries. Manual remedies: rotate the player-client setting, wait out the cooldown, or change networks.")
            watchdogTask?.cancel()
            watchdogTask = nil
            return
        }
        let step = ladder[escalationAttempt - 1]
        print(String(format: "[Watchdog] Live delivery %.2fx realtime over 30s — starvation. Escalation %d/%d: %@.",
                     measuredRatio, escalationAttempt, ladder.count, step.label))

        // Deliberate teardown of the current pair. Suppress the
        // continuation-finish that ffmpeg's termination handler would
        // otherwise perform.
        escalationFlag.lock.lock()
        escalationFlag.suppressFinishOnce = true
        escalationFlag.lock.unlock()
        if let p = ytDlpStreamProcess, p.isRunning { p.terminate() }
        if let p = ffmpegProcess, p.isRunning { p.terminate() }
        // Let termination handlers run before respawning over the
        // same properties.
        try? await Task.sleep(nanoseconds: 500_000_000)

        do {
            let tools = try await Self.resolveYTDlpTools()
            let newPipe = try spawnYTDlpPipeProcess(
                url: ctx.url,
                source: ctx.source,
                sourceLabel: ctx.sourceLabel,
                ffmpegPath: ctx.ffmpegPath,
                tools: tools,
                isStaticSession: false,
                useLiveFromStart: false,
                useCookies: false,
                playerClientOverride: step.client
            )
            try spawnFFmpeg(
                ffmpegPath: ctx.ffmpegPath,
                inputURL: "-",
                isNetworkInput: false,
                stdinPipe: newPipe,
                cacheOutputPath: ctx.cacheOutputPath,
                continuation: continuation
            )
            print("[Watchdog] Respawned pipe at live edge (\(step.label)). Transcript timeline continues; the starved gap is not recoverable. Miniplayer cache restarts.")
        } catch {
            print("[Watchdog] Escalation respawn failed: \(error.localizedDescription) — will re-evaluate on the next window.")
        }
    }

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
        // Opt-in loudness taming (2026-07-21, default OFF — sidebar
        // toggle). Hot, heavily compressed broadcast masters (Fox) are
        // the reliable trigger for Whisper's ALL-CAPS caption-style
        // collapse; dynaudnorm is streaming-safe and pulls input level
        // toward the training distribution. Off by default because
        // this PCM also feeds diarization + voiceprint embeddings —
        // WeSpeaker normalizes internally so impact should be nil, but
        // that's an empirical question the toggle exists to answer,
        // not an assumption to bake in silently.
        if UserDefaults.standard.bool(forKey: "extractor.audioNormalizationEnabled") {
            args.append(contentsOf: ["-af", "dynaudnorm=f=250:g=15"])
        }
        args.append(contentsOf: [
            // STEREO IN, ADAPTIVE MONO OUT (2026-08-26). This was
            // `-ac 1`, which is a plain (L+R)/2 average — and on a
            // POLARITY-INVERTED source that average is mathematically
            // ZERO. Confirmed on a CT-N hearing: the left channel
            // measured -32.6 dB mean / -11.9 dB max while our mono feed
            // read as digital silence, and `(L-R)/2` reproduced the
            // left channel exactly, proving R = -L. Every ASR failed
            // identically on it (Parakeet, Canary, Whisper, and Otter)
            // for the same reason — they all downmix to mono first, so
            // they all destroyed the same audio.
            //
            // We now take both channels and decide the downmix
            // ourselves in StereoDownmixer, which can also rescue the
            // adjacent case of a feed carrying audio on one channel
            // only. Costs one extra PCM channel over the pipe (16 kHz
            // float ≈ 64 KB/s) — nothing against the video alongside it.
            "-ac", "2",                               // stereo; downmixed adaptively below
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
                // Capital V, deliberately (2026-07-22): `0:v?` also
                // matches ATTACHED-PICTURE streams — podcast files
                // carry cover art that ffmpeg surfaces as a video
                // stream. Stream-copying artwork into the fMP4 cache
                // fails at the muxer ("Could not find tag for codec"),
                // which aborts the WHOLE ffmpeg process, slams the
                // stdin pipe shut (yt-dlp: "Broken pipe"), and kills
                // the session ~0.5s in — field failure on an Apple
                // Podcasts episode. `0:V?` matches real video only,
                // excluding attached pictures; audio-only sources with
                // artwork degrade to an audio-only cache exactly as
                // sources with no video stream always have.
                cacheArgs.append(contentsOf: ["-map", "0:V?"])
            }
            cacheArgs.append(contentsOf: [
                "-map", "0:a:0",
            ])
            if wantsVideoInCacheFlag {
                // Transcode cache video to H.264 via VideoToolbox
                // (hardware encoder — near-zero CPU on Apple Silicon)
                // instead of stream-copying whatever codec the source
                // served. Field bug behind this: when YouTube's
                // premuxed MP4 (H.264) tier stopped matching, the
                // format selector's fallback matched a VP9 premuxed
                // format, and `-c:v copy` shipped VP9 inside the .mp4
                // cache — which AVPlayer renders as a BLACK video area
                // with working audio, on every video, with the
                // transcript unaffected. Hardware-transcoding to
                // H.264 makes the cache playable regardless of what
                // codec the source serves, today and after the next
                // upstream format shuffle. Cost: an extra encode of
                // ≤480p video on the media engine — imperceptible on
                // M-series. (H.264 sources get a pointless re-encode;
                // accepted for the codec-proof guarantee.)
                cacheArgs.append(contentsOf: [
                    "-c:v", "h264_videotoolbox",
                    "-b:v", "1500k",
                    "-pix_fmt", "yuv420p",
                ])
            }
            cacheArgs.append(contentsOf: [
                "-c:a", "aac",
                "-b:a", "128k",
                "-f", "mp4",
                // +faststart REMOVED (2026-07): for a fragmented mp4
                // it adds nothing during the session, and its
                // on-exit file rewrite yanks the bytes out from
                // under any AVFragmentedAsset reader the miniplayer
                // has open at that moment. The fragmented file plays
                // fine as-is once complete.
                "-movflags", "+frag_keyframe+empty_moov",
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

        // Adaptive stereo→mono, one per ffmpeg spawn. spawnFFmpeg is
        // re-entered on every escalation respawn, so a new stream
        // re-decides its downmix rather than inheriting a verdict
        // formed from a different rendition. Declared beside the PCM
        // buffer it feeds, since this function owns the stdout reader.
        let downmixer = StereoDownmixer()

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
        // Watchdog visibility: each ffmpeg spawn gets fresh stats; the
        // watchdog always reads the CURRENT one, so an escalation
        // respawn also resets its measurement baseline.
        self.currentRateStats = rateStats
        let escFlag = self.escalationFlag

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
            let modeBefore = downmixer.mode
            let mono = downmixer.downmix(floats)
            if modeBefore == nil, let decided = downmixer.mode {
                print("[Extractor] Stereo downmix: \(decided.rawValue)" +
                      (decided == .average ? "" : " — source channels are not ordinary stereo; corrected"))
            }
            if !mono.isEmpty { continuation.yield(mono) }
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
                let mono = downmixer.downmix(floats)
                if !mono.isEmpty { continuation.yield(mono) }
            }
            // A clip shorter than the decision window leaves audio
            // buffered inside the downmixer — flush it or the whole
            // file goes missing.
            let tail = downmixer.drain()
            if !tail.isEmpty {
                print("[Extractor] Flushed \(tail.count) buffered samples (downmix: \(downmixer.mode?.rawValue ?? "average")).")
                continuation.yield(tail)
            }
            // Any final 1–3 trailing bytes are dropped — they can't form a sample.

            errPipe.fileHandleForReading.readabilityHandler = nil
            // Escalation respawn in progress? Then this exit is
            // deliberate — keep the continuation open for the new
            // ffmpeg. One-shot flag; see EscalationFlag.
            escFlag.lock.lock()
            let suppressFinish = escFlag.suppressFinishOnce
            escFlag.suppressFinishOnce = false
            escFlag.lock.unlock()
            if suppressFinish {
                print("[Extractor] ffmpeg exited for escalation respawn — stream continuation kept open.")
            } else {
                continuation.finish()
            }
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
            // Warm-up speedup flags. Two effects:
            //
            //   - `--ignore-config`: skip the user's yt-dlp config
            //     files (`~/.config/yt-dlp/config`, `~/.yt-dlp.conf`,
            //     etc). Config parsing adds 100-500ms per invocation,
            //     and any user preference baked into their config can
            //     conflict with our explicit args (e.g. format
            //     selectors, output templates). Since StreamScribe
            //     specifies everything it needs on the command line,
            //     the user's config can only hurt our invocations.
            //
            //   - `--no-mark-watched`: skip the network round-trip
            //     that updates the user's watch history on the source
            //     platform (mainly YouTube). One less HTTP request
            //     per invocation. No-op on platforms without watch
            //     tracking.
            //
            // Applied to every yt-dlp invocation in StreamScribe.
            args.append(contentsOf: ["--ignore-config", "--no-mark-watched"])

            // Session-cached cookies: browser extraction on first
            // invocation, cheap jar reads after — see
            // ToolManager.sessionCookieArguments.
            args.append(contentsOf: ToolManager.shared.sessionCookieArguments(
                browserArg: tools.cookieBrowser.ytDlpArgument
            ))
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
                // bgutil PO-token provider (script-deno). Discovers Deno
                // via the --js-runtimes flag above. Empty until
                // PotProviderManager finishes provisioning, so appending
                // unconditionally is safe.
                args.append(contentsOf: PotProviderManager.shared.potArguments())
            }
            // YouTube player-client override (Settings). See
            // ToolManager.youtubePlayerClientArguments — web-family
            // client so the PO-token provider (WebPO-only) applies.
            args.append(contentsOf: ToolManager.youtubePlayerClientArguments())
            args.append(contentsOf: ToolManager.proxyArguments())
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
    private func streamViaYTDlpPipe(_ url: URL, source: StreamSource, ffmpegPath: String, isStaticSession: Bool) async throws -> Pipe {
        let sourceLabel = source.rawValue
        let tools = try await Self.resolveYTDlpTools()
        let hasCookies = tools.cookieBrowser.ytDlpArgument != nil

        // First attempt: --live-from-start with cookies (if configured).
        // This gives the best result (DVR replay from broadcast start)
        // but triggers the known yt-dlp bug on some YouTube live streams.
        //
        // STATIC SESSIONS DO NOT GET IT (2026-08-12). The flag means
        // "capture a LIVE stream from its beginning rather than the
        // live edge" — semantically meaningless for a VOD, which has
        // a beginning by definition. It was being passed
        // unconditionally, so every static yt-dlp session inherited a
        // live-oriented download mode. Field evidence: a 57s X VOD
        // delivered audio at a rock-steady 1.29-1.30x realtime for 40
        // seconds — the flat rate is the signature of media-timeline
        // PACING rather than congestion, and the same 39 MB asset
        // downloaded concurrently by the video cache finished ~8x
        // faster on the same link at the same moment, which rules out
        // bandwidth. Removing it for static costs nothing even if the
        // pacing turns out to have another cause.
        let firstPipe = try spawnYTDlpPipeProcess(
            url: url,
            source: source,
            sourceLabel: sourceLabel,
            ffmpegPath: ffmpegPath,
            tools: tools,
            isStaticSession: isStaticSession,
            useLiveFromStart: !isStaticSession,
            useCookies: true
        )

        // Wait for yt-dlp to either start producing output or die. The
        // timeout has to exceed cookie-extraction-prompt + webpage-fetch
        // + player-API-fetch time (~10-12s in practice for the failing
        // path), otherwise the slow-failing case gets treated as success.
        // Two extractor-specific phrasings of the same disease — a
        // live stream whose formats can't be fetched under the current
        // flags (--live-from-start chief among them):
        //   - YouTube:  "No video formats found!"
        //   - Twitter:  "--live-from-start is passed, but there are no
        //     formats that can be downloaded from the start" (2026-07-22
        //     field failure on a White House broadcast on X — yt-dlp's
        //     own error names the fix this retry already implements,
        //     but the pattern match only knew YouTube's wording, so
        //     the retry never fired).
        // The retry's YouTube-specific extras are harmless elsewhere:
        // player_client args are youtube-namespaced (other extractors
        // ignore them), and cookie-dropping is fine for public
        // broadcasts.
        let failedWithKnownBug = await waitForEarlyFailure(
            timeout: 20.0,
            errorPatterns: [
                "No video formats found",
                "no formats that can be downloaded from the start",
            ]
        )

        if failedWithKnownBug {
            // Which extractor's phrasing matched decides the retry's
            // shape (2026-07-22, White House broadcast on X): the
            // cookie-drop and default-client override are remedies for
            // YOUTUBE-specific failure modes. Applying them to a
            // twitter:broadcast retry is actively harmful — X is a
            // logged-in platform and its playlist fetches often
            // REQUIRE the browser cookies' auth, so the cookie-less
            // retry produced an empty pipe (ffmpeg: "Invalid data
            // found when processing input") after the flag fix let
            // the retry fire at all. Twitter-style failure keeps
            // cookies and the configured client args (which twitter
            // ignores anyway); only --live-from-start is dropped —
            // the one thing its error message actually asked for.
            let failureStderr = ytDlpStreamStderr.flatMap {
                String(data: $0.bytes, encoding: .utf8)
            } ?? ""
            let twitterStyleFailure = failureStderr.contains("no formats that can be downloaded from the start")

            if twitterStyleFailure {
                print("[Extractor] Live-from-start unsupported by this broadcast. Retrying from the live edge (cookies kept — this platform's playlists may require auth)…")
            } else {
                print("[Extractor] yt-dlp reported no formats. Retrying without --live-from-start\(hasCookies ? ", without cookies" : ""), and with yt-dlp's DEFAULT client selection…")
            }

            // Clean up the failed process (terminationHandler already
            // cleared ytDlpStreamProcess, but belt-and-suspenders).
            if let p = ytDlpStreamProcess, p.isRunning { p.terminate() }
            ytDlpStreamProcess = nil
            ytDlpStreamStderr = nil

            // Second attempt: no --live-from-start, no cookies, and —
            // critically (2026-07-22 field failure) — DEFAULT clients.
            // The player-client setting forces web_safari on every
            // invocation, and when YouTube grants that client no live
            // formats at all ("No video formats found!"), a retry that
            // re-forces the same client is a no-op — which is exactly
            // what this retry silently became the day the setting
            // shipped. yt-dlp's default multi-client selection means
            // ANY client currently granted live formats saves the
            // session; the PO-token provider still covers whichever
            // web-family clients appear in that set.
            let retryPipe = try spawnYTDlpPipeProcess(
                url: url,
                source: source,
                sourceLabel: sourceLabel,
                ffmpegPath: ffmpegPath,
                tools: tools,
                isStaticSession: isStaticSession,
                useLiveFromStart: false,
                useCookies: twitterStyleFailure,
                playerClientOverride: twitterStyleFailure ? nil : "default"
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
        isStaticSession: Bool,
        useLiveFromStart: Bool,
        useCookies: Bool,
        playerClientOverride: String? = nil
    ) throws -> Pipe {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tools.ytDlpPath)
        if let env = tools.childEnvironment {
            process.environment = env
        }

        var args: [String] = []
        // Warm-up speedups — see download-path comment for the
        // full explanation. Applied identically to keep yt-dlp's
        // startup behavior consistent across all StreamScribe
        // invocations.
        args.append(contentsOf: ["--ignore-config", "--no-mark-watched"])

        if useCookies {
            args.append(contentsOf: ToolManager.shared.sessionCookieArguments(
                browserArg: tools.cookieBrowser.ytDlpArgument
            ))
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
            // bgutil PO-token provider (script-deno). Discovers Deno
            // via the --js-runtimes flag above. Empty until
            // PotProviderManager finishes provisioning, so appending
            // unconditionally is safe.
            args.append(contentsOf: PotProviderManager.shared.potArguments())
        }
        // YouTube player-client override. Normally the Settings value
        // (see ToolManager.youtubePlayerClientArguments); during a
        // starvation escalation the watchdog passes an explicit
        // override to rotate away from the flagged client.
        if let override = playerClientOverride {
            args.append(contentsOf: ["--extractor-args", "youtube:player_client=\(override)"])
        } else {
            args.append(contentsOf: ToolManager.youtubePlayerClientArguments())
        }
        // User-configured proxy (sidebar). The in-app answer to
        // IP-level walls; empty = direct.
        args.append(contentsOf: ToolManager.proxyArguments())
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
        // SABR-era hardening (field failure 2026-07-17, video fijdz8IDEDc):
        // web clients can now offer NO classic premuxed format at all —
        // the only "muxed" entries are server-side (SSAP/SABR) formats
        // with unknown codecs (e.g. format 387, log signature "WARNING:
        // Unknown codec unknown" ×2). Those starve over plain HTTPS
        // fragment GETs even with a valid gvs PO token, and the bytes
        // that do arrive aren't a parseable container (ffmpeg: "error
        // reading header"). The bare `best[height<=480]` alternative
        // ranked 387 above everything, so:
        //   - every generic alternative now excludes unknown codecs
        //     ([vcodec!*=unknown] also drops codec-less entries — a
        //     missing field fails the filter without the `?` suffix);
        //   - when no usable muxed format exists, degrade to AUDIO-ONLY
        //     rather than failing the session: transcription is the
        //     mission, and the ffmpeg cache output's `-map 0:v?`
        //     (optional map) writes a valid audio-only mp4 for the
        //     miniplayer. The real fix for video-with-no-premuxed is
        //     the split-stream design (separate audio pipe + video
        //     download) — queued, not built.
        // `/best` stays as the absolute last resort for non-YouTube
        // sources routed through this pipe (Senate fallback etc.) whose
        // format lists don't play by YouTube's rules.
        // SPLIT-STREAM (2026-07): static sessions NEVER ask the pipe
        // for video. Transcription needs audio; demanding a muxed
        // format for stdout was what kept steering selection into
        // SABR fake-muxed junk (the format-387 class). Miniplayer
        // video for static sessions comes from VideoCacheDownloader's
        // separate bv*+ba file download instead — the shape that
        // works on every source. The `/best` tail still matters:
        // progressive-only sources (Fox/CNBC single mp4) have no
        // separate audio format, and a video-bearing pipe is harmless
        // — ffmpeg maps the audio; the extra bytes are the cost.
        // Live sessions keep the muxed-preference chain: livestream
        // HLS muxed formats remain broadly available, and a live
        // session can't wait for a file download to finish.
        let audioFirstSelector = "bestaudio[acodec*=mp4a]/bestaudio[ext=m4a]/bestaudio[acodec!*=unknown]/best[vcodec!*=unknown]/best"
        let liveFormatSelector: String
        if isStaticSession {
            liveFormatSelector = audioFirstSelector
        } else {
            liveFormatSelector = wantsVideoInCacheFlag
                ? "best[height<=480][vcodec*=avc]/best[height<=480][ext=mp4]/best[height<=480][vcodec!*=unknown]/bestaudio[acodec*=mp4a]/bestaudio[ext=m4a]/bestaudio[acodec!*=unknown]/best"
                : audioFirstSelector
        }
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
            "--http-chunk-size", "10M",
            "--no-part",
            "--no-warnings",
            "--ffmpeg-location", ffmpegPath,
            "--hls-use-mpegts",
            "--paths", "temp:\(fragmentScratchDir)",
        ])
        if isStaticSession {
            // Static/VOD over the pipe path. REGRESSION GUARD: the
            // live-edge hardening below must NOT apply here. When it
            // did (previous session applied it unconditionally to this
            // shared function), VOD downloads inherited a 10s stall
            // tolerance + infinite retries: throttled googlevideo VOD
            // reads routinely stall past 10s, so downloads collapsed
            // into an endless "Read timed out. Retrying (1/inf)"
            // livelock — field failure 2026-07, broke static mode
            // app-wide. This branch restores the pre-hardening pipe
            // args verbatim: -N 8 parallel fragments, yt-dlp default
            // socket timeout (~20s) and finite default retries (10).
            args.append(contentsOf: [
                "-N", "8",
            ])
        } else {
            args.append(contentsOf: [
                // -N 1 for live: 8 concurrent fragment connections gain
                // little at the live edge (fragments arrive in real time
                // anyway) and corporate proxies choke on the connection
                // fan-out — a contributor to per-fragment stalls.
                "-N", "1",
                // Live-edge CDN hardening. googlevideo fragment servers
                // stall routinely on live streams (field failure: "Read
                // timed out. Retrying (1/10)…" starving the pipe with no
                // output). Three levers:
                //   --socket-timeout 30 (RETUNED 2026-07-21): the
                //     original 10s was designed to fail over to a
                //     different CDN node quickly — but field evidence
                //     (log 15:28, rock-steady 0.32x) showed retries hit
                //     the SAME node, and per-segment the cycle became
                //     mechanical: ~5s live segments served after a
                //     ~10-15s hold, our 10s timeout aborting each first
                //     request, +5s retry-sleep = 15s per 5s segment =
                //     the observed 0.33x. The timeout was MANUFACTURING
                //     the throttle. 30s lets a held-but-alive request
                //     complete; a truly dead node costs 30s once, then
                //     the 1s sleep recycles fast.
                //   infinite retries: a live session should ride out
                //     CDN turbulence indefinitely rather than dying at
                //     attempt 10.
                //   --retry-sleep 1 (was 5): with the long socket
                //     timeout doing the waiting, the sleep's only job
                //     is to avoid hammering; 1s suffices and stops
                //     adding dead time to every recovery.
                //   --force-ipv4: the classic fix for chronically
                //     stalling rr*---sn-* googlevideo nodes, which are
                //     disproportionately flaky over IPv6 routes.
                // LIVE-ONLY: see the static branch above for why these
                // must never leak into VOD sessions.
                "--socket-timeout", "30",
                "--retries", "infinite",
                "--fragment-retries", "infinite",
                "--retry-sleep", "1",
                "--force-ipv4",
            ])
        }
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

        // Defense-in-depth against the read-only-filesystem fragment
        // write bug. `--paths temp:<dir>` above should redirect all
        // fragment scratch I/O, but yt-dlp's path-category handling
        // has edge cases — newer versions categorize some HLS writes
        // differently, and a small subset of streams use code paths
        // that bypass `--paths` and fall back to writing relative-
        // path files in the process CWD.
        //
        // When a .app bundle is launched from Finder, its CWD is `/`
        // — the SIP-protected read-only system volume. Any relative-
        // path write yt-dlp attempts hits EROFS and the whole stream
        // fails with `unable to open for writing: [Errno 30] Read-
        // only file system: '--Frag76'` (where the `--` prefix comes
        // from yt-dlp's `<basename>-Frag<N>` naming convention with
        // `-o -` making the basename literal `-`).
        //
        // Setting `currentDirectoryURL` to the scratch dir ensures
        // any relative-path write lands somewhere writable regardless
        // of yt-dlp's `--paths` handling. Harmless when `--paths`
        // works correctly (all writes use absolute paths anyway);
        // saves the session when it doesn't.
        process.currentDirectoryURL = URL(fileURLWithPath: fragmentScratchDir)

        // Accumulate stderr into a buffer so the retry logic can inspect
        // it for the known error pattern after the process exits. Also
        // log each line for debug visibility.
        let stderrBuffer = MutableByteBuffer()
        let counter403 = Error403Counter()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrBuffer.bytes.append(data)
            if let text = String(data: data, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    print("[yt-dlp stderr] \(trimmed)")
                }
                // Bot-wall circuit breaker. Match loosely — the
                // apostrophe in "you're" arrives as a Unicode
                // right-quote from yt-dlp.
                if text.contains("Sign in to confirm") {
                    Task { [weak self] in await self?.handleBotWall() }
                }
                // 403-storm fast escalation: fragment URLs this
                // config cannot authorize announce themselves
                // immediately and repeatedly — don't wait out a
                // starvation window on them.
                if text.contains("HTTP error 403") {
                    counter403.lock.lock()
                    counter403.count += 1
                    let hit = counter403.count == 6  // fire exactly once
                    counter403.lock.unlock()
                    if hit {
                        Task { [weak self] in await self?.handle403Storm(from: counter403) }
                    }
                }
            }
        }
        self.ytDlpStreamStderr = stderrBuffer
        self.current403Counter = counter403

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
    /// AND its stderr contains any of `errorPatterns`. Returns false if the
    /// process is still running after the timeout (success — it's
    /// streaming audio) or if it exited for a different reason.
    /// Wait up to `timeout` seconds for the current `ytDlpStreamProcess`
    /// to either:
    ///   - exit with a non-zero code AND stderr matches any of `errorPatterns` → returns true (failure, retry)
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
    private func waitForEarlyFailure(timeout: TimeInterval, errorPatterns: [String]) async -> Bool {
        func matchesAny(_ stderr: String) -> Bool {
            errorPatterns.contains { stderr.contains($0) }
        }
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
                if proc.terminationStatus != 0 && matchesAny(stderr) {
                    return true
                }
                return false
            }
            if ytDlpStreamProcess == nil {
                print("[Extractor] yt-dlp process pointer cleared, stderr length: \(stderr.count) bytes")
                return matchesAny(stderr)
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
            args.append(contentsOf: ToolManager.shared.sessionCookieArguments(
                browserArg: tools.cookieBrowser.ytDlpArgument
            ))
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
                // bgutil PO-token provider (script-deno). Discovers Deno
                // via the --js-runtimes flag above. Empty until
                // PotProviderManager finishes provisioning, so appending
                // unconditionally is safe.
                args.append(contentsOf: PotProviderManager.shared.potArguments())
            }
            // YouTube player-client override (Settings). See
            // ToolManager.youtubePlayerClientArguments — web-family
            // client so the PO-token provider (WebPO-only) applies.
            args.append(contentsOf: ToolManager.youtubePlayerClientArguments())
            args.append(contentsOf: ToolManager.proxyArguments())
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
    /// Resolve everything yt-dlp needs to launch: binary path, optional
    /// deno path (for YouTube n-param challenges), cookie browser
    /// config, TLS-check override, and the child environment for SSL
    /// cert overrides. Internal so adjacent services (like
    /// `VideoDownloadService` for the standalone video-download button)
    /// can reuse the same resolution rather than duplicating cookie/
    /// TLS/env logic.
    static func resolveYTDlpTools() async throws -> (
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
    /// Internal so adjacent services (VideoDownloadService, etc.) can share
    /// the same resolution logic instead of duplicating the PATH scan.
    static func requireFFmpegPath() throws -> String {
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
