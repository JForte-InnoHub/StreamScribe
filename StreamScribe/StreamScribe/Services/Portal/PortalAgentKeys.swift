import Foundation
import Combine
import CryptoKit

// MARK: - StreamScribe Web Portal — API keys for agents
//
// Agents (Claude, a clips pipeline, scripts) can't complete Cloudflare Access's
// email-code sign-in, so /api/agent/* is opened by a Cloudflare Bypass rule
// (like the /s/* share links) and authorised here instead, by a named key sent
// as `Authorization: Bearer <key>` or `X-API-Key: <key>`.
//
// Keys are 256 random bits ("ssk_" + 43 base64url characters). Only their
// SHA-256 is stored (Portal/agent-keys.json, owner-only permissions); the key
// itself is shown once, when it's created. Revoking deletes the record, so the
// key stops working on the next request. Jobs a key created stay in the
// portal, labelled with the key's name.

struct PortalAgentKey: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    /// Lowercase hex SHA-256 of the full key.
    let hash: String
    /// First characters of the key ("ssk_AbC1…"), so a person can tell keys apart.
    let prefix: String
    let createdAt: Date
    var lastUsedAt: Date?

    /// How this key appears as a job's submitter in the portal.
    var submitterName: String { "agent: \(label)" }
}

@MainActor
final class PortalAgentKeyStore: ObservableObject {
    static let shared = PortalAgentKeyStore()

    @Published private(set) var keys: [PortalAgentKey] = []

    static let keyPrefix = "ssk_"
    static let maxLabelLength = 60

    private var lastUsedSaveScheduled = false

    private init() { load() }

    private static var file: URL { PortalJobQueue.rootDirectory.appendingPathComponent("agent-keys.json") }

    // MARK: Create / revoke

    /// Returns the new record and the key itself — the only time the key is
    /// available; afterwards only its hash exists.
    func create(label rawLabel: String) -> (record: PortalAgentKey, secret: String) {
        let label = Self.cleanLabel(rawLabel)
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        let body = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let secret = Self.keyPrefix + body
        let record = PortalAgentKey(id: UUID(), label: label, hash: Self.digest(secret),
                                    prefix: String(secret.prefix(Self.keyPrefix.count + 6)),
                                    createdAt: Date(), lastUsedAt: nil)
        keys.append(record)
        save()
        print("[Portal] Agent API key created: \(label) (\(record.prefix)…).")
        return (record, secret)
    }

    func revoke(_ id: UUID) {
        guard let k = keys.first(where: { $0.id == id }) else { return }
        keys.removeAll { $0.id == id }
        save()
        print("[Portal] Agent API key revoked: \(k.label) (\(k.prefix)…).")
        // A revoked key's queued and running jobs stop too — otherwise a
        // leaked key's livestreams would keep their engines after revoking.
        PortalJobQueue.shared.cancelAgentJobs(of: k)
    }

    func record(_ id: UUID) -> PortalAgentKey? { keys.first { $0.id == id } }

    // MARK: Authenticate

    /// The key a request presents, or nil. Accepts `Authorization: Bearer …`
    /// and `X-API-Key: …`. Never reads keys from the URL.
    static func presentedKey(_ request: PortalHTTPRequest) -> String? {
        if let auth = request.header("authorization")?.trimmingCharacters(in: .whitespaces) {
            let parts = auth.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                return String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        if let key = request.header("x-api-key")?.trimmingCharacters(in: .whitespaces), !key.isEmpty {
            return key
        }
        return nil
    }

    /// Looks the key up by its hash. Comparing digests (not the key) means a
    /// timing difference reveals nothing about any stored key.
    func authenticate(_ presented: String) -> PortalAgentKey? {
        guard presented.hasPrefix(Self.keyPrefix), presented.count == Self.keyPrefix.count + 43,
              presented.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return nil
        }
        let h = Self.digest(presented)
        guard let i = keys.firstIndex(where: { $0.hash == h }) else { return nil }
        // Last-used is informational: record it at most once a minute per key
        // and write it out lazily, so a polling agent doesn't hammer the disk.
        let now = Date()
        if keys[i].lastUsedAt.map({ now.timeIntervalSince($0) > 60 }) ?? true {
            keys[i].lastUsedAt = now
            scheduleLastUsedSave()
        }
        return keys[i]
    }

    // MARK: Helpers

    static func digest(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func cleanLabel(_ raw: String) -> String {
        let flat = raw.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let short = String(flat.prefix(maxLabelLength)).trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? "Agent" : short
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.file) else { return }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        if let loaded = try? d.decode([PortalAgentKey].self, from: data) {
            keys = loaded
        } else {
            print("[Portal] Couldn't read agent-keys.json — agent API keys are unavailable until it's fixed or removed.")
        }
    }

    private func save() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: PortalJobQueue.rootDirectory, withIntermediateDirectories: true)
            let data = try e.encode(keys)
            try data.write(to: Self.file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
        } catch {
            print("[Portal] Couldn't save agent API keys: \(error.localizedDescription)")
        }
    }

    private func scheduleLastUsedSave() {
        guard !lastUsedSaveScheduled else { return }
        lastUsedSaveScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self else { return }
            self.lastUsedSaveScheduled = false
            self.save()
        }
    }
}
