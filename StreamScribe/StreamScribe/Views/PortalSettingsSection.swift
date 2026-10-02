import SwiftUI
import AppKit

/// Settings → Web Portal. Drop-in `Section` for SettingsView's Form.
struct PortalSettingsSection: View {
    @ObservedObject private var portal = PortalJobQueue.shared

    @AppStorage(PortalJobQueue.enabledKey) private var enabled: Bool = false
    @AppStorage(PortalJobQueue.portKey) private var port: Int = PortalJobQueue.defaultPort
    @AppStorage(PortalJobQueue.adminEmailsKey) private var adminEmails: String = ""
    @AppStorage(PortalJobQueue.retentionDaysKey) private var retentionDays: Int = PortalJobQueue.defaultRetentionDays
    @AppStorage(PortalJobQueue.capacityKey) private var capacity: Int = 1

    private var isRunning: Bool {
        if case .running = portal.serverState { return true }
        return false
    }

    private var statusColor: Color {
        switch portal.serverState {
        case .running: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    var body: some View {
        Section {
            Toggle("Serve the web portal", isOn: $enabled)
                .onChange(of: enabled) { _, _ in portal.applyServerSetting() }

            HStack {
                Text("Server")
                Spacer()
                Text(portal.serverState.label)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                Text("Port")
                Spacer()
                TextField("", value: $port, format: .number.grouping(.never))
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { portal.applyServerSetting() }
            }

            Toggle("Pause queue", isOn: $portal.isPaused)

            Picker("Jobs at once", selection: $capacity) {
                ForEach(1...PortalJobQueue.maxCapacity, id: \.self) { n in
                    Text(n == 1 ? "1 (one at a time)" : "\(n)").tag(n)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: capacity) { _, _ in portal.capacityChanged() }

            HStack {
                Text("Queue")
                Spacer()
                Text(portal.summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            TextField("Admins", text: $adminEmails, prompt: Text("you@example.com, colleague@example.com"))

            Picker("Keep finished transcripts", selection: $retentionDays) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("1 year").tag(365)
                Text("Forever").tag(0)
            }
            .pickerStyle(.menu)

            HStack {
                Button("Open Portal on This Mac") {
                    if let url = URL(string: "http://127.0.0.1:\(port)/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .disabled(!isRunning)
                Spacer()
                Button("Show Portal Folder") {
                    let dir = PortalJobQueue.rootDirectory
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                }
            }
        } header: {
            Text("Web Portal")
        } footer: {
            Text("Lets people on Windows, phones and other Macs use StreamScribe from a browser, through a Cloudflare Tunnel protected by Cloudflare Access. The server listens only on this Mac (127.0.0.1) and refuses requests that reach it through Cloudflare without an Access sign-in. The first job runs on this window's engine, with the Mac's own settings restored afterwards; with Jobs at once above 1, further jobs run on extra engines in the background and appear only in the portal. Each extra job loads its own models (roughly 1–2 GB) and shares the Neural Engine, so raise this only on a Mac with memory to spare. Admins can pause the queue and stop or delete anyone's job; everyone else can manage their own. See PORTAL_SETUP.md.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
