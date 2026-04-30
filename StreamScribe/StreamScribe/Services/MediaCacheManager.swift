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
    static var currentFileURL: URL {
        cacheDirectory.appendingPathComponent("current.mp4")
    }

    /// Ensure the cache directory exists, returning the path that
    /// ffmpeg should write to. Called by `TranscriptionEngine` before
    /// starting the extractor. Throws if directory creation fails —
    /// rare (would need a permissions issue or full disk).
    static func prepareForRecording() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        // Wipe any leftover from a previous run so partial mkv data
        // can't confuse the miniplayer if the new recording fails
        // before producing usable output.
        try? fm.removeItem(at: currentFileURL)
        return currentFileURL
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
