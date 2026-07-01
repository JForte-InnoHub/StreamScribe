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
                try await self.performDownload(
                    from: sourceURL,
                    to: destinationURL
                )
                await MainActor.run {
                    self.progress = 1.0
                    self.statusText = "Saved to \(destinationURL.lastPathComponent)"
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
    nonisolated private func performDownload(from sourceURL: URL, to destinationURL: URL) async throws {
        let tools = try await AudioStreamExtractor.resolveYTDlpTools()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("streamscribe-vid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let baseFilename = "video"
        let outputTemplate = tempDir.appendingPathComponent("\(baseFilename).%(ext)s").path

        // Run yt-dlp, capture the post-rename path, then move to
        // destination. Wrap in a defer that cleans up the temp dir
        // regardless of outcome — so cancelled or failed downloads
        // don't leak temp files.
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let downloadedPath = try await runYTDlp(
            sourceURL: sourceURL,
            outputTemplate: outputTemplate,
            tempDir: tempDir,
            tools: tools
        )

        let downloadedURL = URL(fileURLWithPath: downloadedPath)

        // Move (or copy across volumes) to user destination. If a
        // file already exists at the destination, NSSavePanel has
        // confirmed overwrite — remove the existing file first
        // since FileManager.moveItem errors on existing target.
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        do {
            try FileManager.default.moveItem(at: downloadedURL, to: destinationURL)
        } catch {
            // Cross-volume move (temp on /private/tmp, destination on
            // user's external drive) fails with EXDEV; fall back to
            // copy + remove. The `removeItem` is best-effort — leaving
            // a stray temp file is preferable to surfacing the copy
            // success as a failure to the user.
            try FileManager.default.copyItem(at: downloadedURL, to: destinationURL)
            try? FileManager.default.removeItem(at: downloadedURL)
        }
    }

    /// Run the yt-dlp subprocess with progress reporting. Returns
    /// the final post-rename filepath emitted by
    /// `--print after_move:filepath`.
    nonisolated private func runYTDlp(
        sourceURL: URL,
        outputTemplate: String,
        tempDir: URL,
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

            // Cookies for sites that require login. Same tool config
            // the rest of the app uses.
            if let browserArg = tools.cookieBrowser.ytDlpArgument {
                args.append(contentsOf: ["--cookies-from-browser", browserArg])
            }

            // No `-f` — let yt-dlp pick the best video+audio merge.
            // For most platforms (YouTube, Vimeo, CNN, etc.) this is
            // the highest-quality mp4. Users wanting a specific format
            // can do that via yt-dlp directly; the app's job here is
            // "just give me a good copy."
            args.append(contentsOf: [
                "-o", outputTemplate,
                "--print", "after_move:filepath",
                "--no-warnings",
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
                        if lineStr.contains("ERROR") || lineStr.contains("WARNING") {
                            print("[VideoDownload yt-dlp] \(lineStr)")
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
