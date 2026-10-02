import Foundation

/// UserDefaults key for the "cache video in addition to audio" preference.
/// Defined at module scope (not nested in the enum) so SwiftUI's
/// `@AppStorage` can reference it from views without a type-name dance.
/// Default semantics: `true` if the key isn't set, since most users want
/// video for speaker identification — the setting is the opt-out for
/// users on bandwidth-constrained connections or worried about disk use.
let mediaCacheIncludeVideoKey = "playback.cacheVideo"
let mediaCacheIncludeVideoDefault = true

/// Owns the on-disk cache file that backs the miniplayer for non-local-file
/// transcriptions. The actual writing is done by the ffmpeg invocation in
/// `AudioStreamExtractor.spawnFFmpeg` (added as a second output to the same
/// ffmpeg process that produces PCM for the transcription engine), so this
/// class is now mostly a path provider + cleanup helper.
///
/// **Single-ffmpeg architecture.** Earlier versions of this file spawned its
/// own ffmpeg sidecar that received a duplicated PCM stream and encoded to
/// audio-only m4a. Adding video support broke that model — we'd need both a
/// PCM stream (for transcription) and the original muxed video data (for
/// playback). The clean fix was to fold the cache output into the main
/// extractor's ffmpeg: same input, two outputs (PCM on stdout, muxed
/// passthrough to disk). That's why this class doesn't run ffmpeg itself
/// anymore.
///
/// **Format.** MPEG-4 (.mp4) container with stream-copy of whatever
/// codecs the source delivers — typically h264 video + aac audio when
/// yt-dlp's `best[height<=480]` format selector chooses a YouTube
/// muxed stream. Stream-copy means zero CPU overhead during
/// transcription and bit-exact preservation of the source quality.
/// mp4 is chosen over Matroska because AVPlayer (the backbone of the
/// miniplayer) supports mp4 natively on macOS; Matroska requires
/// third-party components most users don't have.
///
/// **mp4's codec constraint.** mp4 doesn't accept every codec
/// combination — vp9+opus from some HLS streams, for instance, can't
/// be muxed into mp4 without re-encoding. When that happens ffmpeg
/// fails on the second output and the cache file is never written;
/// the miniplayer simply stays unavailable for that session. For
/// YouTube's 480p selector the chosen formats are almost always
/// h264+aac which mux cleanly, so this edge case is rare in
/// practice. A future improvement could add an audio-re-encode
/// fallback (`-c:v copy -c:a aac`) for these cases.
///
/// **Lifecycle.**
///   - `currentFileURL` — the path ffmpeg should write to. Passed into
///     `AudioStreamExtractor.start(cacheOutputPath:)`.
///   - `clearAll()` — empties the entire cache directory. Wired to app
///     launch, app quit, new-transcription-start, and a manual menu
///     item per the user's spec.
///   - `cacheSizeBytes()` — sum of files in the cache directory.
///     Reserved for future Settings UI ("Audio cache: 142 MB").
///
/// **Concurrency.** Pure static helpers, no instance state. Safe to call
/// from any thread.
enum MediaCacheManager {
    /// `~/Library/Application Support/StreamScribe/media-cache/`. We use
    /// Application Support rather than Caches because we want the file
    /// to survive a system "purge caches" event during a long
    /// transcription, and we control cleanup ourselves.
    static var cacheDirectory: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("StreamScribe")
            .appendingPathComponent("media-cache")
    }

    /// Path the in-progress recording writes to. Single fixed name —
    /// only one transcription runs at a time, so there's no conflict.
    /// `.mp4` for native AVPlayer/QuickTime compatibility on macOS;
    /// see the class doc for rationale.
    /// Per-session cache (2026-10-02, concurrent-sessions work). Each
    /// TranscriptionEngine gets its own subdirectory, so a second session
    /// starting no longer deletes the first one's media mid-run. The file
    /// NAMES inside are unchanged (current.mp4 / session-video.mp4), so
    /// consumers that key on them (miniplayer live-asset detection, the
    /// portal's media snapshot) keep working by last path component.
    struct SessionCache: Sendable, Equatable {
        let directory: URL

        var currentFileURL: URL { directory.appendingPathComponent(MediaCacheManager.currentFileName) }
        var videoDownloadFileURL: URL { directory.appendingPathComponent(MediaCacheManager.videoFileName) }
        var videoRawFileURL: URL { directory.appendingPathComponent("session-video-raw.mp4") }

        /// Create the directory and remove any stale pipe output.
        func prepareForRecording() throws -> URL {
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fm.removeItem(at: currentFileURL)
            return currentFileURL
        }

        /// Delete this session's directory and everything in it.
        func clear() {
            let fm = FileManager.default
            guard fm.fileExists(atPath: directory.path) else { return }
            do {
                try fm.removeItem(at: directory)
                print("[MediaCache] Cleared session cache \(directory.lastPathComponent).")
            } catch {
                print("[MediaCache] Failed to clear \(directory.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    static let currentFileName = "current.mp4"
    static let videoFileName = "session-video.mp4"

    /// A fresh per-session cache under `<cache>/sessions/<id>/`.
    static func makeSessionCache(id: UUID = UUID()) -> SessionCache {
        SessionCache(directory: cacheDirectory
            .appendingPathComponent("sessions")
            .appendingPathComponent(id.uuidString))
    }

    /// True for the growing pipe output of ANY session (the miniplayer
    /// loads it as a fragmented asset).
    static func isLiveCacheFile(_ url: URL) -> Bool {
        url.isFileURL && url.lastPathComponent == currentFileName && url.path.hasPrefix(cacheDirectory.path)
    }

    /// True for a downloaded session video of ANY session.
    static func isVideoCacheFile(_ url: URL) -> Bool {
        url.isFileURL && url.lastPathComponent == videoFileName && url.path.hasPrefix(cacheDirectory.path)
    }

    /// Legacy single-slot paths (pre-2026-10-02), kept only so clearAll()
    /// still covers files written by older builds.
    static var currentFileURL: URL {
        cacheDirectory.appendingPathComponent(currentFileName)
    }

    /// Split-stream video cache (2026-07). For STATIC sessions the
    /// transcription pipe is audio-only (see AudioStreamExtractor's
    /// selector rationale) and the miniplayer's video comes from this
    /// separate, complete file — a normal indexed mp4 downloaded by
    /// `VideoCacheDownloader` via a bv*+ba merge, the shape that works
    /// on every source (adaptive YouTube streams, progressive Fox/
    /// CNBC mp4s, everything the CLI baseline handles). Existence at
    /// this FINAL path means the download completed — yt-dlp writes
    /// to a .part file and renames on success, so a partial download
    /// can never be mistaken for a playable file.
    static var videoDownloadFileURL: URL {
        cacheDirectory.appendingPathComponent(videoFileName)
    }


    /// Remove every file under the cache directory. Called on app
    /// launch (catches files from a crashed prior session), on each new
    /// transcription start (the cache is for the currently-displayed
    /// session only), on app quit (per the user's spec), and on demand
    /// via the menu item.
    static func clearAll() {
        let fm = FileManager.default
        let dir = cacheDirectory
        guard fm.fileExists(atPath: dir.path) else { return }
        do {
            let contents = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            var removed = 0
            for url in contents {
                do {
                    try fm.removeItem(at: url)
                    removed += 1
                } catch {
                    print("[MediaCache] Failed to remove \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if removed > 0 {
                print("[MediaCache] Cleared \(removed) file(s) from cache.")
            }
        } catch {
            print("[MediaCache] Failed to list cache directory: \(error.localizedDescription)")
        }
    }

    /// Sum of file sizes under the cache directory. Reserved for a
    /// future Settings UI display. Defensive — returns 0 on any error
    /// rather than throwing.
    static func cacheSizeBytes() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: cacheDirectory.path) else { return 0 }
        var total: Int64 = 0
        for case let sub as String in enumerator {
            let full = (cacheDirectory.path as NSString).appendingPathComponent(sub)
            if let attrs = try? fm.attributesOfItem(atPath: full),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }
}

/// Downloads the split-stream video cache file for static sessions.
/// One at a time (one session at a time); `start` kills any prior run.
/// Deliberately NOT the transcription-critical path: failure just
/// means the miniplayer stays audio-only for the session, exactly the
/// pre-split behavior. Lives in this file so no new Xcode file
/// membership is needed.
final class VideoCacheDownloader: @unchecked Sendable {
    /// One instance per TranscriptionEngine (2026-10-02): a single shared
    /// slot meant one session's cancel() killed another session's download.

    private let lock = NSLock()
    private var process: Process?

    /// Download the session's video to
    /// `MediaCacheManager.videoDownloadFileURL`. Returns true when the
    /// completed file exists at the final path. Safe to call from any
    /// task; cancellation via `cancel()`.
    func run(url: URL, into cache: MediaCacheManager.SessionCache) async -> Bool {
        cancel()
        let dest = cache.videoDownloadFileURL
        try? FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        // Raw download target. FIELD BUG (2026-07-21, VRP err=-12852,
        // Fox Business): source bitstreams can be AVFoundation-hostile
        // — this one had malformed SEI NAL units that ffmpeg merely
        // warns about but AVPlayer's decoder refuses outright. The
        // session cache never hit this because its ffmpeg transcode
        // through h264_videotoolbox silently sanitized every stream.
        // So the raw download is a STAGING file; the published
        // session-video.mp4 is always the laundered transcode below —
        // same codec-proof guarantee as the cache path.
        let rawDest = cache.videoRawFileURL
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.removeItem(at: rawDest)

        guard let tools = try? await AudioStreamExtractor.resolveYTDlpTools() else {
            print("[VideoCache] Tools unavailable — miniplayer will be audio-only this session.")
            return false
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tools.ytDlpPath)
        if let env = tools.childEnvironment { proc.environment = env }
        proc.currentDirectoryURL = cache.directory

        var args: [String] = ["--ignore-config", "--no-mark-watched"]
        if let denoPath = tools.denoPath {
            args.append(contentsOf: ["--js-runtimes", "deno:\(denoPath)"])
            args.append(contentsOf: PotProviderManager.shared.potArguments())
        }
        args.append(contentsOf: ToolManager.youtubePlayerClientArguments())
        args.append(contentsOf: ToolManager.proxyArguments())
        // Sync, non-isolated — mirrors VideoDownloadService's usage.
        args.append(contentsOf: ToolManager.shared.sessionCookieArguments(
            browserArg: tools.cookieBrowser.ytDlpArgument
        ))
        if tools.disableTLSCheck {
            args.append("--no-check-certificate")
        }
        args.append(contentsOf: [
            // bv*+ba merge — the proven-everywhere shape (file output
            // has no single-muxed-format constraint). Known codecs
            // preferred, SABR unknown-codec formats excluded, capped
            // at 480p to match the miniplayer's display size and keep
            // the download comfortably faster than realtime.
            "-f", "bv*[vcodec^=avc1][height<=480]+ba[acodec^=mp4a]/bv*[height<=480][vcodec!*=unknown]+ba[acodec!*=unknown]/b[height<=480][vcodec!*=unknown]/b[vcodec!*=unknown]/b",
            "--merge-output-format", "mp4",
            "-N", "8",
            "--no-warnings",
            "-o", rawDest.path,
            url.absoluteString,
        ])
        // ffmpeg is needed for the bv*+ba merge tiers; without it the
        // progressive `/b` tail still works, so degrade rather than
        // bail. `ffmpegPath` is Optional — the bundled binary may not
        // have finished provisioning on a fresh install.
        if let ffmpeg = ToolManager.shared.ffmpegPath {
            args.append(contentsOf: ["--ffmpeg-location", ffmpeg])
        } else {
            print("[VideoCache] ffmpeg unavailable — merge tiers may fail; progressive fallback only.")
        }
        proc.arguments = args

        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()

        do {
            try proc.run()
        } catch {
            print("[VideoCache] Failed to launch yt-dlp: \(error.localizedDescription)")
            return false
        }
        lock.lock(); process = proc; lock.unlock()
        print("[VideoCache] Video cache download started → \(dest.lastPathComponent)")

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in cont.resume() }
        }
        lock.lock(); if process === proc { process = nil }; lock.unlock()

        let downloaded = proc.terminationStatus == 0
            && FileManager.default.fileExists(atPath: rawDest.path)
        guard downloaded else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            print("[VideoCache] Download failed (exit \(proc.terminationStatus)) — miniplayer stays audio-only. Last stderr: \(err.suffix(400))")
            return false
        }
        print("[VideoCache] Raw download complete (\(sizeMB(rawDest))) — transcoding for AVPlayer…")

        // Launder stage. Mirrors the cache pipeline's proven settings
        // (h264_videotoolbox + aac + yuv420p): hardware encode, near-
        // zero CPU on Apple Silicon, and the output plays in AVPlayer
        // regardless of what the source served. +faststart IS wanted
        // here (unlike the fragmented cache): this is a complete
        // offline file, and moov-up-front makes the miniplayer open it
        // instantly.
        let ok = await transcode(rawDest: rawDest, dest: dest, workingDirectory: cache.directory)
        try? FileManager.default.removeItem(at: rawDest)
        if ok {
            print("[VideoCache] Video cache ready (\(sizeMB(dest))).")
        } else {
            print("[VideoCache] Transcode failed — miniplayer stays audio-only this session.")
            try? FileManager.default.removeItem(at: dest)
        }
        return ok
    }

    private func sizeMB(_ url: URL) -> String {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil)
            .map { "\($0 / 1_048_576) MB" } ?? "?"
    }

    /// ffmpeg launder pass: raw download → AVPlayer-safe mp4. Runs
    /// under the same cancellation regime as the download (cancel()
    /// terminates whichever process is current).
    private func transcode(rawDest: URL, dest: URL, workingDirectory: URL) async -> Bool {
        guard let ffmpeg = ToolManager.shared.ffmpegPath else {
            print("[VideoCache] ffmpeg unavailable for transcode.")
            return false
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.currentDirectoryURL = workingDirectory
        proc.arguments = [
            "-hide_banner", "-loglevel", "warning",
            "-i", rawDest.path,
            // Capital V: exclude attached-picture streams (podcast
            // cover art) — same field failure as the session cache's
            // map, see AudioStreamExtractor. With no real video the
            // transcode yields an audio-only mp4, which plays fine.
            "-map", "0:V:0?",
            "-map", "0:a:0",
            "-c:v", "h264_videotoolbox",
            "-b:v", "1500k",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-b:a", "128k",
            "-movflags", "+faststart",
            "-y",
            dest.path,
        ]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        do {
            try proc.run()
        } catch {
            print("[VideoCache] Failed to launch ffmpeg: \(error.localizedDescription)")
            return false
        }
        lock.lock(); process = proc; lock.unlock()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in cont.resume() }
        }
        lock.lock(); if process === proc { process = nil }; lock.unlock()
        if proc.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            print("[VideoCache] ffmpeg transcode exit \(proc.terminationStatus): \(err.suffix(400))")
        }
        return proc.terminationStatus == 0
            && FileManager.default.fileExists(atPath: dest.path)
    }

    /// Terminate an in-flight download (session stop / new session).
    func cancel() {
        lock.lock()
        let proc = process
        process = nil
        lock.unlock()
        if let proc, proc.isRunning {
            proc.terminate()
            print("[VideoCache] Download cancelled.")
        }
    }
}
