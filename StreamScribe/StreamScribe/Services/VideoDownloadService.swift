import Foundation
import Combine

/// Stand-alone video downloader. Drives a one-off yt-dlp invocation
/// against a URL the user has pasted into the URL field, writing the
/// result to a destination they pick via NSSavePanel.
///
/// **Why a service rather than reusing `AudioStreamExtractor`.**
/// `AudioStreamExtractor.downloadViaYTDlp` is the transcription
/// pipeline's audio downloader — it's tied to ffmpeg piping, audio
/// format selection, and the session lifecycle. A standalone video
/// download wants none of that. It's a single yt-dlp call that picks
/// best-video+best-audio, writes to disk, and exits. Sharing the audio
/// path would muddy both code paths; the duplication here is small
/// (~80 lines) and keeps the audio pipeline unaffected by feature
/// additions on the video side.
///
/// **Why a singleton.** Single download in flight at a time — the
/// concurrent-downloads scenario isn't useful (user picks one URL,
/// downloads it, then picks another). Singleton mirrors the pattern
/// used by VoiceprintService and NotificationService.
///
/// **Why an ObservableObject.** Progress + status need to flow to
/// SwiftUI for inline UI feedback. The class publishes
/// `isDownloading`, `progress`, `statusText`, and `lastError` so the
/// sidebar can render a "Downloading… 42%" indicator and surface
/// failures inline rather than via console-only logs.
@MainActor
final class VideoDownloadService: ObservableObject {

    static let shared = VideoDownloadService()

    /// True while a download is in progress. Drives the disabled
    /// state of the download button (prevents re-triggering mid-
    /// download) and the visibility of progress UI.
    @Published private(set) var isDownloading: Bool = false

    /// Download progress as a 0.0...1.0 fraction. yt-dlp reports this
    /// in its `[download] NN.N% of SIZE at RATE` stderr lines; we
    /// parse and publish. May briefly read 0 at the start before the
    /// first progress line and 1.0 at the end before
    /// `isDownloading` flips off.
    @Published private(set) var progress: Double = 0

    /// Human-readable status: "Starting…", "Downloading… 42%",
    /// "Saved to MyVideo.mp4", "Cancelled", "Failed: …". The sidebar
    /// renders this directly. Stays populated after the download
    /// completes so the user sees the outcome until they dismiss it
    /// (which clears via `clearStatus()`).
    @Published private(set) var statusText: String = ""

    /// Last error message, if the download failed. Nil during a
    /// successful download or while one is in progress. The sidebar
    /// surfaces this distinctly (color coding) so failures stand out
    /// from neutral status text.
    @Published private(set) var lastError: String?

    /// The actively-running download task. Used to support cancel().
    /// nil when no download is in flight.
    private var currentTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    /// Begin a download from `sourceURL` to `destinationURL`. Fire-
    /// and-forget — progress flows through the published properties.
    /// If a download is already in progress, this is a no-op (the UI
    /// should disable the trigger button via `isDownloading`, but the
    /// guard is defensive).
    func downloadVideo(from sourceURL: URL, to destinationURL: URL) {
        guard !isDownloading else { return }
        isDownloading = true
        progress = 0
        statusText = "Starting download…"
        lastError = nil

        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let savedURL = try await self.performDownload(
                    from: sourceURL,
                    to: destinationURL
                )
                await MainActor.run {
                    self.progress = 1.0
                    self.statusText = "Saved to \(savedURL.lastPathComponent)"
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.statusText = "Cancelled"
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self.lastError = message
                    self.statusText = "Failed"
                }
                print("[VideoDownload] Failed: \(error)")
            }
            await MainActor.run {
                self.isDownloading = false
                self.currentTask = nil
            }
        }
    }

    /// Cancel the in-flight download. Yt-dlp gets a SIGTERM and
    /// teardown proceeds; partial files are removed in
    /// `performDownload`'s cleanup. No-op when nothing is downloading.
    func cancel() {
        currentTask?.cancel()
    }

    /// Clear the displayed status. Called from the UI when the user
    /// dismisses a completed-download status row, so the next
    /// download starts with a fresh slate.
    func clearStatus() {
        guard !isDownloading else { return }
        statusText = ""
        lastError = nil
        progress = 0
    }

    // MARK: - Implementation

    /// The actual yt-dlp invocation. Runs nonisolated (off the main
    /// actor) since it spawns a process and waits — same pattern as
    /// `AudioStreamExtractor.downloadViaYTDlp`.
    ///
    /// **Format selection.** We let yt-dlp pick its default best-quality
    /// merge (`bestvideo+bestaudio/best`, which yt-dlp uses when no
    /// `-f` is specified). This produces an mp4 or mkv depending on
    /// what the source platform offers. The user picks the destination
    /// filename + extension; if yt-dlp's chosen container doesn't
    /// match the user's extension, we move-as-renamed and accept the
    /// minor mismatch.
    ///
    /// **Why move-from-temp rather than write directly.** yt-dlp's
    /// output template uses `%(ext)s` to pick its own extension based
    /// on the format. We don't know that extension up front, but we
    /// DO know where the user wants the file. So we let yt-dlp write
    /// to a temp dir with `%(ext)s` substitution, capture the final
    /// path via `--print after_move:filepath`, and then move that
    /// file to the user's chosen destination. Same idiom as the
    /// audio path.
    /// Returns the URL the file was ACTUALLY saved to — which can
    /// differ from `destinationURL` by extension: audio-only sources
    /// are delivered as .mp3 (2026-07-22 user request; podcast-class
    /// content saved as an audio-only .mp4 confused every downstream
    /// tool).
    @discardableResult
    nonisolated private func performDownload(from sourceURL: URL, to destinationURL: URL) async throws -> URL {
        // Route by source type. yt-dlp is the workhorse for most
        // platforms (YouTube, Twitter, Instagram, Threads, etc.)
        // because it handles their platform-specific format
        // negotiation and JS challenges. Critical Mention doesn't
        // have a yt-dlp extractor — we resolve it via our own
        // WebKit-based extractor and download the HLS stream
        // directly via ffmpeg, mirroring the transcription path's
        // approach.
        let ffmpegPath = try AudioStreamExtractor.requireFFmpegPath()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("streamscribe-vid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let source = StreamSource.detect(from: sourceURL)
        let downloadedPath: String

        if source == .criticalMention || source == .granicus {
            // Browser-extractor flow (Critical Mention + Granicus):
            // resolve the player page → HLS URL → ffmpeg copies the
            // stream to disk. ffmpeg reads the m3u8, downloads
            // segments in order, and remuxes to mp4 without
            // re-encoding — same bit-exact copy semantics as yt-dlp
            // would provide, but via a path that doesn't depend on
            // yt-dlp knowing about the source.
            await MainActor.run {
                self.statusText = source == .granicus
                    ? "Resolving Granicus stream…"
                    : "Resolving Critical Mention clip…"
            }
            let resolved = try await CriticalMentionExtractor.resolve(url: sourceURL)
            downloadedPath = try await runFFmpegHLSDownload(
                streamURL: resolved.m3u8URL,
                tempDir: tempDir,
                ffmpegPath: ffmpegPath
            )
        } else if source == .hls {
            // Bare HLS URL (2026-07-29 user request): the URL IS the
            // m3u8 — no page resolution needed. Same ffmpeg segment-
            // concatenate-and-remux path the Critical Mention/Granicus
            // flows use. The download button only appears for HLS once
            // the probe has confirmed the playlist is finite (VOD), so
            // a live stream that never terminates won't reach here.
            await MainActor.run { self.statusText = "Downloading HLS stream…" }
            downloadedPath = try await runFFmpegHLSDownload(
                streamURL: sourceURL,
                tempDir: tempDir,
                ffmpegPath: ffmpegPath
            )
        } else {
            // yt-dlp flow for all other sources.
            let tools = try await AudioStreamExtractor.resolveYTDlpTools()
            let outputTemplate = tempDir.appendingPathComponent("video.%(ext)s").path
            downloadedPath = try await runYTDlp(
                sourceURL: sourceURL,
                outputTemplate: outputTemplate,
                tempDir: tempDir,
                ffmpegPath: ffmpegPath,
                tools: tools
            )
        }

        var downloadedURL = URL(fileURLWithPath: downloadedPath)

        // AUDIO-ONLY → MP3 (2026-07-22 user request): podcast-class
        // sources have no real video, and delivering them as an
        // audio-only .mp4 confuses downstream tools. Detection uses
        // the same attached-picture-aware capital-V selector as the
        // broken-pipe fix (cover art must not count as video). On any
        // failure the original container is delivered — this stage
        // must never turn a successful download into an error.
        var effectiveDestination = destinationURL
        if let mp3URL = Self.convertToMP3IfAudioOnly(downloadedURL: downloadedURL, ffmpegPath: ffmpegPath) {
            downloadedURL = mp3URL
            effectiveDestination = destinationURL
                .deletingPathExtension()
                .appendingPathExtension("mp3")
        }

        // Move (or copy across volumes) to user destination. If a
        // file already exists at the destination, NSSavePanel has
        // confirmed overwrite — remove the existing file first
        // since FileManager.moveItem errors on existing target.
        // (For an mp3 delivery the extension changed AFTER the save
        // panel, so an existing file at the .mp3 path gets the same
        // overwrite treatment.)
        if FileManager.default.fileExists(atPath: effectiveDestination.path) {
            try FileManager.default.removeItem(at: effectiveDestination)
        }
        do {
            try FileManager.default.moveItem(at: downloadedURL, to: effectiveDestination)
        } catch {
            // Cross-volume move (temp on /private/tmp, destination on
            // user's external drive) fails with EXDEV; fall back to
            // copy + remove. The `removeItem` is best-effort — leaving
            // a stray temp file is preferable to surfacing the copy
            // success as a failure to the user.
            try FileManager.default.copyItem(at: downloadedURL, to: effectiveDestination)
            try? FileManager.default.removeItem(at: downloadedURL)
        }
        return effectiveDestination
    }

    /// If `downloadedURL` has no REAL video stream (attached-picture
    /// cover art excluded via the `0:V` selector), return an .mp3 to
    /// deliver instead: the file itself when it's already MP3, or a
    /// libmp3lame V2 conversion (transparent for speech). Returns nil
    /// when the file has video OR when anything fails — the caller
    /// then delivers the original container unchanged.
    nonisolated private static func convertToMP3IfAudioOnly(downloadedURL: URL, ffmpegPath: String) -> URL? {
        func runFFmpeg(_ arguments: [String]) -> Int32 {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpegPath)
            proc.arguments = arguments
            proc.standardOutput = Pipe(); proc.standardError = Pipe()
            do { try proc.run() } catch { return -1 }
            proc.waitUntilExit()
            return proc.terminationStatus
        }

        // Real-video probe: decode at most one frame from the first
        // NON-attached-picture video stream. Audio-only files fail the
        // map instantly; real video succeeds in milliseconds.
        let probeStatus = runFFmpeg([
            "-v", "error",
            "-i", downloadedURL.path,
            "-map", "0:V:0",
            "-frames:v", "1",
            "-f", "null", "-",
        ])
        guard probeStatus != 0 else { return nil }  // has real video

        if downloadedURL.pathExtension.lowercased() == "mp3" {
            // Podcast feeds commonly serve native MP3 — yt-dlp already
            // saved it with the right extension; nothing to convert.
            return downloadedURL
        }

        let mp3URL = downloadedURL.deletingPathExtension().appendingPathExtension("mp3")
        if mp3URL != downloadedURL {
            try? FileManager.default.removeItem(at: mp3URL)
        }
        let convertStatus = runFFmpeg([
            "-v", "error",
            "-i", downloadedURL.path,
            "-vn",
            "-c:a", "libmp3lame",
            "-q:a", "2",
            mp3URL.path,
        ])
        guard convertStatus == 0, FileManager.default.fileExists(atPath: mp3URL.path) else {
            print("[Download] Audio-only source detected but MP3 conversion failed — delivering the original container.")
            try? FileManager.default.removeItem(at: mp3URL)
            return nil
        }
        try? FileManager.default.removeItem(at: downloadedURL)
        print("[Download] Audio-only source — delivered as MP3.")
        return mp3URL
    }

    /// Download an HLS stream via ffmpeg. Used for Critical Mention
    /// clips (and potentially any other future source whose stream
    /// URL we know but yt-dlp doesn't handle). Emits mp4 with copied
    /// codecs — no re-encoding, so the resulting file is bit-identical
    /// to what the CDN served, just remuxed to a container that plays
    /// in QuickTime and other standard apps.
    ///
    /// **Progress reporting.** ffmpeg's stderr emits `time=HH:MM:SS.mm`
    /// lines during processing. We parse those and divide by the
    /// total duration (probed from the m3u8 manifest) to derive a
    /// fraction. Without a known total we can't display a percentage
    /// — the status stays at "Downloading…" until completion.
    nonisolated private func runFFmpegHLSDownload(
        streamURL: URL,
        tempDir: URL,
        ffmpegPath: String
    ) async throws -> String {
        let outputPath = tempDir.appendingPathComponent("video.mp4").path

        // Optionally probe total duration up front so we can compute
        // progress percentages. If the probe fails, we still proceed
        // — the download works either way, just without a % display.
        let totalDurationSeconds: Double? = await {
            let result = await TranscriptionEngine.probeRemoteDurationViaFFmpeg(url: streamURL)
            if case .finite(let s) = result { return s }
            return nil
        }()

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let process = Process()
            let errPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.currentDirectoryURL = tempDir

            // ffmpeg args:
            //   -i <url>           input HLS manifest
            //   -c copy            no re-encoding; remux codecs as-is
            //   -bsf:a aac_adtstoasc  ADTS → ASC audio bitstream conversion,
            //                        needed when muxing AAC into mp4
            //                        (HLS commonly delivers AAC as ADTS)
            //   -y                 overwrite output without prompting
            //   -progress pipe:2   emit machine-readable progress to stderr
            //   -nostats           suppress the human-readable progress
            //                     (would interleave with -progress output)
            //   -loglevel warning  quiet the info-level chatter but keep
            //                     warnings + errors
            process.arguments = [
                "-i", streamURL.absoluteString,
                "-c", "copy",
                "-bsf:a", "aac_adtstoasc",
                "-y",
                "-progress", "pipe:2",
                "-nostats",
                "-loglevel", "warning",
                outputPath
            ]

            process.standardOutput = FileHandle.nullDevice
            process.standardError = errPipe

            // Parse `out_time_ms=N` progress lines to update
            // percentage. `-progress pipe:2` emits key=value pairs
            // one per line; `out_time_ms` is the current position in
            // microseconds (not millis, despite the name — ffmpeg's
            // naming is historical).
            errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let text = String(data: data, encoding: .utf8) else {
                    return
                }
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    let lineStr = String(line).trimmingCharacters(in: .whitespaces)
                    if lineStr.hasPrefix("out_time_ms=") {
                        let value = lineStr.dropFirst("out_time_ms=".count)
                        if let microseconds = Double(value), microseconds > 0 {
                            let currentSeconds = microseconds / 1_000_000
                            if let total = totalDurationSeconds, total > 0 {
                                let fraction = min(1.0, currentSeconds / total)
                                Task { @MainActor [weak self] in
                                    self?.progress = fraction
                                    self?.statusText = "Downloading… \(Int(fraction * 100))%"
                                }
                            } else {
                                let mmss = String(
                                    format: "%d:%02d",
                                    Int(currentSeconds) / 60,
                                    Int(currentSeconds) % 60
                                )
                                Task { @MainActor [weak self] in
                                    self?.statusText = "Downloading… \(mmss)"
                                }
                            }
                        }
                    } else if !lineStr.isEmpty {
                        // Warnings + errors that made it through
                        // -loglevel warning. Log for diagnosis.
                        print("[VideoDownload ffmpeg] \(lineStr)")
                    }
                }
            }

            process.terminationHandler = { proc in
                errPipe.fileHandleForReading.readabilityHandler = nil
                let exitStatus = proc.terminationStatus
                if proc.terminationReason == .uncaughtSignal {
                    cont.resume(throwing: CancellationError())
                    return
                }
                guard exitStatus == 0 else {
                    let errText = String(
                        data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                    cont.resume(throwing: NSError(
                        domain: "VideoDownload",
                        code: Int(exitStatus),
                        userInfo: [NSLocalizedDescriptionKey: "ffmpeg exited with code \(exitStatus): \(errText)"]
                    ))
                    return
                }
                cont.resume(returning: outputPath)
            }

            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
                return
            }

            // Cancellation → SIGTERM ffmpeg. Same polling pattern as
            // the yt-dlp path.
            Task {
                while process.isRunning {
                    if Task.isCancelled {
                        process.terminate()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
    }

    /// Run the yt-dlp subprocess with progress reporting. Returns
    /// the final post-rename filepath emitted by
    /// `--print after_move:filepath`.
    nonisolated private func runYTDlp(
        sourceURL: URL,
        outputTemplate: String,
        tempDir: URL,
        ffmpegPath: String,
        tools: (ytDlpPath: String, denoPath: String?, cookieBrowser: CookieBrowser, disableTLSCheck: Bool, childEnvironment: [String: String]?)
    ) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let process = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: tools.ytDlpPath)
            if let env = tools.childEnvironment {
                process.environment = env
            }
            // EROFS guard — see the corresponding defense in
            // AudioStreamExtractor.swift for the full explanation.
            // App launched from Finder has CWD = `/` (read-only);
            // any relative-path write by yt-dlp would fail.
            process.currentDirectoryURL = tempDir

            var args: [String] = []
            args.append(contentsOf: ["--ignore-config", "--no-mark-watched"])

            // JavaScript runtime for YouTube's n-parameter challenge.
            // YouTube runs an obfuscated JS decryption on video URL
            // parameters; without a JS runtime, yt-dlp emits the
            // "n challenge solving failed: Some formats may be
            // missing" warning and skips the formats that need
            // decryption. Which is often ALL of them, producing
            // "Requested format is not available" downstream.
            //
            // Passing `--js-runtimes deno:<path>` gives yt-dlp a
            // sandboxed JavaScript engine to run the challenge in.
            // ToolManager provides the deno binary on demand; if
            // it's not installed, we omit the flag and yt-dlp falls
            // back to whatever it can find on PATH (typically
            // nothing on a packaged .app), producing the warning
            // the user reported.
            //
            // Mirrors the setup in AudioStreamExtractor's download
            // path — same tools tuple, same flag, same behavior.
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

            // Cookies for sites that require login. Session-cached —
            // browser extraction on first invocation, cheap jar reads
            // after. See ToolManager.sessionCookieArguments.
            args.append(contentsOf: ToolManager.shared.sessionCookieArguments(
                browserArg: tools.cookieBrowser.ytDlpArgument
            ))

            // **Format selector rationale (revised).** Original chain
            // (`bv*+ba/best/…`) prioritized the video+audio merge
            // (needs ffmpeg) as the primary tier. In practice, some
            // YouTube videos have separated formats where `bv*+ba`
            // parses correctly but the fallback logic doesn't kick in
            // properly — yt-dlp reports "requested format is not
            // available" even when a plain `best` single-file DOES
            // exist. Reordering to try single-file FIRST sidesteps
            // this: yt-dlp evaluates against the actual format list
            // and finds a match on tier 1 for the common case.
            //
            //   1. `best` — best single-file with combined video+audio.
            //      Works without ffmpeg. Most compatible. Gives ~360p
            //      on YouTube (the highest quality that's still
            //      shipped as a combined single file) — but reliably.
            //   2. `bv*+ba` — best video + best audio, merged via
            //      ffmpeg. HD content. Fires when tier 1 has no
            //      single-file combined format (some past-broadcast
            //      livestreams, some DASH-only uploads).
            //   3. `bv*` — best video-only. Video without audio;
            //      better than failing outright.
            //   4. `wv*` — worst video-only. Guarantees we return
            //      SOMETHING for videos with restrictive format
            //      access.
            //   5. `w` — worst overall. Absolute last resort.
            //
            // **`--ffmpeg-location` still passed.** Tier 2 (merge)
            // needs it; keeping it always-on so tier 2 works when
            // tier 1 falls through.
            //
            // **`--no-warnings` removed.** The original suppressed
            // useful diagnostic output. yt-dlp warnings now flow to
            // the log, where the user (or the diagnostic assistant)
            // can see WHY a specific format request failed. The
            // progress line parser skips warnings — they don't
            // interfere with progress display.
            args.append(contentsOf: [
                "--ffmpeg-location", ffmpegPath,
                // [vcodec!*=unknown] on the muxed tier: keeps the
                // SABR-era unknown-codec formats (e.g. 387) from
                // outranking a real bv*+ba merge — same field failure
                // as the pipe path, see AudioStreamExtractor's
                // liveFormatSelector comment (2026-07-17).
                "-f", "best[vcodec!*=unknown]/bv*+ba/bv*/wv*/w",
                "-o", outputTemplate,
                "--print", "after_move:filepath",
                "--newline",   // progress lines on their own lines, easier to parse
                sourceURL.absoluteString
            ])
            process.arguments = args

            process.standardOutput = outPipe
            process.standardError = errPipe

            // Parse stderr for progress lines. yt-dlp emits lines like:
            //   [download]  42.3% of 123.45MiB at 1.23MiB/s ETA 00:42
            // The percentage is what we want. We use a simple regex
            // and update the published progress whenever a match
            // arrives. Errors and other stderr noise are passed
            // through to console for debugging.
            let progressRegex = try! NSRegularExpression(
                pattern: #"\[download\]\s+(\d+\.\d+)%"#
            )

            errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let text = String(data: data, encoding: .utf8) else {
                    return
                }
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    let lineStr = String(line)
                    let range = NSRange(lineStr.startIndex..., in: lineStr)
                    if let match = progressRegex.firstMatch(in: lineStr, range: range),
                       let pctRange = Range(match.range(at: 1), in: lineStr),
                       let pct = Double(lineStr[pctRange]) {
                        let fraction = pct / 100.0
                        Task { @MainActor [weak self] in
                            self?.progress = fraction
                            self?.statusText = "Downloading… \(Int(pct))%"
                        }
                    } else {
                        // Non-progress stderr line — log for debug.
                        // Previously we filtered to ERROR/WARNING but
                        // that hid useful information (available-
                        // formats hints, extractor negotiation, etc.).
                        // Logging everything makes format failures
                        // debuggable; the small volume during a normal
                        // download is acceptable.
                        let stripped = lineStr.trimmingCharacters(in: .whitespaces)
                        if !stripped.isEmpty {
                            print("[VideoDownload yt-dlp] \(stripped)")
                        }
                    }
                }
            }

            // Captured filepath from --print after_move:filepath.
            // Accumulated across stdout reads since yt-dlp may chunk
            // the output.
            var stdoutBuffer = Data()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stdoutBuffer.append(data)
            }

            process.terminationHandler = { proc in
                // Stop reading.
                errPipe.fileHandleForReading.readabilityHandler = nil
                outPipe.fileHandleForReading.readabilityHandler = nil

                let exitStatus = proc.terminationStatus
                if proc.terminationReason == .uncaughtSignal {
                    // SIGTERM from cancel() — surface as cancellation
                    cont.resume(throwing: CancellationError())
                    return
                }
                guard exitStatus == 0 else {
                    let errText = String(
                        data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                    cont.resume(throwing: NSError(
                        domain: "VideoDownload",
                        code: Int(exitStatus),
                        userInfo: [NSLocalizedDescriptionKey: "yt-dlp exited with code \(exitStatus): \(errText)"]
                    ))
                    return
                }

                // Drain any remaining stdout.
                stdoutBuffer.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                guard let stdoutText = String(data: stdoutBuffer, encoding: .utf8) else {
                    cont.resume(throwing: NSError(
                        domain: "VideoDownload",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "yt-dlp output not UTF-8"]
                    ))
                    return
                }

                // `--print after_move:filepath` emits the final path
                // (one per matched download — there should be one). If
                // there are multiple lines, the last non-empty one is
                // the most recent post-rename path.
                let candidate = stdoutText
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .last
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

                guard let path = candidate, !path.isEmpty else {
                    cont.resume(throwing: NSError(
                        domain: "VideoDownload",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "yt-dlp didn't report a final filepath"]
                    ))
                    return
                }

                cont.resume(returning: path)
            }

            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
                return
            }

            // Wire cancellation to SIGTERM. The Task wrapping this
            // continuation already calls `Task.cancel()`; we observe
            // that via withTaskCancellationHandler at the caller.
            // Here we attach the signal-handler poll loop to the same
            // Task — checking periodically and signalling yt-dlp.
            Task {
                while process.isRunning {
                    if Task.isCancelled {
                        process.terminate()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                }
            }
        }
    }
}
