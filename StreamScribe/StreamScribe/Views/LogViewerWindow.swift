import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The log viewer window. Lives independently of the main window — opened via
/// the Window menu (or ⌘L) and can stay open alongside transcription work for
/// real-time debugging.
///
/// Layout: toolbar at top (filters, search, action buttons) + scrollable list
/// of log rows below. Auto-scroll-to-bottom toggleable; defaults on so live
/// debugging works as expected.
struct LogViewerWindow: View {
    @StateObject private var logger = StreamScribeLogger.shared

    /// Active level filter set. Empty set = no filter (show all). We use a Set
    /// rather than three booleans so adding a new level later doesn't require
    /// expanding the toggle UI logic.
    @State private var activeLevels: Set<LogLevel> = Set(LogLevel.allCases)
    @State private var sourceFilter: SourceFilter = .all
    @State private var searchText: String = ""
    /// When true, the list auto-scrolls to the latest entry on every new arrival.
    /// Off lets the user read mid-buffer without being yanked to the bottom.
    @State private var autoScroll: Bool = true
    @State private var showCopiedToast: Bool = false

    enum SourceFilter: String, CaseIterable, Identifiable {
        case all    = "All sources"
        case stdout = "stdout only"
        case stderr = "stderr only"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(NSColor.windowBackgroundColor))
            Divider()
            logList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .top) {
            if showCopiedToast {
                Text("Copied to clipboard")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.9))
                    )
                    .foregroundStyle(.white)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(minWidth: 700, minHeight: 400)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            // Capture toggle. When off, new lines are dropped — useful when the user
            // wants the buffer to stop growing mid-investigation so they can scroll
            // freely without auto-evictions or fresh-arrival jitter.
            Toggle(isOn: $logger.isCapturing) {
                Label("Capturing", systemImage: logger.isCapturing
                      ? "record.circle.fill"
                      : "pause.circle")
                    .foregroundStyle(logger.isCapturing ? Color.red : Color.secondary)
                    .labelStyle(.titleAndIcon)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(logger.isCapturing
                  ? "Pause capture — new lines won't be added to the buffer"
                  : "Resume capture")

            // Level filter — multi-select via menu. Showing as a button with the
            // current active count keeps the toolbar compact.
            Menu {
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Button {
                        toggleLevel(level)
                    } label: {
                        if activeLevels.contains(level) {
                            Label(level.rawValue, systemImage: "checkmark")
                        } else {
                            Text(level.rawValue)
                        }
                    }
                }
                Divider()
                Button("All") { activeLevels = Set(LogLevel.allCases) }
                Button("None") { activeLevels = [] }
            } label: {
                Label(levelMenuLabel, systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

            // Source filter — single-select picker since the three states are mutex.
            Picker("Source", selection: $sourceFilter) {
                ForEach(SourceFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .labelsHidden()
            .fixedSize()

            // Search field. Free-text filter applied case-insensitively to the
            // line text. Works alongside level/source filters; intersected.
            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .controlSize(.small)

            Spacer()

            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .controlSize(.small)

            Button(action: copyVisible) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .controlSize(.small)
            .help("Copy currently visible (filtered) entries to clipboard")

            Button(action: exportToFile) {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .controlSize(.small)
            .help("Save full log to a file")

            Button(role: .destructive, action: { logger.clear() }) {
                Label("Clear", systemImage: "trash")
            }
            .controlSize(.small)
            .help("Discard all entries")
        }
    }

    private var levelMenuLabel: String {
        if activeLevels.count == LogLevel.allCases.count {
            return "All levels"
        }
        if activeLevels.isEmpty {
            return "No levels"
        }
        return activeLevels.map(\.rawValue).sorted().joined(separator: ", ")
    }

    private func toggleLevel(_ level: LogLevel) {
        if activeLevels.contains(level) {
            activeLevels.remove(level)
        } else {
            activeLevels.insert(level)
        }
    }

    // MARK: - List

    /// Filtered view over `logger.entries`. Recomputed on every body invocation;
    /// cheap for 5000-cap buffer with simple predicates.
    private var visibleEntries: [LogEntry] {
        let search = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return logger.entries.filter { entry in
            guard activeLevels.contains(entry.level) else { return false }
            switch sourceFilter {
            case .all: break
            case .stdout: guard entry.source == .stdout else { return false }
            case .stderr: guard entry.source == .stderr else { return false }
            }
            if !search.isEmpty {
                guard entry.text.lowercased().contains(search) else { return false }
            }
            return true
        }
    }

    /// Scrollable list. We use `ScrollViewReader` + `.onChange` on the entries
    /// count to scroll to the latest row whenever a new one arrives (when
    /// auto-scroll is on). LazyVStack keeps memory and CPU sane on large buffers.
    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let rows = visibleEntries
                    ForEach(rows) { entry in
                        LogRow(entry: entry)
                            .id(entry.id)
                    }
                    if rows.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                    }
                }
            }
            .onChange(of: logger.entries.count) { _, _ in
                guard autoScroll, let last = logger.entries.last else { return }
                // Use last entry id rather than visibleEntries.last because filters
                // can hide tail entries — we still want to track the underlying tail
                // when capturing, since that's what most users want when leaving
                // auto-scroll on.
                withAnimation(.linear(duration: 0.05)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: logger.entries.isEmpty
                  ? "doc.text.magnifyingglass"
                  : "line.3.horizontal.decrease")
                .font(.system(size: 32, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(logger.entries.isEmpty
                 ? "No log entries yet."
                 : "No entries match the current filters.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func copyVisible() {
        let text = visibleEntries.map { $0.formatted }.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Brief visual confirmation. This is a UI nicety — without it the user
        // gets no feedback that the copy worked.
        withAnimation(.easeOut(duration: 0.2)) { showCopiedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeIn(duration: 0.3)) { showCopiedToast = false }
        }
    }

    private func exportToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "streamscribe-log-\(timestampForFilename()).txt"
        panel.title = "Export Log"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Always export the full unfiltered buffer when saving — filtered copy is
        // available via the Copy button. The reasoning: a saved log file is most
        // useful as a complete record for later analysis, where filters can be
        // re-applied in any text editor. Saving filtered output silently would
        // obscure that.
        Task { @MainActor in
            let body = StreamScribeLogger.shared.renderForExport()
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func timestampForFilename() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

// MARK: - Single row

/// One log entry rendered as a tight monospace row with timestamp, level pill,
/// and message text. Selection is per-row (tap to highlight, ⌘C copies the
/// selected row's text — handled by NSPasteboard since SwiftUI's text selection
/// across non-text elements is awkward on macOS).
private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(timestampString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(entry.level.rawValue)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(levelColor)
                .frame(width: 42, alignment: .leading)
            Text(entry.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(textColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(rowBackground)
    }

    private var timestampString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: entry.timestamp)
    }

    private var levelColor: Color {
        switch entry.level {
        case .info:  return .secondary
        case .warn:  return .orange
        case .error: return .red
        }
    }

    private var textColor: Color {
        // stderr lines get a slightly dimmer color so they're visually distinct
        // from stdout without being unreadable. Errors remain red regardless.
        if entry.level == .error { return .red }
        return entry.source == .stderr ? .secondary : .primary
    }

    private var rowBackground: some View {
        // Alternating row bg helps long lines stay readable when wrapping.
        // Subtle so it doesn't fight the level color cues.
        Color.gray.opacity(0.04)
    }
}
