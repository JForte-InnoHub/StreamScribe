import Foundation
import Combine
import Darwin

/// Severity level inferred from log line contents. Used for filtering in the
/// viewer; doesn't change how lines are stored.
enum LogLevel: String, CaseIterable {
    case info  = "INFO"
    case warn  = "WARN"
    case error = "ERROR"

    /// Heuristic level detection from a raw line. We can't get explicit levels
    /// from `print()` output, but the existing codebase uses recognizable patterns
    /// like "Error: ...", "[Component] failed: ...", etc. This is imperfect — users
    /// can fall back to free-text search when the heuristic miscategorizes.
    static func detect(from line: String) -> LogLevel {
        let lower = line.lowercased()
        // Order matters: check error before warn, since "warning: error in ..." should
        // count as warn (the line is *about* an error but not itself reporting one).
        // We use whole-word-ish matching by anchoring on common prefixes/punctuation
        // to reduce false positives from words like "errors" being a substring.
        if lower.contains("error:") || lower.contains(" error ") || lower.contains("[error]")
            || lower.contains("failed") || lower.contains("exception") {
            return .error
        }
        if lower.contains("warn") {
            return .warn
        }
        return .info
    }
}

/// Where the line came from — distinguishes stdout (our prints + framework prints)
/// from stderr (errors, panics, NSLog on some configurations).
enum LogSource: String {
    case stdout
    case stderr
}

struct LogEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let source: LogSource
    let text: String

    /// Pre-formatted single-line representation used by export/copy.
    var formatted: String {
        let df = LogEntry.timestampFormatter
        return "[\(df.string(from: timestamp))] [\(level.rawValue)] [\(source.rawValue)] \(text)"
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
}

/// Captures stdout/stderr and exposes a published ring buffer of log entries that
/// the in-app log viewer renders. Designed to be installed once at app launch and
/// run for the app's lifetime — there's no clean-up path because we redirect
/// global file descriptors and unwinding that mid-flight is risky.
///
/// Architectural notes:
///
/// • We use `dup2` to point FD 1 (stdout) and FD 2 (stderr) at the write ends of
///   pipes we own. Before redirecting, we save the original FDs so we can echo
///   captured output back to them — that way Xcode's console still receives
///   prints in development builds. In release builds the originals don't go
///   anywhere meaningful but echoing is harmless.
///
/// • We `setvbuf(_IONBF)` on the C FILE* wrappers so prints flush immediately into
///   the pipe rather than sitting in libSystem's stdio buffer. Without this the
///   viewer would lag noticeably behind the actual print calls.
///
/// • Pipe readability handlers fire on background queues. We accumulate bytes,
///   split on newlines, then hop to MainActor to mutate `entries` since SwiftUI
///   binds to it.
///
/// • The buffer is capped at `maxEntries` to keep memory bounded across long
///   sessions. Older entries get evicted. 5000 is enough for ~1-2 hours of
///   typical activity given the existing log volume.
final class StreamScribeLogger: ObservableObject {
    static let shared = StreamScribeLogger()

    /// The visible log buffer. Append-only from a single producer (the readability
    /// handlers funnel through MainActor). UI uses Identifiable rows.
    @Published private(set) var entries: [LogEntry] = []

    /// When true, new entries get added to the buffer. When false, the capture
    /// pipes still drain (so we don't deadlock writers) but lines are dropped.
    /// Lets the user pause the live tail to read without scroll-jumping.
    @Published var isCapturing: Bool = true

    /// Cap on retained entries. Older ones are evicted once we exceed.
    private let maxEntries = 5000

    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var savedStdoutFD: Int32 = -1
    private var savedStderrFD: Int32 = -1
    /// Per-source byte accumulator. stdout/stderr can deliver mid-line chunks;
    /// we hold partial lines until we see a newline.
    private var partialBuffers: [LogSource: String] = [.stdout: "", .stderr: ""]
    private let partialQueue = DispatchQueue(label: "logger.partial-buffers")

    private init() {}

    // MARK: - Capture lifecycle

    /// Install the stdout/stderr redirects. Call once at app launch. Subsequent
    /// calls are no-ops.
    func startCapture() {
        guard stdoutPipe == nil else { return }

        // Save originals so we can echo captured output back to them. dup() returns
        // a new FD pointing at the same kernel file description; closing one doesn't
        // affect the other. -1 means dup failed, in which case we just don't echo.
        savedStdoutFD = dup(fileno(stdout))
        savedStderrFD = dup(fileno(stderr))

        stdoutPipe = makeCapturePipe(targetFD: fileno(stdout), source: .stdout, savedFD: savedStdoutFD)
        stderrPipe = makeCapturePipe(targetFD: fileno(stderr), source: .stderr, savedFD: savedStderrFD)

        // Force unbuffered stdio so print() output reaches our pipe promptly.
        // _IONBF = no buffering. This affects all subsequent writes; existing buffered
        // bytes (if any) are flushed first by setvbuf per the man page.
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)

        // Seed an entry so users see immediate confirmation that capture is running
        // even before any print() fires. Helpful for "did this even start?" anxiety
        // when the log appears empty.
        appendOnMain(LogEntry(
            id: UUID(),
            timestamp: Date(),
            level: .info,
            source: .stdout,
            text: "[Logger] Capture started — stdout and stderr are being recorded."
        ))
    }

    /// Wire up a single pipe: redirect `targetFD` into the pipe's write end, attach
    /// a readability handler to the read end that parses lines and forwards them
    /// to the main-thread buffer (and echoes raw bytes to `savedFD` so Xcode's
    /// console keeps working).
    private func makeCapturePipe(targetFD: Int32, source: LogSource, savedFD: Int32) -> Pipe {
        let pipe = Pipe()
        // dup2 atomically closes targetFD and makes it a copy of the pipe's write FD.
        // After this, anything written to targetFD goes into our pipe.
        dup2(pipe.fileHandleForWriting.fileDescriptor, targetFD)

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            // `availableData` returns a `Data` that is, on macOS, often a
            // no-copy wrapper around the FileHandle's internal buffer.
            // The handler can be re-invoked on a different dispatch worker
            // before our processing finishes, which lets the FileHandle
            // reuse/free that buffer while we're still touching it — which
            // produces an `EXC_BREAKPOINT` inside malloc (the symptom:
            // `_szone_free` → `_swift_release_dealloc` → ... → our
            // `String.components(separatedBy:)` call).
            //
            // Fix: force an immediate copy via `Data(...)` so anything we
            // do afterwards is on bytes WE own. The cost is a small heap
            // copy per readability event; cheap compared to the alternative
            // (a process-killing race).
            let raw = handle.availableData
            // availableData returning empty data means EOF on the pipe. That shouldn't
            // happen during normal operation since the writer FD lives in the same
            // process, but be defensive.
            guard !raw.isEmpty else { return }
            let data = Data(raw)  // defensive copy; see above

            // Echo raw bytes to the original FD so Xcode console / terminal still sees
            // them. write() is async-safe; partial writes are unlikely with pipes this
            // small but we don't bother retrying — losing a few echo bytes to Xcode
            // doesn't affect what's stored in our buffer.
            if savedFD >= 0 {
                _ = data.withUnsafeBytes { buf in
                    write(savedFD, buf.baseAddress, data.count)
                }
            }

            guard let self else { return }
            self.processBytes(data, source: source)
        }
        return pipe
    }

    /// Decode bytes to UTF-8, glue with any held partial line, split on newlines,
    /// and emit complete lines to the buffer. Trailing partial-line data is held
    /// until the next chunk completes it.
    private func processBytes(_ data: Data, source: LogSource) {
        // Lossy UTF-8 conversion — invalid sequences become replacement chars rather
        // than dropping data. ASR/ML logs occasionally include odd bytes from
        // underlying CoreML/Metal layers and we'd rather show garbled than nothing.
        guard let chunk = String(data: data, encoding: .utf8) else { return }

        // Glue with held partial, split, then re-hold any final partial. We mutate
        // the per-source partial under a lock since multiple pipes can fire
        // concurrent readability events on background queues.
        //
        // **Why split on both \n AND \r.** Most prints emit `\n` and are
        // terminated cleanly. But terminal-style progress lines (e.g.
        // mlx-audio-swift's HF Hub download log) use bare `\r` to
        // overwrite the same physical row in a terminal: `1/N files\r`,
        // `2/N files\r`, etc. If we split only on `\n`, those lines
        // accumulate in the partial buffer forever and never get
        // emitted — so our progress-regex never sees them and the UI
        // bar stays at 0%. Splitting on `\r` too treats every progress
        // tick as a separate line. We still strip a trailing `\r` per
        // line below in case `\r\n` (CRLF) ever shows up.
        var lines: [String] = []
        partialQueue.sync {
            let combined = (partialBuffers[source] ?? "") + chunk
            // Replace bare \r with \n first, then split. CRLF sequences
            // become \n\n (one empty line) which the empty-line filter
            // below drops, so this doesn't change behavior for cleanly-
            // terminated lines — only rescues \r-only lines.
            let normalized = combined.replacingOccurrences(of: "\r", with: "\n")
            let parts = normalized.components(separatedBy: "\n")
            // The last element is either empty (input ended with \n; nothing held)
            // or a partial line (input ended mid-line; hold it for next time).
            if let tail = parts.last {
                partialBuffers[source] = tail
            }
            // All elements except the last are complete lines.
            lines = Array(parts.dropLast())
        }

        guard !lines.isEmpty else { return }

        // Build entries off the main thread, then ship the batch over to MainActor
        // for the actual buffer mutation. Doing the build here avoids burning
        // MainActor time on string parsing during heavy log bursts.
        let now = Date()
        let entries: [LogEntry] = lines.compactMap { raw -> LogEntry? in
            // Strip a trailing \r in case writers used CRLF (rare on macOS but cheap
            // to handle).
            let trimmed = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            // Drop completely empty lines — they create visual noise and aren't
            // informative. Lines containing only whitespace are kept since
            // formatted output sometimes uses them as separators.
            guard !trimmed.isEmpty else { return nil }
            // Drop noisy library progress spam. mlx-audio-swift's HF Hub
            // download flow emits lines of the form "<N>/<M> files" on
            // bare `\r`, several times per second, for the entire
            // duration of every model download. With the `\r → \n`
            // normalization above turning each tick into its own log
            // entry, a 2.5 GB Parakeet download produces ~1500 lines of
            // pure noise in the log file. Earlier we kept these around
            // for a progress-regex consumer that would have driven the
            // UI download bar; that consumer was never built (the
            // libraries don't expose true byte progress — see
            // `ModelDownloadManager` for the indeterminate-spinner
            // workaround), so these lines have no consumer and are
            // pure clutter. Drop them at capture time so the persistent
            // log stays readable. Match the exact "<digits>/<digits> files"
            // shape (with optional leading spaces) to avoid suppressing
            // anything else that legitimately includes "files".
            if Self.isLibraryProgressSpam(trimmed) { return nil }
            return LogEntry(
                id: UUID(),
                timestamp: now,
                level: LogLevel.detect(from: trimmed),
                source: source,
                text: trimmed
            )
        }
        guard !entries.isEmpty else { return }

        // Hop to MainActor for buffer mutation since `entries` is @Published.
        Task { @MainActor [weak self] in
            self?.appendBatch(entries)
        }
    }

    @MainActor
    private func appendBatch(_ batch: [LogEntry]) {
        guard isCapturing else { return }
        entries.append(contentsOf: batch)
        // Evict oldest when we overflow. We chunk-evict by 10% rather than one at
        // a time so a long session doesn't pay the array-shift cost on every line.
        if entries.count > maxEntries {
            let evictCount = entries.count - (maxEntries - maxEntries / 10)
            entries.removeFirst(evictCount)
        }
    }

    @MainActor
    private func appendOnMain(_ entry: LogEntry) {
        appendBatch([entry])
    }

    /// Whether a captured line is mlx-audio-swift's download progress
    /// spam. Matches `"<digits>/<digits> files"` exactly (with optional
    /// surrounding whitespace), where both numbers are byte counts the
    /// library mislabels as "files". Tight match — anything with
    /// additional text falls through to the normal logging path so we
    /// don't accidentally suppress a real message that happens to
    /// mention files.
    ///
    /// Examples that ARE suppressed:
    ///   - "0/2508579601 files"
    ///   - "  290865/2508579601 files  "
    ///
    /// Examples that are NOT suppressed:
    ///   - "Downloading 3 files from HF Hub" (has extra words)
    ///   - "Total fragments: 639" (different shape)
    ///   - "[Pipeline] 3/4 files staged" (has prefix)
    private static func isLibraryProgressSpam(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(" files") else { return false }
        // Strip the trailing " files" and check the prefix is "N/M".
        let prefix = String(trimmed.dropLast(6))  // " files".count == 6
        let parts = prefix.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts[0].allSatisfy(\.isNumber) && parts[1].allSatisfy(\.isNumber)
    }

    // MARK: - Public API for the viewer

    @MainActor
    func clear() {
        entries.removeAll()
    }

    /// Render entries (filtered or not) to a single string suitable for clipboard
    /// or file export.
    @MainActor
    func renderForExport(_ rows: [LogEntry]? = nil) -> String {
        let rows = rows ?? entries
        return rows.map { $0.formatted }.joined(separator: "\n")
    }
}
