import SwiftUI
import AppKit

/// Settings → Agent API. Named keys that let AI agents and scripts request
/// transcripts through /api/agent (REST) and /api/agent/mcp (MCP).
struct PortalAgentKeysSection: View {
    @ObservedObject private var store = PortalAgentKeyStore.shared

    @State private var newLabel: String = ""
    /// The key just created — shown once, until dismissed.
    @State private var revealed: (label: String, secret: String)?
    @State private var pendingRevoke: PortalAgentKey?

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Section {
            if let revealed {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New key for \(revealed.label) — copy it now. It won't be shown again.")
                        .font(.callout.weight(.semibold))
                    HStack {
                        Text(revealed.secret)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(revealed.secret, forType: .string)
                        }
                        Button("Done") { self.revealed = nil }
                    }
                }
                .padding(.vertical, 2)
            }

            HStack {
                TextField("New key name", text: $newLabel, prompt: Text("e.g. Clips pipeline"))
                Button("Create Key") {
                    let made = store.create(label: newLabel)
                    revealed = (made.record.label, made.secret)
                    newLabel = ""
                }
            }

            if store.keys.isEmpty {
                Text("No keys yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.keys) { key in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.label)
                            Text("\(key.prefix)…  ·  created \(Self.dateFormat.string(from: key.createdAt))  ·  "
                                 + (key.lastUsedAt.map { "last used \(Self.dateFormat.string(from: $0))" } ?? "never used"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke", role: .destructive) { pendingRevoke = key }
                    }
                }
            }
        } header: {
            Text("Agent API")
        } footer: {
            Text("Lets AI agents and scripts request transcripts of links, wait for them to finish, read them and create share links. Agents send a key as \"Authorization: Bearer <key>\" (or \"X-API-Key\") to https://<portal address>/api/agent/v1 (REST) or /api/agent/mcp (MCP). Each key only sees the transcripts it requested; those jobs also appear in the portal under \"agent: <name>\". Cloudflare needs a Bypass rule for api/agent/* — see PORTAL_SETUP.md. Revoking a key stops it at once.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "Revoke \(pendingRevoke?.label ?? "this key")?",
            isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
            presenting: pendingRevoke
        ) { key in
            Button("Revoke", role: .destructive) { store.revoke(key.id) }
        } message: { _ in
            Text("Anything using it stops working straight away. Transcripts it requested stay in the portal.")
        }
    }
}
