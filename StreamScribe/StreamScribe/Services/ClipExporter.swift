import Foundation

/// Exports clips from the live media cache (and, later, arbitrary
/// spans of finished media — the transcript-selection export feature
/// shares this plumbing).
///
/// **Why this is cheap.** Live sessions already mux a stream-copy of
/// the source into `MediaCache/current.mp4` (the single-ffmpeg
/// two-output architecture — see MediaCacheManager). That growing
/// file IS a replay buffer covering the whole session. A "clip the
/// last N seconds" is one ffmpeg invocation with `-sseof -N`
/// (seek-from-end-of-file) and stream copy: no re-encode, no
/// duration bookkeeping, sub-second export for any sane clip length.
///
/// **Keyframe granularity.** Stream copy can only cut on keyframes,
/// so the clip's start snaps backward to the previous keyframe —
/// for typical 480p web streams that's a 2-4s GOP, meaning "last
/// 30 seconds" delivers 30-34 seconds with a little extra lead-in.
/// For the capture-what-was-just-said use case, extra lead-in is a
/// feature. Frame-exact cutting would require re-encoding; not
/// worth it until someone asks.
enum ClipExporter {

    enum ClipError: LocalizedError {
        case sourceMissing
        case ffmpegMissing
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .sourceMissing:
                return "No cached media to clip from."
            case .ffmpegMissing:
                return "ffmpeg is not available. Check Tools in the sidebar."
            case .exportFailed(let detail):
                return "Clip export failed: \(detail)"
            }
        }
    }

    /// Where clips land: `~/Movies/StreamScribe Clips/`. Created on
    /// first export. Chosen over a save panel so the button is
    /// one-click during a live hearing — no dialog to dismiss while
    /// the moment you wanted to capture keeps playing.
    static var clipsDirectory: URL {
        let movies = FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("StreamScribe Clips", isDirectory: true)
    }

    /// Export the trailing `duration` seconds of `source` to the
    /// clips directory. Returns the written file's URL.
    ///
    /// Uses `-sseof -N` (input option: seek relative to END of file)
    /// so we never need to know the file's current duration — exactly
    /// right for a file that's still growing. ffmpeg resolves EOF at
    /// open time, so the clip covers the last N seconds as of the
    /// moment the button was pressed; the mux's write buffer means
    /// the true live edge can lag by ~1-2s, which is inside the
    /// keyframe slop anyway.
    static func exportTrailingClip(from source: URL, duration: TimeInterval) async throws -> URL {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ClipError.sourceMissing
        }
        guard let ffmpeg = ToolManager.shared.ffmpegPath else {
            throw ClipError.ffmpegMissing
        }

        try FileManager.default.createDirectory(
            at: clipsDirectory, withIntermediateDirectories: true
        )

        let stamp = Self.timestampFormatter.string(from: Date())
        let dest = uniqueURL(for: clipsDirectory
            .appendingPathComponent("Clip \(stamp).mp4"))

        let args = [
            "-hide_banner", "-nostdin", "-y",
            "-sseof", "-\(Int(duration.rounded()))",
            "-i", source.path,
            "-c", "copy",
            // faststart relocates the moov atom to the file head so
            // the clip previews instantly in QuickLook/Slack/etc.
            // Costs a second remux pass — trivial at clip sizes.
            "-movflags", "+faststart",
            dest.path,
        ]

        let stderrText = try await runProcess(executable: ffmpeg, arguments: args)

        guard FileManager.default.fileExists(atPath: dest.path),
              (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64 ?? 0) ?? 0 > 0 else {
            // Surface the tail of stderr — ffmpeg's actual complaint
            // is always in the last few lines.
            let tail = stderrText.split(separator: "\n").suffix(4).joined(separator: " ")
            throw ClipError.exportFailed(tail.isEmpty ? "no output produced" : tail)
        }
        print("[Clip] Exported \(Int(duration))s clip → \(dest.lastPathComponent)")
        return dest
    }

    // MARK: - Internals

    private static func runProcess(executable: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let errPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errPipe
            process.terminationHandler = { _ in
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Collision-safe destination: appends " 2", " 3", … before the
    /// extension if the timestamped name somehow already exists (two
    /// clips within the same second).
    private static func uniqueURL(for url: URL) -> URL {
        var candidate = url
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = url.deletingPathExtension().lastPathComponent
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(base) \(counter).\(url.pathExtension)")
            counter += 1
        }
        return candidate
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()
}
