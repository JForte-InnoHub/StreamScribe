import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - StreamScribe Web Portal — Agent API (REST + MCP)
//
// For AI agents and scripts: request a transcript of a link, wait for it,
// read it, and get a share link — without a browser sign-in.
//
//   REST  /api/agent/v1/…   (OpenAPI description at /api/agent/v1/openapi.json)
//   MCP   /api/agent/mcp    (Streamable HTTP transport, JSON responses only)
//
// Authorisation is an API key from Settings → Agent API (PortalAgentKeys.swift),
// sent as `Authorization: Bearer <key>` or `X-API-Key: <key>`. Cloudflare
// Access is bypassed for /api/agent/* (PORTAL_SETUP.md), so the key is the
// only credential; everything below is confined to the jobs that key created.
//
// Nothing here is reachable through cookies: no cookie is ever read, so a
// browser can't be tricked into calling it (no CSRF), and no CORS headers are
// sent, so a web page can't read the answers.

// MARK: DTOs (snake_case on the wire)

struct PortalAgentTextDTO: Encodable {
    /// Paragraphs as "[HH:MM:SS] Speaker: text", one per line.
    let format: String
    let offset: Int
    let length: Int
    let totalLength: Int
    /// Where the next page starts, when this one stopped short of the end.
    let nextOffset: Int?
    /// False while the job is still running (more text may arrive).
    let complete: Bool
    let content: String
}

struct PortalAgentTranscriptDTO: Encodable {
    let id: String
    /// queued | running | completed | failed | cancelled | interrupted
    let status: String
    /// True once the job has stopped for good (any of the last four statuses).
    let done: Bool
    let title: String?
    let sourceUrl: String
    /// "live" or "static" once the engine has decided.
    let mode: String?
    let createdAt: Date
    let startedAt: Date?
    let finishedAt: Date?
    let durationSeconds: Double?
    let processedSeconds: Double?
    /// 0…1 when the recording's length is known.
    let progress: Double?
    let queuePosition: Int?
    let message: String?
    let segmentCount: Int
    let speakers: [String]
    /// The job in the signed-in portal (needs a portal login).
    let portalUrl: String
    /// Public link — anyone holding it can open this one transcript.
    let shareUrl: String?
    let shareCanEdit: Bool?
    var reused: Bool? = nil
    var text: PortalAgentTextDTO? = nil
}

struct PortalAgentCreateBody: Decodable {
    let url: String
    let title: String?
    let language: String?
    let expectedSpeakers: Int?
    /// auto (default) | static | live
    let mode: String?
    /// none (default) | view | edit — create a share link straight away.
    let share: String?
    /// Default true: return this key's existing job for the same link
    /// instead of transcribing it again (failed/cancelled jobs don't count).
    let reuse: Bool?
}

struct PortalAgentShareBody: Decodable {
    let canEdit: Bool?
}

// MARK: - Errors

private struct AgentError: Error {
    let status: Int
    let message: String
    init(_ status: Int, _ message: String) { self.status = status; self.message = message }
}

extension PortalJobQueue {

    static let agentMaxActiveJobsPerKey = 10
    static let agentMaxWaitSeconds = 55          // Cloudflare cuts origin responses at 100 s
    static let agentMaxOpenWaitsPerKey = 4
    static let agentDefaultMaxChars = 50_000
    static let agentMaxMaxChars = 200_000

    // MARK: Entry point

    /// Everything under /api/agent. Called before the Access identity check.
    func handleAgent(_ request: PortalHTTPRequest) async -> PortalHTTPResponse {
        let c = request.pathComponents            // ["api", "agent", …]
        let r = Array(c.dropFirst(2))
        let method = request.method

        if method == "GET" && r == ["v1", "openapi.json"] {
            return PortalHTTPResponse.jsonData(Data(Self.agentOpenAPI(base: agentBaseURL(request)).utf8))
        }

        guard let presented = PortalAgentKeyStore.presentedKey(request),
              let key = PortalAgentKeyStore.shared.authenticate(presented) else {
            agentLogRejected(request)
            var resp = PortalHTTPResponse.error(401, "Missing or unknown API key. Send it as \"Authorization: Bearer <key>\"; keys are created in StreamScribe's Settings → Agent API.")
            resp.headers.append(("WWW-Authenticate", "Bearer realm=\"StreamScribe\""))
            return resp
        }
        let who = PortalIdentity(email: key.submitterName, isLocal: false, agentKeyID: key.id)

        if r.first == "mcp" && r.count == 1 {
            return await handleMCP(request, key: key, who: who)
        }
        guard r.first == "v1" else { return .error(404, "Not found") }
        let v = Array(r.dropFirst())

        do {
            switch (method, v.count) {
            case ("GET", 0):
                return agentJSON(["name": "StreamScribe agent API", "version": "1",
                                  "key": key.label, "docs": agentBaseURL(request) + "/api/agent/v1/openapi.json"])
            case ("GET", 1) where v[0] == "transcripts":
                let limit = min(max(Int(request.query["limit"] ?? "") ?? 20, 1), 100)
                return agentJSON(agentList(key: key, limit: limit, base: agentBaseURL(request)))
            case ("POST", 1) where v[0] == "transcripts":
                guard let body = try? Self.agentDecoder.decode(PortalAgentCreateBody.self, from: request.body) else {
                    throw AgentError(400, "Expected JSON like {\"url\": \"https://…\"}")
                }
                let (dto, created) = try await agentCreate(body, key: key, who: who, base: agentBaseURL(request))
                return agentJSON(dto, status: created ? 201 : 200)
            default:
                break
            }

            guard v.count >= 2, v[0] == "transcripts" else { throw AgentError(404, "Not found") }
            let job = try agentJob(v[1], key: key)
            let action = v.count >= 3 ? v[2] : ""
            switch (method, action, v.count) {
            case ("GET", "", 2):
                let wait = Double(request.query["wait"] ?? "") ?? 0
                let includeText = ["1", "true", "yes"].contains((request.query["text"] ?? "").lowercased())
                let offset = Int(request.query["offset"] ?? "") ?? 0
                let maxChars = Int(request.query["max_chars"] ?? "") ?? Self.agentDefaultMaxChars
                try await agentWait(job.id, seconds: wait, key: key)
                return agentJSON(agentDTO(latestAgentJob(job), base: agentBaseURL(request),
                                          text: includeText ? (offset, maxChars) : nil))
            case ("GET", "export", 3):
                return exportResponse(latestAgentJob(job), request)
            case ("POST", "share", 3):
                var canEdit: Bool? = nil
                if !request.body.isEmpty {
                    guard let body = try? Self.agentDecoder.decode(PortalAgentShareBody.self, from: request.body) else {
                        throw AgentError(400, "Expected {\"can_edit\": true|false}")
                    }
                    canEdit = body.canEdit
                }
                let j = setShareLink(job.id, canEdit: canEdit, by: who) ?? job
                return agentJSON(agentDTO(j, base: agentBaseURL(request)))
            case ("POST", "cancel", 3):
                return agentJSON(try agentCancel(job, who: who, base: agentBaseURL(request)))
            default:
                throw AgentError(404, "Not found")
            }
        } catch let e as AgentError {
            return .error(e.status, e.message)
        } catch {
            return .error(500, "Unexpected error")
        }
    }

    // MARK: Operations (shared by REST and MCP)

    private func agentCreate(_ body: PortalAgentCreateBody, key: PortalAgentKey, who: PortalIdentity,
                             base: String) async throws -> (PortalAgentTranscriptDTO, Bool) {
        let checked = Self.validateSubmittedURL(body.url)
        guard let url = checked.url else { throw AgentError(422, checked.problem ?? "Invalid link") }
        // Anyone holding a key can make the Mac fetch a link, so — unlike a
        // signed-in colleague — an agent may not point it at this Mac or the
        // network around it. (Redirects are followed by the downloaders and
        // aren't re-checked; this stops the direct case.)
        if let host = url.host, let problem = await Self.agentHostProblem(host) {
            throw AgentError(422, problem)
        }

        let share = (body.share ?? "none").lowercased()
        guard ["none", "view", "edit"].contains(share) else {
            throw AgentError(422, "share must be none, view or edit")
        }

        if body.reuse ?? true,
           let existing = jobs.last(where: {
               $0.agentKeyID == key.id && $0.input == url.absoluteString
                   && ![.failed, .cancelled, .interrupted].contains($0.status)
           }) {
            var j = existing
            if share != "none" { j = setShareLink(j.id, canEdit: share == "edit", by: who) ?? j }
            var dto = agentDTO(j, base: base)
            dto.reused = true
            return (dto, false)
        }

        let active = jobs.filter { $0.agentKeyID == key.id && !$0.status.isTerminal }.count
        guard active < Self.agentMaxActiveJobsPerKey else {
            throw AgentError(429, "This key already has \(active) transcripts waiting or running. Wait for some to finish (or cancel them) first.")
        }

        var settings = PortalJobSettings()
        let mode = (body.mode ?? "auto").lowercased()
        guard ["auto", "static", "live"].contains(mode) else { throw AgentError(422, "mode must be auto, static or live") }
        settings.mode = mode
        if let lang = body.language?.trimmingCharacters(in: .whitespaces), !lang.isEmpty { settings.language = lang.lowercased() }
        settings.expectedSpeakers = body.expectedSpeakers
        if let problem = settings.validationError() ?? modelProblem(settings) { throw AgentError(422, problem) }

        var job = PortalJob(input: url.absoluteString, displaySource: url.absoluteString,
                            isUpload: false, uploadDirectory: nil,
                            settings: settings, submittedBy: who.email)
        job.agentKeyID = key.id
        if let t = body.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            job.title = String(t.components(separatedBy: .controlCharacters).joined(separator: " ").prefix(200))
        }
        update(job, saveNow: true)
        print("[Portal] \(who.email) queued \(url.absoluteString)")
        if share != "none" { job = setShareLink(job.id, canEdit: share == "edit", by: who) ?? job }
        pump()
        return (agentDTO(self.job(job.id) ?? job, base: base), true)
    }

    private func agentJob(_ rawID: String, key: PortalAgentKey) throws -> PortalJob {
        // Another key's job (or a person's) answers exactly like a missing one.
        guard let id = UUID(uuidString: rawID), let job = job(id), job.agentKeyID == key.id else {
            throw AgentError(404, "No transcript with that id for this key")
        }
        return job
    }

    private func agentList(key: PortalAgentKey, limit: Int, base: String) -> [String: [PortalAgentTranscriptDTO]] {
        let mine = jobs.filter { $0.agentKeyID == key.id }.suffix(limit).reversed()
        return ["transcripts": mine.map { agentDTO($0, base: base) }]
    }

    private func agentCancel(_ job: PortalJob, who: PortalIdentity, base: String) throws -> PortalAgentTranscriptDTO {
        guard !job.status.isTerminal else { throw AgentError(409, "This transcript has already finished") }
        let resp = stopJob(job, who)
        guard resp.status < 300 else { throw AgentError(resp.status, "Couldn't cancel this transcript") }
        return agentDTO(self.job(job.id) ?? job, base: base)
    }

    /// Holds the request until the job stops, up to `seconds` (capped). A key
    /// may hold only a few of these open at once.
    private func agentWait(_ id: UUID, seconds: Double, key: PortalAgentKey) async throws {
        let limit = min(max(seconds.isFinite ? seconds : 0, 0), Double(Self.agentMaxWaitSeconds))
        guard limit > 0 else { return }
        guard Self.agentOpenWaits[key.id, default: 0] < Self.agentMaxOpenWaitsPerKey else {
            throw AgentError(429, "This key already has \(Self.agentMaxOpenWaitsPerKey) waits open. Wait on fewer transcripts at once.")
        }
        Self.agentOpenWaits[key.id, default: 0] += 1
        defer {
            Self.agentOpenWaits[key.id, default: 1] -= 1
            if Self.agentOpenWaits[key.id] ?? 0 <= 0 { Self.agentOpenWaits[key.id] = nil }
        }
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline, !Task.isCancelled {
            guard let j = job(id), !j.status.isTerminal else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private static var agentOpenWaits: [UUID: Int] = [:]

    /// Revoking a key stops its queued and running jobs (Settings → Agent API).
    func cancelAgentJobs(of key: PortalAgentKey) {
        let who = PortalIdentity(email: key.submitterName, isLocal: false, agentKeyID: key.id)
        for job in jobs where job.agentKeyID == key.id && !job.status.isTerminal {
            _ = stopJob(job, who)
        }
    }

    /// Why an agent may not submit a link to `host`, or nil. Resolves the
    /// name (off the main thread) and refuses loopback, private, link-local,
    /// carrier-grade NAT, multicast and other non-public addresses, in both
    /// IPv4 and IPv6, including numeric spellings like 0x7f000001.
    static func agentHostProblem(_ host: String) async -> String? {
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        // Numeric addresses are checked as written — a resolver may refuse an
        // IPv6 literal on a machine without IPv6, which must not mean "allowed".
        var v6 = in6_addr()
        if inet_pton(AF_INET6, name, &v6) == 1 {
            return isPublicAddress(withUnsafeBytes(of: &v6) { Array($0) }) ? nil : "Links to this Mac or its local network aren't allowed"
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, name, &v4) == 1 {
            return isPublicAddress(withUnsafeBytes(of: &v4) { Array($0) }) ? nil : "Links to this Mac or its local network aren't allowed"
        }
        let addresses = await Task.detached(priority: .userInitiated) { () -> [[UInt8]] in
            var hints = addrinfo()
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(name, nil, &hints, &res) == 0, let first = res else { return [] }
            defer { freeaddrinfo(first) }
            var out: [[UInt8]] = []
            var cur: UnsafeMutablePointer<addrinfo>? = first
            while let ai = cur {
                if let sa = ai.pointee.ai_addr {
                    if Int32(sa.pointee.sa_family) == AF_INET {
                        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                            var a = p.pointee.sin_addr
                            out.append(withUnsafeBytes(of: &a) { Array($0) })
                        }
                    } else if Int32(sa.pointee.sa_family) == AF_INET6 {
                        sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                            var a = p.pointee.sin6_addr
                            out.append(withUnsafeBytes(of: &a) { Array($0) })
                        }
                    }
                }
                cur = ai.pointee.ai_next
            }
            return out
        }.value
        // An unresolvable name can't be fetched either; let the job fail normally.
        for a in addresses where !isPublicAddress(a) {
            return "Links to this Mac or its local network aren't allowed"
        }
        return nil
    }

    static func isPublicAddress(_ a: [UInt8]) -> Bool {
        if a.count == 4 {
            let (b0, b1) = (a[0], a[1])
            if b0 == 0 || b0 == 10 || b0 == 127 || b0 >= 224 { return false }          // this-net, private, loopback, multicast/reserved
            if b0 == 100 && (b1 & 0xC0) == 64 { return false }                          // 100.64/10 carrier-grade NAT
            if b0 == 169 && b1 == 254 { return false }                                  // link-local
            if b0 == 172 && (b1 & 0xF0) == 16 { return false }                          // 172.16/12
            if b0 == 192 && b1 == 168 { return false }                                  // 192.168/16
            if b0 == 192 && b1 == 0 && a[2] == 0 { return false }                       // 192.0.0/24 protocol assignments
            if b0 == 198 && (b1 & 0xFE) == 18 { return false }                          // 198.18/15 benchmarking
            return true
        }
        guard a.count == 16 else { return false }
        if a.allSatisfy({ $0 == 0 }) { return false }                                    // ::
        if a[0..<15].allSatisfy({ $0 == 0 }) && a[15] == 1 { return false }             // ::1
        if a[0..<10].allSatisfy({ $0 == 0 }) && a[10] == 0xFF && a[11] == 0xFF {        // ::ffff:v4
            return isPublicAddress(Array(a[12..<16]))
        }
        if a[0] == 0xFF { return false }                                                 // multicast
        if a[0] == 0xFE && (a[1] & 0xC0) == 0x80 { return false }                        // fe80::/10 link-local
        if (a[0] & 0xFE) == 0xFC { return false }                                        // fc00::/7 unique local
        if a[0] == 0x00 && a[1] == 0x64 && a[2] == 0xFF && a[3] == 0x9B {                // 64:ff9b::/96 NAT64
            return isPublicAddress(Array(a[12..<16]))
        }
        return true
    }

    private func latestAgentJob(_ job: PortalJob) -> PortalJob {
        syncIfAttached(job)
        return self.job(job.id) ?? job
    }

    // MARK: DTO building

    private func agentDTO(_ job: PortalJob, base: String, text: (offset: Int, maxChars: Int)? = nil) -> PortalAgentTranscriptDTO {
        let status: String
        switch job.status {
        case .queued: status = "queued"
        case .preparing, .running, .finishing: status = "running"
        default: status = job.status.rawValue
        }
        var position: Int? = nil
        if job.status == .queued {
            position = (jobs.filter { $0.status == .queued }.firstIndex { $0.id == job.id } ?? 0) + 1
        }
        var progress: Double? = nil
        if job.status == .completed {
            progress = 1
        } else if let d = job.durationSeconds, d > 0, d.isFinite, let p = job.processedSeconds, p.isFinite {
            progress = min(max(p / d, 0), 1)
        }
        var speakers: [String] = []
        for seg in job.segments {
            guard let name = job.displayName(for: seg.speaker), !speakers.contains(name) else { continue }
            speakers.append(name)
        }
        var dto = PortalAgentTranscriptDTO(
            id: job.id.uuidString, status: status, done: job.status.isTerminal,
            title: job.title, sourceUrl: job.displaySource, mode: job.resolvedMode,
            createdAt: job.createdAt, startedAt: job.startedAt, finishedAt: job.finishedAt,
            durationSeconds: job.durationSeconds.flatMap { $0.isFinite ? $0 : nil },
            processedSeconds: job.processedSeconds.flatMap { $0.isFinite ? $0 : nil },
            // Generic notes only: raw errors carry local paths, and "Stopped by" an email.
            progress: progress, queuePosition: position, message: Self.publicMessage(job),
            segmentCount: job.segments.count, speakers: speakers,
            portalUrl: base + "/#/job/" + job.id.uuidString,
            shareUrl: job.shareToken.map { base + "/s/" + $0 },
            shareCanEdit: job.shareToken == nil ? nil : job.shareAllowsEdits)
        if let text {
            dto.text = Self.agentTextPage(Self.agentText(job), offset: text.offset,
                                          maxChars: text.maxChars, complete: job.status.isTerminal)
        }
        return dto
    }

    /// Paragraph per speaker turn: "[HH:MM:SS] Name: text". Long turns are
    /// split about every 1,000 characters so timestamps stay useful.
    static func agentText(_ job: PortalJob) -> String {
        var lines: [String] = []
        var name: String? = nil
        var start: Double = 0
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            lines.append("[\(stamp(start))] " + (name.map { "\($0): " } ?? "") + buffer)
            buffer = ""
        }
        for seg in job.segments {
            let t = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let n = job.displayName(for: seg.speaker)
            if buffer.isEmpty || n != name || buffer.count >= 1000 {
                flush()
                name = n
                start = seg.start.isFinite ? seg.start : 0
                buffer = t
            } else {
                buffer += " " + t
            }
        }
        flush()
        return lines.joined(separator: "\n")
    }

    static func agentTextPage(_ full: String, offset rawOffset: Int, maxChars rawMax: Int, complete: Bool) -> PortalAgentTextDTO {
        let total = full.count
        let offset = min(max(rawOffset, 0), total)
        let maxChars = min(max(rawMax, 1), agentMaxMaxChars)
        let startIdx = full.index(full.startIndex, offsetBy: offset)
        let endIdx = full.index(startIdx, offsetBy: maxChars, limitedBy: full.endIndex) ?? full.endIndex
        let slice = String(full[startIdx..<endIdx])
        let end = offset + slice.count
        return PortalAgentTextDTO(format: "[HH:MM:SS] Speaker: text", offset: offset, length: slice.count,
                                  totalLength: total, nextOffset: end < total ? end : nil,
                                  complete: complete, content: slice)
    }

    private static func stamp(_ t: Double) -> String {
        let s = Int(max(t, 0))
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    // MARK: Plumbing

    /// Public origin for links handed back to the agent: the host the request
    /// arrived on (Cloudflare passes the public hostname through), https when
    /// it came through Cloudflare.
    func agentBaseURL(_ request: PortalHTTPRequest) -> String {
        // Host only: Cloudflare passes a client's own X-Forwarded-Host through.
        let raw = (request.header("host") ?? "")
            .split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let hostOK = !raw.isEmpty && raw.count <= 253
            && raw.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-:[]".contains($0)) }
        let viaProxy = request.header("cf-ray") != nil
            || request.header("x-forwarded-proto")?.lowercased() == "https"
        if hostOK { return (viaProxy ? "https://" : "http://") + raw.lowercased() }
        let d = UserDefaults.standard
        let port = d.object(forKey: Self.portKey) == nil ? Self.defaultPort : d.integer(forKey: Self.portKey)
        return "http://127.0.0.1:\(port)"
    }

    static let agentEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let agentDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private func agentJSON<T: Encodable>(_ value: T, status: Int = 200) -> PortalHTTPResponse {
        guard let data = try? Self.agentEncoder.encode(value) else { return .error(500, "Encoding failed") }
        return PortalHTTPResponse.jsonData(data, status: status)
    }

    private func agentLogRejected(_ request: PortalHTTPRequest) {
        let now = Date()
        guard now.timeIntervalSince(Self.agentLastRejectLog) > 60 else { return }
        Self.agentLastRejectLog = now
        let ip = (request.header("cf-connecting-ip") ?? "local").filter { $0.isASCII && !$0.isNewline }.prefix(64)
        print("[Portal] Agent API: refused a request without a valid key from \(ip) (logged at most once a minute).")
    }

    private static var agentLastRejectLog = Date.distantPast

    // MARK: - MCP (Streamable HTTP, JSON responses)

    /// Only versions whose Streamable HTTP transport this matches (no SSE
    /// transport, no batches).
    private static let mcpProtocolVersions = ["2025-11-25", "2025-06-18"]

    private func handleMCP(_ request: PortalHTTPRequest, key: PortalAgentKey, who: PortalIdentity) async -> PortalHTTPResponse {
        guard request.method == "POST" else {
            // No server-initiated stream: every answer comes back on the POST.
            var resp = PortalHTTPResponse.error(405, "This MCP endpoint only accepts POST")
            resp.headers.append(("Allow", "POST"))
            return resp
        }
        // DNS-rebinding guard from the MCP spec: a browser page may only talk
        // to us from our own origin. Agents send no Origin at all.
        // Rebinding pages arrive with their own hostname in both Origin and
        // Host, so a match alone proves nothing off Cloudflare: there, only
        // the Mac's own loopback names count. (The API key is still required.)
        if let origin = request.header("origin"), !origin.isEmpty {
            let viaCloudflare = request.header("cf-ray") != nil
            guard origin.lowercased() == agentBaseURL(request),
                  viaCloudflare || Self.isLoopbackHost(request.header("host")) else {
                return .error(403, "Cross-origin MCP requests aren't allowed")
            }
        }
        if let v = request.header("mcp-protocol-version"), !v.isEmpty, !Self.mcpProtocolVersions.contains(v) {
            return .error(400, "Unsupported MCP-Protocol-Version \(v.prefix(32)); this server speaks \(Self.mcpProtocolVersions.joined(separator: ", "))")
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: request.body) else {
            return mcpReply(["jsonrpc": "2.0", "id": NSNull(),
                             "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let msg = parsed as? [String: Any] else {
            return mcpReply(["jsonrpc": "2.0", "id": NSNull(),
                             "error": ["code": -32600, "message": "Batches aren't supported; send one JSON-RPC message per request"]])
        }
        guard let method = msg["method"] as? String else {
            // A response or something unrecognisable from the client: nothing to answer.
            return PortalHTTPResponse(status: 202, headers: [], body: Data())
        }
        guard let id = msg["id"] else {
            // Notifications (initialized, cancelled, …) get 202 and no body.
            return PortalHTTPResponse(status: 202, headers: [], body: Data())
        }
        guard id is String || id is NSNumber else {
            return mcpReply(["jsonrpc": "2.0", "id": NSNull(),
                             "error": ["code": -32600, "message": "Request id must be a string or number"]])
        }
        let params = msg["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let version = Self.mcpProtocolVersions.contains(asked) ? asked : Self.mcpProtocolVersions[1]
            return mcpReply(["jsonrpc": "2.0", "id": id, "result": [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "StreamScribe", "version": "1.0"],
                "instructions": Self.mcpInstructions,
            ] as [String: Any]])
        case "ping":
            return mcpReply(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
        case "tools/list":
            return mcpReply(["jsonrpc": "2.0", "id": id, "result": ["tools": Self.mcpTools]])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return mcpReply(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Missing tool name"]])
            }
            guard Self.mcpTools.contains(where: { $0["name"] as? String == name }) else {
                return mcpReply(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Unknown tool: \(name.prefix(64))"]])
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let result = await mcpCall(name, args, key: key, who: who, base: agentBaseURL(request))
            return mcpReply(["jsonrpc": "2.0", "id": id, "result": result])
        default:
            return mcpReply(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private func mcpReply(_ object: [String: Any]) -> PortalHTTPResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return .error(500, "Encoding failed")
        }
        return PortalHTTPResponse.jsonData(data)
    }

    private func mcpCall(_ name: String, _ args: [String: Any], key: PortalAgentKey,
                         who: PortalIdentity, base: String) async -> [String: Any] {
        func str(_ k: String) -> String? { args[k] as? String }
        func int(_ k: String) -> Int? { (args[k] as? NSNumber)?.intValue ?? (args[k] as? String).flatMap { Int($0) } }
        func bool(_ k: String) -> Bool? { (args[k] as? NSNumber)?.boolValue }
        do {
            switch name {
            case "request_transcript":
                guard let url = str("url") else { throw AgentError(422, "url is required") }
                let body = PortalAgentCreateBody(url: url, title: str("title"), language: str("language"),
                                                 expectedSpeakers: int("expected_speakers"), mode: str("mode"),
                                                 share: str("share"), reuse: bool("reuse"))
                let (dto, _) = try await agentCreate(body, key: key, who: who, base: base)
                return try mcpResult(dto)
            case "get_transcript":
                let job = try agentJob(str("id") ?? "", key: key)
                try await agentWait(job.id, seconds: Double(int("wait_seconds") ?? 0), key: key)
                let includeText = bool("include_text") ?? true
                let dto = agentDTO(latestAgentJob(job), base: base,
                                   text: includeText ? (int("text_offset") ?? 0, int("max_chars") ?? Self.agentDefaultMaxChars) : nil)
                return try mcpResult(dto)
            case "create_share_link":
                let job = try agentJob(str("id") ?? "", key: key)
                // Omitted can_edit keeps an existing link's permission (new links are view-only).
                let j = setShareLink(job.id, canEdit: bool("can_edit"), by: who) ?? job
                return try mcpResult(agentDTO(j, base: base))
            case "list_transcripts":
                let limit = min(max(int("limit") ?? 10, 1), 50)
                return try mcpResult(agentList(key: key, limit: limit, base: base))
            case "cancel_transcript":
                let job = try agentJob(str("id") ?? "", key: key)
                return try mcpResult(try agentCancel(job, who: who, base: base))
            default:
                throw AgentError(404, "Unknown tool \(name)")
            }
        } catch let e as AgentError {
            return ["content": [["type": "text", "text": e.message]], "isError": true]
        } catch {
            return ["content": [["type": "text", "text": "Unexpected error"]], "isError": true]
        }
    }

    /// The DTO as structured content, plus text blocks for clients that only
    /// read text: the metadata as JSON, then the transcript itself unescaped.
    private func mcpResult<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try Self.agentEncoder.encode(value)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError(500, "Encoding failed")
        }
        var content: [[String: Any]] = []
        var transcript: String? = nil
        if var text = object["text"] as? [String: Any], let body = text["content"] as? String {
            transcript = body
            text["content"] = "(transcript text follows in the next content block)"
            object["text"] = text
        }
        let meta = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        content.append(["type": "text", "text": String(decoding: meta, as: UTF8.self)])
        if let transcript { content.append(["type": "text", "text": transcript.isEmpty ? "(no speech transcribed yet)" : transcript]) }
        // structuredContent mirrors the first block (metadata); the transcript
        // itself is sent once, in the second block, not twice.
        return ["content": content, "structuredContent": object, "isError": false]
    }

    private static let mcpInstructions = """
        StreamScribe transcribes broadcast and web video/audio links (YouTube, C-SPAN, \
        Critical Mention, congressional and agency sites, X, direct media files) on a Mac \
        and returns speaker-labelled transcripts. Typical use: call request_transcript \
        with the link, then call get_transcript with that id and wait_seconds 50, again \
        and again, until done is true. Recorded videos usually take a fraction of their \
        running time; livestreams run until the broadcast ends (partial text is \
        available while running). Long transcripts are paged: when text.next_offset is \
        set, call get_transcript again with text_offset set to it. create_share_link \
        returns a public URL to the finished transcript that anyone can open.
        """

    private static let mcpTools: [[String: Any]] = [
        [
            "name": "request_transcript",
            "title": "Request a transcript",
            "description": "Queue a transcript of a video or audio link. Returns immediately with the transcript's id and status; use get_transcript to wait for it. By default, asking again for the same link returns the existing transcript instead of transcribing it twice.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "Full http(s) link to the broadcast, video page or media file."],
                    "title": ["type": "string", "description": "Optional title, used if StreamScribe can't find one itself."],
                    "language": ["type": "string", "description": "ISO language code such as \"en\" or \"es\", or \"auto\". Omit to use the Mac's setting."],
                    "expected_speakers": ["type": "integer", "minimum": 0, "maximum": 60, "description": "How many different voices to expect; 0 = unconstrained. Omit to use the Mac's setting."],
                    "mode": ["type": "string", "enum": ["auto", "static", "live"], "description": "auto (default) detects livestreams; static treats the link as a recording."],
                    "share": ["type": "string", "enum": ["none", "view", "edit"], "description": "Create a public share link straight away (view-only or editable). Default none."],
                    "reuse": ["type": "boolean", "description": "Default true: return this key's existing transcript of the same link if there is one."],
                ] as [String: Any],
                "required": ["url"],
            ] as [String: Any],
        ],
        [
            "name": "get_transcript",
            "title": "Get transcript status and text",
            "description": "Status, progress and text of a transcript. Set wait_seconds (up to 55) to hold the call until the job finishes or the time runs out. Text is returned as paragraphs \"[HH:MM:SS] Speaker: text\" and paged by max_chars.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Transcript id from request_transcript."],
                    "wait_seconds": ["type": "integer", "minimum": 0, "maximum": 55, "description": "Wait up to this long for the job to finish before answering. Default 0."],
                    "include_text": ["type": "boolean", "description": "Default true. False returns status only."],
                    "text_offset": ["type": "integer", "minimum": 0, "description": "Character offset to start the text from (use text.next_offset)."],
                    "max_chars": ["type": "integer", "minimum": 1, "maximum": 200000, "description": "Most characters of text to return. Default 50000."],
                ] as [String: Any],
                "required": ["id"],
            ] as [String: Any],
        ],
        [
            "name": "create_share_link",
            "title": "Create a share link",
            "description": "Create (or return) a public link to this transcript that anyone can open without signing in, and set whether link holders can edit it. Returns share_url.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Transcript id."],
                    "can_edit": ["type": "boolean", "description": "true = anyone with the link can edit; false = view only. Omit to keep an existing link's setting (new links are view-only)."],
                ] as [String: Any],
                "required": ["id"],
            ] as [String: Any],
        ],
        [
            "name": "list_transcripts",
            "title": "List transcripts",
            "description": "This key's most recent transcripts, newest first (status only, no text).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "Default 10."],
                ] as [String: Any],
            ] as [String: Any],
        ],
        [
            "name": "cancel_transcript",
            "title": "Cancel a transcript",
            "description": "Stop a queued or running transcript. Text transcribed so far is kept.",
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "Transcript id."]] as [String: Any],
                "required": ["id"],
            ] as [String: Any],
        ],
    ]
}

// MARK: - OpenAPI description

extension PortalJobQueue {
    /// Served unauthenticated at /api/agent/v1/openapi.json — it describes the
    /// API and holds nothing secret.
    static func agentOpenAPI(base: String) -> String {
        let server = base.replacingOccurrences(of: "\"", with: "")
        return #"""
        {
          "openapi": "3.1.0",
          "info": {
            "title": "StreamScribe agent API",
            "version": "1",
            "description": "Request transcripts of video/audio links, wait for them, read them and create public share links. Authenticate with an API key from StreamScribe's Settings → Agent API, sent as 'Authorization: Bearer <key>' or 'X-API-Key: <key>'. Each key sees only the transcripts it requested. An MCP endpoint with the same operations is at /api/agent/mcp."
          },
          "servers": [{"url": "\#(server)/api/agent/v1"}],
          "security": [{"bearer": []}, {"apiKey": []}],
          "components": {
            "securitySchemes": {
              "bearer": {"type": "http", "scheme": "bearer"},
              "apiKey": {"type": "apiKey", "in": "header", "name": "X-API-Key"}
            },
            "schemas": {
              "Transcript": {
                "type": "object",
                "properties": {
                  "id": {"type": "string", "format": "uuid"},
                  "status": {"type": "string", "enum": ["queued", "running", "completed", "failed", "cancelled", "interrupted"]},
                  "done": {"type": "boolean", "description": "True once the job has stopped for good."},
                  "title": {"type": ["string", "null"]},
                  "source_url": {"type": "string"},
                  "mode": {"type": ["string", "null"], "description": "live or static, once decided."},
                  "created_at": {"type": "string", "format": "date-time"},
                  "started_at": {"type": ["string", "null"], "format": "date-time"},
                  "finished_at": {"type": ["string", "null"], "format": "date-time"},
                  "duration_seconds": {"type": ["number", "null"]},
                  "processed_seconds": {"type": ["number", "null"]},
                  "progress": {"type": ["number", "null"], "minimum": 0, "maximum": 1},
                  "queue_position": {"type": ["integer", "null"]},
                  "message": {"type": ["string", "null"]},
                  "segment_count": {"type": "integer"},
                  "speakers": {"type": "array", "items": {"type": "string"}},
                  "portal_url": {"type": "string", "description": "The job in the signed-in portal."},
                  "share_url": {"type": ["string", "null"], "description": "Public link; anyone holding it can open this transcript."},
                  "share_can_edit": {"type": ["boolean", "null"]},
                  "reused": {"type": ["boolean", "null"], "description": "True when an existing transcript of the same link was returned."},
                  "text": {"$ref": "#/components/schemas/TextPage"}
                }
              },
              "TextPage": {
                "type": "object",
                "properties": {
                  "format": {"type": "string", "description": "One paragraph per line: [HH:MM:SS] Speaker: text"},
                  "offset": {"type": "integer"},
                  "length": {"type": "integer"},
                  "total_length": {"type": "integer"},
                  "next_offset": {"type": ["integer", "null"], "description": "Pass as ?offset= for the next page."},
                  "complete": {"type": "boolean", "description": "False while the job is still running."},
                  "content": {"type": "string"}
                }
              },
              "Error": {"type": "object", "properties": {"error": {"type": "string"}}}
            }
          },
          "paths": {
            "/transcripts": {
              "post": {
                "summary": "Request a transcript of a link",
                "requestBody": {"required": true, "content": {"application/json": {"schema": {
                  "type": "object", "required": ["url"],
                  "properties": {
                    "url": {"type": "string", "description": "Full http(s) link."},
                    "title": {"type": "string"},
                    "language": {"type": "string", "description": "ISO code (en, es, …) or auto; omit for the Mac's setting."},
                    "expected_speakers": {"type": "integer", "minimum": 0, "maximum": 60},
                    "mode": {"type": "string", "enum": ["auto", "static", "live"], "default": "auto"},
                    "share": {"type": "string", "enum": ["none", "view", "edit"], "default": "none"},
                    "reuse": {"type": "boolean", "default": true, "description": "Return this key's existing transcript of the same link instead of transcribing it again."}
                  }}}}},
                "responses": {
                  "201": {"description": "Queued", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Transcript"}}}},
                  "200": {"description": "Existing transcript reused", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Transcript"}}}},
                  "422": {"description": "Invalid link or option", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Error"}}}},
                  "429": {"description": "This key has too many transcripts waiting or running"}
                }
              },
              "get": {
                "summary": "This key's recent transcripts, newest first",
                "parameters": [{"name": "limit", "in": "query", "schema": {"type": "integer", "minimum": 1, "maximum": 100, "default": 20}}],
                "responses": {"200": {"description": "List", "content": {"application/json": {"schema": {
                  "type": "object", "properties": {"transcripts": {"type": "array", "items": {"$ref": "#/components/schemas/Transcript"}}}}}}}}
              }
            },
            "/transcripts/{id}": {
              "get": {
                "summary": "Status, and optionally text; can wait for completion",
                "parameters": [
                  {"name": "id", "in": "path", "required": true, "schema": {"type": "string"}},
                  {"name": "wait", "in": "query", "description": "Hold the request up to this many seconds (max 55) until the job finishes.", "schema": {"type": "integer", "minimum": 0, "maximum": 55}},
                  {"name": "text", "in": "query", "description": "1 to include the transcript text.", "schema": {"type": "integer", "enum": [0, 1]}},
                  {"name": "offset", "in": "query", "schema": {"type": "integer", "minimum": 0}},
                  {"name": "max_chars", "in": "query", "schema": {"type": "integer", "minimum": 1, "maximum": 200000, "default": 50000}}
                ],
                "responses": {"200": {"description": "Transcript", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Transcript"}}}},
                              "404": {"description": "No transcript with that id for this key"}}
              }
            },
            "/transcripts/{id}/export": {
              "get": {
                "summary": "Download the transcript as a file",
                "parameters": [
                  {"name": "id", "in": "path", "required": true, "schema": {"type": "string"}},
                  {"name": "format", "in": "query", "schema": {"type": "string", "enum": ["docx", "txt", "md", "rtf", "srt", "vtt", "json"], "default": "docx"}},
                  {"name": "ts", "in": "query", "description": "Timestamps (1/0); other options: bold, placement, title, source, generated.", "schema": {"type": "integer"}}
                ],
                "responses": {"200": {"description": "File"}, "409": {"description": "No transcript yet"}}
              }
            },
            "/transcripts/{id}/share": {
              "post": {
                "summary": "Create (or return) the public share link",
                "parameters": [{"name": "id", "in": "path", "required": true, "schema": {"type": "string"}}],
                "requestBody": {"content": {"application/json": {"schema": {"type": "object", "properties": {"can_edit": {"type": "boolean", "default": false}}}}}},
                "responses": {"200": {"description": "Transcript with share_url", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Transcript"}}}}}
              }
            },
            "/transcripts/{id}/cancel": {
              "post": {
                "summary": "Stop a queued or running transcript (text so far is kept)",
                "parameters": [{"name": "id", "in": "path", "required": true, "schema": {"type": "string"}}],
                "responses": {"200": {"description": "Transcript"}, "409": {"description": "Already finished"}}
              }
            }
          }
        }
        """#
    }
}
