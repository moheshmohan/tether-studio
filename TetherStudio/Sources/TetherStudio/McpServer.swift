import Foundation
import Network

/// An MCP server inside the app, so that a language model (Claude Code, Claude Desktop, any MCP client)
/// can do what the window does: the app holds the camera and the board, so it is the one to ask.
///
/// Transport: MCP "Streamable HTTP" at `http://127.0.0.1:<port>/mcp`, answering each JSON-RPC request
/// with one JSON reply (no event stream). It listens on the loopback address only, wants
/// `Authorization: Bearer <token>` (the token is made once and kept in Application Support, readable
/// by this user only), and turns away requests whose Origin is a web page (DNS rebinding).
final class McpServer: @unchecked Sendable {
    static let shared = McpServer()
    static let defaultPort: UInt16 = 8765
    static let path = "/mcp"
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "tether.mcp")
    /// Runs one tools/call on the main actor; set by the app.
    var handler: (@Sendable (String, [String: Any]) async -> McpToolResult)?
    var tools: () -> [[String: Any]] = { [] }
    private(set) var port: UInt16 = McpServer.defaultPort
    var log: (@Sendable (String) -> Void)?

    static var tokenURL: URL {
        BridgeSettings.url.deletingLastPathComponent().appendingPathComponent("mcp-token")
    }

    /// The token clients must send; made on first use.
    static func token() -> String {
        let url = tokenURL
        if let text = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 32 {
            return text
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        return token
    }

    var url: String { "http://127.0.0.1:\(port)\(Self.path)" }

    func start(port: UInt16 = McpServer.defaultPort) {
        stop()
        self.port = port
        _ = Self.token()        // made now, so a client can be set up before the first call
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.log?("MCP server listening on \(self?.url ?? "")")
                case .failed(let e): self?.log?("MCP server failed: \(e.localizedDescription)")
                default: break
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            log?("MCP server not started: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - HTTP

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let request = HttpRequest.parse(buf) {
                self.respond(to: request, on: conn) { keepAlive in
                    if keepAlive { self.receive(conn, buffer: request.rest) } else { conn.cancel() }
                }
            } else if error != nil || done || buf.count > 8 << 20 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func send(_ conn: NWConnection, status: Int, body: Data?, extra: [String: String] = [:], then: @escaping (Bool) -> Void) {
        let reason = [200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized",
                      403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body?.count ?? 0)\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        if let body { out.append(body) }
        conn.send(content: out, completion: .contentProcessed { _ in then(status < 400) })
    }

    private func respond(to req: HttpRequest, on conn: NWConnection, then: @escaping (Bool) -> Void) {
        if let origin = req.headers["origin"], !Self.originAllowed(origin) {
            return send(conn, status: 403, body: Self.json(["error": "origin not allowed"]), then: then)
        }
        guard req.path.split(separator: "?").first.map(String.init) == Self.path else {
            return send(conn, status: 404, body: nil, then: then)
        }
        guard Self.authorized(req.headers["authorization"], token: Self.token()) else {
            return send(conn, status: 401, body: Self.json(["error": "missing or wrong bearer token"]),
                        extra: ["WWW-Authenticate": "Bearer"], then: then)
        }
        switch req.method {
        case "POST":
            break
        case "DELETE":
            return send(conn, status: 204, body: nil, then: then)     // no sessions are kept
        default:
            return send(conn, status: 405, body: nil, extra: ["Allow": "POST"], then: then)
        }
        guard let message = try? JSONSerialization.jsonObject(with: req.body) else {
            return send(conn, status: 400, body: Self.json(Self.error(nil, -32700, "parse error")), then: then)
        }
        Task {
            if let batch = message as? [[String: Any]] {
                var replies: [[String: Any]] = []
                for item in batch { if let r = await self.handle(item) { replies.append(r) } }
                if replies.isEmpty { self.send(conn, status: 202, body: nil, then: then) }
                else { self.send(conn, status: 200, body: Self.json(replies), then: then) }
            } else if let single = message as? [String: Any] {
                if let reply = await self.handle(single) { self.send(conn, status: 200, body: Self.json(reply), then: then) }
                else { self.send(conn, status: 202, body: nil, then: then) }
            } else {
                self.send(conn, status: 400, body: Self.json(Self.error(nil, -32600, "invalid request")), then: then)
            }
        }
    }

    // MARK: - JSON-RPC

    /// One message; nil for a notification (nothing is sent back).
    func handle(_ msg: [String: Any]) async -> [String: Any]? {
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]
        guard id != nil else { return nil }         // notifications/initialized and the like
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            let version = asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
            return Self.result(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "tether-studio", "title": "Tether Studio", "version": "1.0"],
                "instructions": McpTools.instructions,
            ])
        case "ping":
            return Self.result(id, [:])
        case "tools/list":
            return Self.result(id, ["tools": tools()])
        case "tools/call":
            guard let name = params["name"] as? String else { return Self.error(id, -32602, "tools/call needs a name") }
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard let handler else { return Self.error(id, -32603, "the app is not ready") }
            log?("MCP tool \(name)")
            let out = await handler(name, args)
            if out.unknownTool { return Self.error(id, -32602, "unknown tool \(name)") }
            return Self.result(id, out.json)
        default:
            return Self.error(id, -32601, "method not found: \(method)")
        }
    }

    static func result(_ id: Any?, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    static func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// Only pages served from this Mac itself; a page from elsewhere must not reach the camera.
    static func originAllowed(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    static func authorized(_ header: String?, token: String) -> Bool {
        guard let header, header.lowercased().hasPrefix("bearer ") else { return false }
        let given = Array(header.dropFirst(7).trimmingCharacters(in: .whitespaces).utf8)
        let wanted = Array(token.utf8)
        guard given.count == wanted.count else { return false }
        return zip(given, wanted).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0     // same time whatever matches
    }
}

/// What a tool gives back.
struct McpToolResult {
    var content: [[String: Any]]
    var isError = false
    var unknownTool = false

    static func text(_ text: String, error: Bool = false) -> McpToolResult {
        McpToolResult(content: [["type": "text", "text": text]], isError: error)
    }

    static func data(_ object: Any) -> McpToolResult {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return .text(String(data: data, encoding: .utf8) ?? "{}")
    }

    static func failure(_ text: String) -> McpToolResult { .text(text, error: true) }

    var json: [String: Any] { ["content": content, "isError": isError] }
}

/// A request as far as this server needs it.
struct HttpRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    /// Bytes after this request (a next one on the same connection).
    let rest: Data

    /// nil until the whole request (head and body) is in `data`.
    static func parse(_ data: Data) -> HttpRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ").map(String.init) ?? []
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return nil }
        let bodyEnd = data.index(bodyStart, offsetBy: length)
        return HttpRequest(method: first[0].uppercased(), path: first[1], headers: headers,
                           body: Data(data[bodyStart..<bodyEnd]), rest: Data(data[bodyEnd...]))
    }
}
