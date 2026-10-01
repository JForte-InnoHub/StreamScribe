import Foundation
import Network

// MARK: - StreamScribe Web Portal — HTTP layer
//
// A deliberately small HTTP/1.1 server on Network.framework (no package
// dependencies), in the same spirit as the OBS dock server design.
//
// SECURITY MODEL — the listener is LOOPBACK ONLY. It binds to the loopback
// interface, sets `acceptLocalOnly`, and re-checks every connection's remote
// address. Nothing on the LAN or internet can reach it directly; the only
// remote path in is `cloudflared` running on this same Mac, which forwards
// requests that Cloudflare Access has already authenticated. Identity and the
// "came through Cloudflare but WITHOUT Access" fail-closed check live in
// PortalJobQueue.identity(for:).
//
// TRANSPORT CHOICES (made with a possible move onto a Netskope-managed LAN in
// mind):
//   - Every response is `Connection: close`. No keep-alive state to get wrong;
//     cloudflared simply opens a fresh origin connection per request.
//   - No WebSockets. The page polls small JSON diffs instead. Polling survives
//     every proxy in the path (Cloudflare, cloudflared, and TLS-inspecting
//     corporate proxies on the *viewer's* side, which are known to break or
//     time out long-lived upgrade connections).
//   - Request bodies accept BOTH Content-Length and chunked transfer encoding,
//     because we don't control how cloudflared re-frames bodies to the origin.
//   - Bodies are capped (default 64 MB) and uploads arrive in 16 MB chunks,
//     because Cloudflare rejects any single request body over 100 MB on the
//     Free/Pro plans.

// MARK: - Request

nonisolated struct PortalHTTPRequest: Sendable {
    let method: String
    /// Raw request target as sent ("/api/jobs?x=1").
    let target: String
    /// Percent-decoded path without the query string.
    let path: String
    let query: [String: String]
    /// Header names are lowercased. Repeated headers are joined with ", ".
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Path split into non-empty components: "/api/jobs/ABC/pins" → ["api","jobs","ABC","pins"].
    var pathComponents: [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}

// MARK: - Response

/// A byte range of a file on disk, streamed after the response head instead
/// of being held in memory (media can be gigabytes).
nonisolated struct PortalFileBody: Sendable {
    let url: URL
    let offset: Int64
    let length: Int64
}

nonisolated enum PortalByteRange: Equatable {
    case full
    case partial(start: Int64, end: Int64)   // inclusive
    case unsatisfiable

    /// Parse a `Range` header against a file of `size` bytes. Single ranges
    /// only ("bytes=0-499", "bytes=500-", "bytes=-500"); anything else is
    /// served whole, which RFC 9110 permits.
    static func parse(_ header: String?, size: Int64) -> PortalByteRange {
        guard let header = header?.trimmingCharacters(in: .whitespaces),
              header.lowercased().hasPrefix("bytes=") else { return .full }
        let spec = header.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(",") else { return .full }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .full }
        let a = parts[0].trimmingCharacters(in: .whitespaces)
        let b = parts[1].trimmingCharacters(in: .whitespaces)
        guard size > 0 else { return .unsatisfiable }
        if a.isEmpty {
            // Suffix range: the last N bytes.
            guard let n = Int64(b), n > 0 else { return .unsatisfiable }
            return .partial(start: max(0, size - n), end: size - 1)
        }
        guard let start = Int64(a), start >= 0 else { return .full }
        guard start < size else { return .unsatisfiable }
        if b.isEmpty { return .partial(start: start, end: size - 1) }
        guard let end = Int64(b), end >= start else { return .full }
        return .partial(start: start, end: min(end, size - 1))
    }
}

nonisolated struct PortalHTTPResponse: Sendable {
    var status: Int
    var headers: [(String, String)] = []
    var body: Data = Data()
    /// When set, the body is streamed from this file range and `body` is ignored.
    var file: PortalFileBody? = nil

    /// Non-finite doubles are encoded as strings rather than throwing — a NaN
    /// duration must never take the whole response down. A fresh encoder per
    /// call keeps this type free of shared mutable state (it runs off-main).
    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// A JSON response from already-encoded bytes. App model types are encoded
    /// on the main actor (see PortalJobQueue's `.dto`) because, with
    /// MainActor default isolation, their Codable conformances are
    /// MainActor-isolated; only stdlib types are encoded in here.
    static func jsonData(_ data: Data, status: Int = 200) -> PortalHTTPResponse {
        PortalHTTPResponse(
            status: status,
            headers: [("Content-Type", "application/json; charset=utf-8"),
                      ("Cache-Control", "no-store")],
            body: data)
    }

    static func json(_ value: [String: String], status: Int = 200) -> PortalHTTPResponse {
        do {
            return jsonData(try makeEncoder().encode(value), status: status)
        } catch {
            print("[Portal] JSON encode failed: \(error)")
            return PortalHTTPResponse(
                status: 500,
                headers: [("Content-Type", "application/json; charset=utf-8")],
                body: Data("{\"error\":\"Internal encoding error\"}".utf8))
        }
    }

    static func error(_ status: Int, _ message: String) -> PortalHTTPResponse {
        json(["error": message], status: status)
    }

    static func ok() -> PortalHTTPResponse { json(["ok": "true"]) }

    static func html(_ page: String) -> PortalHTTPResponse {
        PortalHTTPResponse(
            status: 200,
            headers: [("Content-Type", "text/html; charset=utf-8"),
                      ("Cache-Control", "no-store"),
                      // Everything the page needs is inline; nothing else may load.
                      ("Content-Security-Policy",
                       "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")],
            body: Data(page.utf8))
    }

    /// A downloadable file. The filename is sanitized for the ASCII fallback
    /// and percent-encoded for the RFC 5987 `filename*` form, so a title with
    /// quotes, newlines or non-Latin characters can't break the header.
    static func attachment(_ data: Data, filename: String, contentType: String) -> PortalHTTPResponse {
        PortalHTTPResponse(
            status: 200,
            headers: [("Content-Type", contentType),
                      ("Cache-Control", "no-store"),
                      ("Content-Disposition", contentDisposition(filename))],
            body: data)
    }

    static func contentDisposition(_ filename: String) -> String {
        let ascii = String(filename.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            if v < 0x20 || v > 0x7E || scalar == "\"" || scalar == "\\" || scalar == ";" { return "_" }
            return Character(scalar)
        })
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: allowed) ?? ascii
        return "attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)"
    }

    /// Serve a file (or the requested byte range of it) from disk, streamed.
    /// `downloadName` nil = play inline; otherwise save-as with that name.
    static func file(_ url: URL, contentType: String, rangeHeader: String?,
                     downloadName: String? = nil) -> PortalHTTPResponse {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return .error(404, "That file is no longer on the Mac Mini")
        }
        var headers: [(String, String)] = [
            ("Content-Type", contentType),
            ("Accept-Ranges", "bytes"),
            ("Cache-Control", "private, max-age=3600"),
        ]
        if let downloadName { headers.append(("Content-Disposition", contentDisposition(downloadName))) }
        switch PortalByteRange.parse(rangeHeader, size: size) {
        case .full:
            return PortalHTTPResponse(status: 200, headers: headers,
                                      file: PortalFileBody(url: url, offset: 0, length: size))
        case .partial(let start, let end):
            headers.append(("Content-Range", "bytes \(start)-\(end)/\(size)"))
            return PortalHTTPResponse(status: 206, headers: headers,
                                      file: PortalFileBody(url: url, offset: start, length: end - start + 1))
        case .unsatisfiable:
            return PortalHTTPResponse(status: 416, headers: [("Content-Range", "bytes */\(size)")])
        }
    }

    func serialized() -> Data {
        var out = serializedHead(contentLength: Int64(body.count))
        out.append(body)
        return out
    }

    func serializedHead(contentLength: Int64) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers {
            // Defense in depth against header injection from any computed value.
            let clean = value.replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            head += "\(name): \(clean)\r\n"
        }
        head += "Content-Length: \(contentLength)\r\n"
        head += "Connection: close\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        head += "X-Frame-Options: DENY\r\n"
        head += "\r\n"
        return Data(head.utf8)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 206: return "Partial Content"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 416: return "Range Not Satisfiable"
        case 422: return "Unprocessable Entity"
        case 410: return "Gone"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        case 505: return "HTTP Version Not Supported"
        case 507: return "Insufficient Storage"
        default: return "Status"
        }
    }
}

// MARK: - Incremental request parser
//
// Pure value type with no Network.framework dependency, so its logic can be
// exercised by a ported test harness. Works on [UInt8] rather than Data on
// purpose: Data slices keep their parent's indices, a classic source of
// off-by-N bugs in hand-written parsers.

nonisolated struct PortalRequestParser {
    nonisolated enum Outcome {
        case needMore
        case complete(PortalHTTPRequest)
        case failed(Int, String)
    }

    let maxHeaderBytes: Int
    let maxBodyBytes: Int

    /// True once a parsed head carried `Expect: 100-continue`. The connection
    /// answers with an interim 100 before the body arrives.
    private(set) var wantsContinue = false

    nonisolated private enum BodyMode { case length(Int), chunked }
    nonisolated private enum ChunkState { case size, data(Int), trailers }

    nonisolated private struct Head {
        let method: String
        let target: String
        let headers: [String: String]
        let mode: BodyMode
    }

    private var buffer: [UInt8] = []
    /// Read cursor into `buffer` for the body phase (avoids O(n) removeFirst).
    private var pos = 0
    private var head: Head?
    private var chunkState: ChunkState = .size
    private var chunkedBody: [UInt8] = []
    private var done = false

    init(maxHeaderBytes: Int = 32 * 1024, maxBodyBytes: Int = 64 * 1024 * 1024) {
        self.maxHeaderBytes = maxHeaderBytes
        self.maxBodyBytes = maxBodyBytes
    }

    mutating func feed(_ bytes: [UInt8]) -> Outcome {
        guard !done else { return .needMore }
        buffer.append(contentsOf: bytes)

        if head == nil {
            guard let end = Self.find(crlfcrlf: buffer, from: 0) else {
                if buffer.count > maxHeaderBytes { return fail(431, "Request headers too large") }
                return .needMore
            }
            if end > maxHeaderBytes { return fail(431, "Request headers too large") }
            switch parseHead(Array(buffer[0..<end])) {
            case .success(let h): head = h
            case .failure(let f): return fail(f.status, f.message)
            }
            pos = end + 4
        }

        guard let h = head else { return .needMore }
        switch h.mode {
        case .length(let n):
            guard buffer.count - pos >= n else { return .needMore }
            let body = Data(buffer[pos..<(pos + n)])
            return finish(h, body: body)
        case .chunked:
            return advanceChunked(h)
        }
    }

    // MARK: Head

    nonisolated private struct HeadFailure: Error { let status: Int; let message: String }

    private mutating func parseHead(_ bytes: [UInt8]) -> Result<Head, HeadFailure> {
        guard let text = String(bytes: bytes, encoding: .utf8)
                ?? String(bytes: bytes, encoding: .isoLatin1) else {
            return .failure(HeadFailure(status: 400, message: "Unreadable request head"))
        }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else {
            return .failure(HeadFailure(status: 400, message: "Malformed request line"))
        }
        let method = parts[0].uppercased()
        let target = String(parts[1])
        guard parts[2].hasPrefix("HTTP/1.") else {
            return .failure(HeadFailure(status: 505, message: "Only HTTP/1.x is supported"))
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                return .failure(HeadFailure(status: 400, message: "Malformed header line"))
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                return .failure(HeadFailure(status: 400, message: "Empty header name"))
            }
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        let mode: BodyMode
        if let te = headers["transfer-encoding"]?.lowercased(), te.contains("chunked") {
            mode = .chunked
        } else if let cl = headers["content-length"] {
            // A repeated Content-Length arrives joined as "5, 5" — treat any
            // non-integer as malformed rather than guessing (request smuggling
            // guard, even though only cloudflared can reach us).
            guard let n = Int(cl), n >= 0 else {
                return .failure(HeadFailure(status: 400, message: "Invalid Content-Length"))
            }
            guard n <= maxBodyBytes else {
                return .failure(HeadFailure(status: 413, message: "Request body too large (limit \(maxBodyBytes / (1024 * 1024)) MB)"))
            }
            mode = .length(n)
        } else {
            mode = .length(0)
        }

        wantsContinue = headers["expect"]?.lowercased() == "100-continue"
        return .success(Head(method: method, target: target, headers: headers, mode: mode))
    }

    // MARK: Chunked body

    private mutating func advanceChunked(_ h: Head) -> Outcome {
        while true {
            switch chunkState {
            case .size:
                guard let lineEnd = Self.find(crlf: buffer, from: pos) else {
                    if buffer.count - pos > 1024 { return fail(400, "Malformed chunk size line") }
                    return .needMore
                }
                let line = String(decoding: buffer[pos..<lineEnd], as: UTF8.self)
                pos = lineEnd + 2
                let hex = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                    .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard !hex.isEmpty, let size = Int(hex, radix: 16), size >= 0 else {
                    return fail(400, "Malformed chunk size")
                }
                if size == 0 {
                    chunkState = .trailers
                } else {
                    guard chunkedBody.count + size <= maxBodyBytes else {
                        return fail(413, "Request body too large (limit \(maxBodyBytes / (1024 * 1024)) MB)")
                    }
                    chunkState = .data(size)
                }
            case .data(let size):
                guard buffer.count - pos >= size + 2 else { return .needMore }
                chunkedBody.append(contentsOf: buffer[pos..<(pos + size)])
                guard buffer[pos + size] == 13, buffer[pos + size + 1] == 10 else {
                    return fail(400, "Chunk missing terminating CRLF")
                }
                pos += size + 2
                chunkState = .size
            case .trailers:
                guard let lineEnd = Self.find(crlf: buffer, from: pos) else {
                    if buffer.count - pos > 8 * 1024 { return fail(400, "Trailers too large") }
                    return .needMore
                }
                let isEmptyLine = (lineEnd == pos)
                pos = lineEnd + 2
                if isEmptyLine {
                    return finish(h, body: Data(chunkedBody))
                }
            }
        }
    }

    // MARK: Helpers

    private mutating func finish(_ h: Head, body: Data) -> Outcome {
        done = true
        let (path, query) = Self.splitTarget(h.target)
        return .complete(PortalHTTPRequest(
            method: h.method, target: h.target, path: path, query: query,
            headers: h.headers, body: body))
    }

    private mutating func fail(_ status: Int, _ message: String) -> Outcome {
        done = true
        return .failed(status, message)
    }

    static func splitTarget(_ target: String) -> (String, [String: String]) {
        var raw = target
        // Absolute-form ("http://host/path?q") — take path + query only.
        if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://"),
           let url = URL(string: raw) {
            raw = url.path.isEmpty ? "/" : url.path
            if let q = url.query { raw += "?" + q }
        }
        let pieces = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = pieces.first.map(String.init) ?? "/"
        let path = rawPath.removingPercentEncoding ?? rawPath
        var query: [String: String] = [:]
        if pieces.count == 2 {
            for pair in pieces[1].split(separator: "&", omittingEmptySubsequences: true) {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = decodeQueryComponent(String(kv[0]))
                let value = kv.count > 1 ? decodeQueryComponent(String(kv[1])) : ""
                if !key.isEmpty { query[key] = value }
            }
        }
        return (path.isEmpty ? "/" : path, query)
    }

    static func decodeQueryComponent(_ s: String) -> String {
        let spaced = s.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    static func find(crlfcrlf b: [UInt8], from start: Int) -> Int? {
        guard b.count >= 4, start <= b.count - 4 else { return nil }
        var i = start
        while i <= b.count - 4 {
            if b[i] == 13, b[i + 1] == 10, b[i + 2] == 13, b[i + 3] == 10 { return i }
            i += 1
        }
        return nil
    }

    static func find(crlf b: [UInt8], from start: Int) -> Int? {
        guard b.count >= 2, start <= b.count - 2 else { return nil }
        var i = start
        while i <= b.count - 2 {
            if b[i] == 13, b[i + 1] == 10 { return i }
            i += 1
        }
        return nil
    }
}

// MARK: - Server

nonisolated enum PortalServerState: Equatable, Sendable {
    case stopped
    case starting
    case running(port: UInt16)
    case failed(String)

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running(let port): return "Running on 127.0.0.1:\(port)"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }
}

nonisolated final class PortalServer: @unchecked Sendable {
    typealias Handler = @Sendable (PortalHTTPRequest) async -> PortalHTTPResponse

    private let queue = DispatchQueue(label: "streamscribe.portal.server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: PortalConnection] = [:]
    private let maxBodyBytes: Int

    init(maxBodyBytes: Int = 64 * 1024 * 1024) {
        self.maxBodyBytes = maxBodyBytes
    }

    /// Start listening on the loopback interface. `onState` is delivered on the main actor.
    func start(port: UInt16, handler: @escaping Handler,
               onState: @escaping @Sendable @MainActor (PortalServerState) -> Void) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port), port > 0 else {
            Task { @MainActor in onState(.failed("Invalid port \(port)")) }
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only: never reachable from the LAN. cloudflared on this Mac
        // is the only remote path in.
        params.requiredInterfaceType = .loopback
        params.acceptLocalOnly = true

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in onState(.failed(message)) }
            return
        }
        queue.sync { self.listener = listener }
        Task { @MainActor in onState(.starting) }

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            // Ignore late callbacks from a listener that has since been
            // replaced (a port change): its `.cancelled` would otherwise land
            // after the new listener's `.ready` and show "Stopped".
            guard let self, let listener, self.listener === listener else { return }
            let mapped: PortalServerState?
            switch state {
            case .ready: mapped = .running(port: port)
            case .failed(let err): mapped = .failed(err.localizedDescription)
            case .cancelled: mapped = .stopped
            default: mapped = nil
            }
            if let mapped {
                print("[Portal] Listener: \(mapped.label)")
                Task { @MainActor in onState(mapped) }
            }
        }

        listener.newConnectionHandler = { [weak self] nwConnection in
            guard let self else { nwConnection.cancel(); return }
            guard Self.isLoopback(nwConnection.endpoint) else {
                print("[Portal] Rejected non-loopback connection from \(nwConnection.endpoint)")
                nwConnection.cancel()
                return
            }
            let conn = PortalConnection(connection: nwConnection, queue: self.queue,
                                        maxBodyBytes: self.maxBodyBytes, handler: handler)
            let key = ObjectIdentifier(conn)
            self.connections[key] = conn
            conn.onClose = { [weak self] in
                self?.queue.async { self?.connections[key] = nil }
            }
            conn.start()
        }

        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for (_, c) in connections { c.cancel() }
            connections.removeAll()
        }
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a):
            return a.isLoopback
        case .ipv6(let a):
            if a.isLoopback { return true }
            if let mapped = a.asIPv4 { return mapped.isLoopback }
            return false
        case .name(let name, _):
            return name == "localhost" || name == "127.0.0.1" || name == "::1"
        @unknown default:
            return false
        }
    }
}

// MARK: - Connection

nonisolated final class PortalConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: PortalServer.Handler
    private var parser: PortalRequestParser
    private var finished = false
    private var sentContinue = false
    private var timeoutItem: DispatchWorkItem?
    /// Closes a response stream whose reader has stopped reading (a paused
    /// video tab that went away without resetting the connection).
    private var stallItem: DispatchWorkItem?
    private static let stallTimeout: TimeInterval = 120

    var onClose: (() -> Void)?

    /// A request that hasn't fully arrived within this window is dropped.
    /// Generous because a 16 MB upload chunk on a slow uplink takes a while.
    private static let requestTimeout: TimeInterval = 300

    init(connection: NWConnection, queue: DispatchQueue, maxBodyBytes: Int,
         handler: @escaping PortalServer.Handler) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
        self.parser = PortalRequestParser(maxBodyBytes: maxBodyBytes)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            print("[Portal] Request timed out; closing connection.")
            self.close()
        }
        timeoutItem = item
        queue.asyncAfter(deadline: .now() + Self.requestTimeout, execute: item)
        receive()
    }

    func cancel() { close() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                switch self.parser.feed([UInt8](data)) {
                case .needMore:
                    if self.parser.wantsContinue && !self.sentContinue {
                        self.sentContinue = true
                        self.connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8),
                                             completion: .contentProcessed { _ in })
                    }
                    if isComplete || error != nil { self.close(); return }
                    self.receive()
                case .complete(let request):
                    self.dispatch(request)
                case .failed(let status, let message):
                    self.respond(.error(status, message))
                }
            } else if isComplete || error != nil {
                self.close()
            } else {
                self.receive()
            }
        }
    }

    private func dispatch(_ request: PortalHTTPRequest) {
        let handler = self.handler
        let isHead = request.method == "HEAD"
        Task {
            let response = await handler(request)
            self.queue.async { self.respond(response, headOnly: isHead) }
        }
    }

    private func respond(_ response: PortalHTTPResponse, headOnly: Bool = false) {
        guard !finished else { return }
        timeoutItem?.cancel()
        guard let file = response.file else {
            let data = headOnly
                ? response.serializedHead(contentLength: Int64(response.body.count))
                : response.serialized()
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.close()
            })
            return
        }
        let head = response.serializedHead(contentLength: file.length)
        if headOnly {
            connection.send(content: head, completion: .contentProcessed { [weak self] _ in self?.close() })
            return
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file.url)
            try handle.seek(toOffset: UInt64(file.offset))
        } catch {
            respond(.error(404, "That file is no longer on the Mac Mini"))
            return
        }
        armStallTimer()
        connection.send(content: head, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { try? handle.close(); self?.close(); return }
            self.queue.async { self.streamFile(handle, remaining: file.length) }
        })
    }

    private func armStallTimer() {
        stallItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            print("[Portal] Closing a stalled download (no progress in \(Int(Self.stallTimeout))s).")
            self.close()
        }
        stallItem = item
        queue.asyncAfter(deadline: .now() + Self.stallTimeout, execute: item)
    }

    /// Send the file in 512 KB pieces, each after the previous one has been
    /// handed to the network stack, so memory stays flat and a client that
    /// goes away (a seek abandons the old request) stops the reads promptly.
    /// The per-request timeout was cancelled in respond(): it guards requests
    /// that never finish ARRIVING, not long downloads.
    private func streamFile(_ handle: FileHandle, remaining: Int64) {
        guard !finished, remaining > 0 else {
            try? handle.close()
            close()
            return
        }
        let data: Data
        do {
            data = try handle.read(upToCount: Int(min(remaining, 512 * 1024))) ?? Data()
        } catch {
            try? handle.close()
            close()
            return
        }
        guard !data.isEmpty else {
            try? handle.close()
            close()
            return
        }
        armStallTimer()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { try? handle.close(); self?.close(); return }
            self.queue.async { self.streamFile(handle, remaining: remaining - Int64(data.count)) }
        })
    }

    private func close() {
        guard !finished else { return }
        finished = true
        timeoutItem?.cancel()
        stallItem?.cancel()
        connection.cancel()
        onClose?()
        onClose = nil
    }
}
