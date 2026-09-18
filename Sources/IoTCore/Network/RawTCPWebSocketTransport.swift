import Foundation
import CryptoKit
#if canImport(Network)
import Network
#endif

// Ported from Lumen `FrigateMQTTClient.connectRawTCP` (the raw-TCP path). iOS ATS refuses
// `ws://` upgrades via URLSession even with NSAllowsLocalNetworking in some proxy setups, so
// cleartext LAN WebSockets are spoken by hand over NWConnection: HTTP/1.1 upgrade + RFC 6455
// framing. Provider-specific concerns stay OUT of Core: path fallback lists (`/ws` vs `/api/ws`),
// session-cookie login flows, and the pivot-to-WSS after a redirect are the caller's job — the
// redirect is surfaced as `IoTError.redirected(toHTTPS:)`.

// MARK: - Handshake (pure, fixture-testable)

enum WebSocketUpgradeResult: Equatable, Sendable {
    case accepted
    /// 301/302/307/308 with an absolute `https://` Location — caller should pin HTTPS and use WSS.
    case redirectToHTTPS(String)
    case rejected(statusLine: String)
}

enum WebSocketHandshake {
    /// Headers the transport owns; caller-supplied extras with these names are dropped.
    static let reservedHeaders: Set<String> = [
        "host", "upgrade", "connection", "sec-websocket-key", "sec-websocket-version",
        "content-length", "transfer-encoding", "sec-websocket-extensions",
    ]

    static func randomKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
    }

    /// Build the HTTP/1.1 upgrade request. `extraHeaders` carries auth (Basic, Cookie,
    /// CF-Access service tokens, forward-auth) — reserved names are filtered out.
    private static let tokens = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~")
    /// RFC 9110 token: the only safe shape for a header name.
    static func isToken(_ name: String) -> Bool { !name.isEmpty && name.unicodeScalars.allSatisfy { tokens.contains($0) } }

    static func upgradeRequest(host: String, path: String, key: String,
                               extraHeaders: [String: String] = [:]) throws -> Data {
        guard !host.isEmpty, !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              path.isEmpty || path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              !key.contains("\r"), !key.contains("\n"), extraHeaders.count <= 64,
              Set(extraHeaders.keys.map { $0.lowercased() }).count == extraHeaders.count,
              extraHeaders.allSatisfy({ name, value in
                  isToken(name)
                  && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
              }) else { throw IoTError.notConfigured }
        var lines = "GET \(path.isEmpty ? "/" : path) HTTP/1.1\r\n"
        lines += "Host: \(host)\r\n"
        lines += "Upgrade: websocket\r\n"
        lines += "Connection: Upgrade\r\n"
        lines += "Sec-WebSocket-Key: \(key)\r\n"
        lines += "Sec-WebSocket-Version: 13\r\n"
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key })
        where !reservedHeaders.contains(name.lowercased()) {
            lines += "\(name): \(value)\r\n"
        }
        lines += "\r\n"
        guard lines.utf8.count <= 8192 else { throw IoTError.notConfigured }
        return Data(lines.utf8)
    }

    /// Parse the raw response header block. Detects Caddy/nginx/Traefik auto-HTTPS 30x redirects
    /// so an `http://`-configured server doesn't perma-fail the live channel (Lumen 2026-05-22).
    static func parseUpgradeResponse(_ data: Data, expectedKey: String? = nil,
                                     requestedProtocols: [String] = []) -> WebSocketUpgradeResult {
        guard data.count <= 8192, let text = String(data: data, encoding: .utf8),
              text.hasSuffix("\r\n\r\n") else { return .rejected(statusLine: "<invalid header>") }
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return .rejected(statusLine: "<missing status>") }
        let status = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard status.count >= 2, status[0] == "HTTP/1.1", status[1].count == 3,
              let code = Int(status[1]) else { return .rejected(statusLine: "<invalid status>") }
        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), line.first != " ", line.first != "\t" else {
                return .rejected(statusLine: "<invalid header>")
            }
            let name = String(line[..<colon]).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name, default: []].append(value)
        }
        if code == 101 {
            guard let expectedKey,
                  headers["upgrade"]?.map({ $0.lowercased() }) == ["websocket"],
                  headers["connection"]?.joined(separator: ",").split(separator: ",")
                    .contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "upgrade" }) == true,
                  headers["sec-websocket-accept"] == [acceptValue(for: expectedKey)],
                  headers["sec-websocket-extensions"] == nil else { return .rejected(statusLine: "<invalid upgrade proof>") }
            if let protocols = headers["sec-websocket-protocol"] {
                guard protocols.count == 1, requestedProtocols.contains(protocols[0]) else {
                    return .rejected(statusLine: "<unexpected subprotocol>")
                }
            } else if !requestedProtocols.isEmpty { return .rejected(statusLine: "<missing subprotocol>") }
            return .accepted
        }
        if [301, 302, 307, 308].contains(code), headers["location"]?.count == 1,
           let location = httpsLocation(in: text) { return .redirectToHTTPS(location) }
        return .rejected(statusLine: String(statusLine.prefix(200)))
    }

    static func acceptValue(for key: String) -> String {
        // SHA-1 here is the mandated RFC 6455 nonce response, never credential hashing.
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    /// Case-insensitive `Location:` lookup; only absolute `https://` targets count.
    static func httpsLocation(in response: String) -> String? {
        for line in response.split(separator: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            guard line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "location" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard value.lowercased().hasPrefix("https://") else { return nil }
            return value
        }
        return nil
    }
}

// MARK: - Framing (pure, fixture-testable)

struct WebSocketFrame: Equatable, Sendable {
    enum Opcode: UInt8, Sendable {
        case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA
    }
    var opcode: Opcode
    var payload: Data
    var isFinal = true
}

enum WebSocketFrameCodec {
    /// 16 MB payload cap — anything bigger on an IoT event socket is corruption or abuse.
    static let maxPayloadBytes = 16_777_216

    /// Encode a client frame (FIN set, masked per RFC 6455 §5.3). `mask` is injectable for tests.
    static func encodeFrame(_ opcode: WebSocketFrame.Opcode, payload: Data = Data(),
                            mask: [UInt8]? = nil) -> Data {
        let key = mask ?? (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        var out = Data([0x80 | opcode.rawValue])
        let n = payload.count
        if n < 126 {
            out.append(0x80 | UInt8(n))
        } else if n <= 0xFFFF {
            out.append(0x80 | 126)
            out.append(UInt8(n >> 8)); out.append(UInt8(n & 0xFF))
        } else {
            out.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((UInt64(n) >> UInt64(shift)) & 0xFF))
            }
        }
        out.append(contentsOf: key)
        var masked = payload
        for i in masked.indices { masked[i] ^= key[(i - masked.startIndex) % 4] }
        out.append(masked)
        return out
    }
}

/// Incremental server→client frame parser. Feed raw TCP chunks with `append`, drain complete
/// frames with `nextFrame()` — chunk boundaries never have to align with frame boundaries.
struct WebSocketFrameDecoder: Sendable {
    private var buffer = Data()
    private let acceptsMaskedFrames: Bool
    init(acceptsMaskedFrames: Bool = false) { self.acceptsMaskedFrames = acceptsMaskedFrames }

    mutating func append(_ data: Data) { buffer.append(data) }

    /// Returns the next complete frame, or nil if more bytes are needed.
    /// Throws on an unknown opcode or a payload above the cap.
    mutating func nextFrame() throws -> WebSocketFrame? {
        guard buffer.count >= 2 else { return nil }
        let b = [UInt8](buffer.prefix(14))     // max header: 2 + 8 (len64) + 4 (mask)
        guard let opcode = WebSocketFrame.Opcode(rawValue: b[0] & 0x0F) else {
            throw IoTError.transport("unsupported WebSocket opcode 0x\(String(b[0] & 0x0F, radix: 16))")
        }
        let isMasked = (b[1] & 0x80) != 0
        let isFinal = (b[0] & 0x80) != 0
        guard b[0] & 0x70 == 0, !isMasked || acceptsMaskedFrames else { throw IoTError.invalidResponse }
        var length = UInt64(b[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard b.count >= 4 else { return nil }
            length = UInt64(b[2]) << 8 | UInt64(b[3])
            offset = 4
            guard length >= 126 else { throw IoTError.invalidResponse }
        } else if length == 127 {
            guard b.count >= 10 else { return nil }
            length = 0
            for i in 0..<8 { length = length << 8 | UInt64(b[2 + i]) }
            offset = 10
            guard length > 65535, b[2] & 0x80 == 0 else { throw IoTError.invalidResponse }
        }
        guard length <= UInt64(WebSocketFrameCodec.maxPayloadBytes) else {
            throw IoTError.transport("WebSocket frame exceeds \(WebSocketFrameCodec.maxPayloadBytes)B cap")
        }
        if opcode.rawValue & 0x08 != 0 {
            guard isFinal, length <= 125 else { throw IoTError.invalidResponse }
        }
        var maskKey: [UInt8]?
        if isMasked {
            guard b.count >= offset + 4 else { return nil }
            maskKey = Array(b[offset..<offset + 4])
            offset += 4
        }
        let total = offset + Int(length)
        guard buffer.count >= total else { return nil }
        var payload = Data(buffer[buffer.startIndex + offset ..< buffer.startIndex + total])
        buffer.removeFirst(total)
        if let maskKey {
            for i in payload.indices { payload[i] ^= maskKey[(i - payload.startIndex) % 4] }
        }
        return WebSocketFrame(opcode: opcode, payload: payload, isFinal: isFinal)
    }
}

#if canImport(Network)

// MARK: - The transport

/// `RealtimeTransport` speaking cleartext WebSocket over a raw `NWConnection` — the ATS bypass for
/// `ws://` LAN servers (Frigate, HA behind plain nginx…). Pair with `RealtimeSocketClient`, whose
/// watchdog calls `close()` to unstick a silently-dead socket, and use `sendPing()` as its
/// keep-alive hook. Control frames are handled inside `receive()`: inbound pings are answered,
/// and ping/pong return `Data()` (decodes to nil upstream) so ANY inbound frame — including a bare
/// pong on a quiet camera — refreshes the watchdog's activity clock instead of looking like death.
public actor RawTCPWebSocketTransport: RealtimeTransport {

    private let url: URL
    private let extraHeaders: [String: String]
    private let connectTimeout: Double
    private let sendsText: Bool
    private var connection: NWConnection?
    private var decoder = WebSocketFrameDecoder()
    private var assembler = WebSocketMessageAssembler()
    private var generation: UInt64 = 0
    private var isOpen = false
    private var receivingGeneration: UInt64?
    private var timedOutGeneration: UInt64?

    /// - Parameters:
    ///   - url: `http://` or `ws://` URL including the socket path (e.g. `http://host:5000/ws`).
    ///   - extraHeaders: auth headers for the upgrade (Basic, Cookie, CF-Access…). Reserved
    ///     handshake headers are filtered.
    ///   - connectTimeout: seconds before an unresolved TCP connect is abandoned.
    ///   - sendsText: JSON IoT protocols speak text frames (default); false → binary frames.
    public init(url: URL, extraHeaders: [String: String] = [:],
                connectTimeout: Double = 10, sendsText: Bool = true) {
        self.url = url
        self.extraHeaders = extraHeaders
        self.connectTimeout = connectTimeout
        self.sendsText = sendsText
    }

    /// The address the policy checked. URLComponents keeps IPv6 brackets, which `NWEndpoint.Host` would
    /// otherwise treat as a hostname to resolve.
    static func endpointHost(_ host: String) -> NWEndpoint.Host {
        guard host.hasPrefix("["), host.hasSuffix("]") else { return .init(host) }
        return .init(String(host.dropFirst().dropLast()))
    }

    public func open() async throws {
        guard connection == nil else { throw IoTError.notConfigured }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "ws"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil, components.fragment == nil,
              let host = components.host, !host.isEmpty,
              let rawPort = UInt16(exactly: components.port ?? 80), rawPort > 0,
              let port = NWEndpoint.Port(rawValue: rawPort),
              connectTimeout.isFinite, connectTimeout > 0, connectTimeout <= 60 else {
            throw IoTError.notConfigured
        }
        // No TLS here: credential headers may only travel to a private host.
        // A query string can carry a token as well as a header can.
        let mayCarryCredentials = HTTPOrigin.carriesCredentials(extraHeaders) || !(components.percentEncodedQuery ?? "").isEmpty
        guard !mayCarryCredentials || HTTPOrigin.isPrivateHost(host) else {
            throw IoTError.notSupported("Credentials over a cleartext WebSocket are only allowed on a private network")
        }
        let key = WebSocketHandshake.randomKey()
        let path = (components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath)
            + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        let authority = host + (components.port.map { ":\($0)" } ?? "")
        let request = try WebSocketHandshake.upgradeRequest(host: authority, path: path, key: key,
                                                             extraHeaders: extraHeaders)
        let protocols = extraHeaders.first(where: { $0.key.lowercased() == "sec-websocket-protocol" })?
            .value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        try Task.checkCancellation()
        let conn = NWConnection(host: Self.endpointHost(host), port: port, using: .tcp)
        generation &+= 1
        let token = generation
        connection = conn
        decoder = WebSocketFrameDecoder()
        assembler = WebSocketMessageAssembler()
        let deadline = Task { [weak self, connectTimeout] in
            do { try await Task.sleep(for: .seconds(connectTimeout)) } catch { return }
            await self?.expireOpening(token)
        }
        defer { deadline.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await NWConnectionAsync.waitReady(conn, timeout: connectTimeout)
                try validate(token)
                try await NWConnectionAsync.send(conn, request)
                let response = try await readUntilHeaderEnd(conn, generation: token)
                try validate(token)
                switch WebSocketHandshake.parseUpgradeResponse(response, expectedKey: key, requestedProtocols: protocols) {
                case .accepted: isOpen = true
                case .redirectToHTTPS(let location):
                    guard let target = URLComponents(string: location), target.scheme?.lowercased() == "https",
                          target.host?.lowercased() == components.host?.lowercased(),
                          target.user == nil, target.password == nil, target.fragment == nil,
                          (1...65535).contains(target.port ?? 443) else { throw IoTError.notConfigured }
                    throw IoTError.redirected(toHTTPS: location)
                case .rejected(let statusLine):
                    throw IoTError.transport("WebSocket upgrade rejected: \(statusLine)")
                }
            } onCancel: { conn.cancel() }
        } catch {
            if generation == token { await close() }
            if Task.isCancelled { throw CancellationError() }
            if timedOutGeneration == token { throw IoTError.timeout }
            throw error
        }
    }

    private func validate(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard generation == token, connection != nil else { throw IoTError.notConnected }
    }

    private func expireOpening(_ token: UInt64) async {
        guard generation == token, !isOpen else { return }
        timedOutGeneration = token
        await close()
    }

    public func send(_ data: Data) async throws {
        guard let connection, isOpen else { throw IoTError.notConnected }
        guard data.count <= WebSocketMessageAssembler().maxPayloadBytes,
              !sendsText || String(data: data, encoding: .utf8) != nil else { throw IoTError.invalidResponse }
        let token = generation
        let frame = WebSocketFrameCodec.encodeFrame(sendsText ? .text : .binary, payload: data)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await NWConnectionAsync.send(connection, frame)
            try validate(token)
        } onCancel: { connection.cancel() }
    }

    /// Keep-alive for the `RealtimeSocketClient` ping hook. Errors are swallowed — a dead socket
    /// is detected by the watchdog's staleness check, not by ping delivery.
    public func ping() async {
        guard let connection, isOpen else { return }
        try? await NWConnectionAsync.send(connection, WebSocketFrameCodec.encodeFrame(.ping))
    }

    public func receive() async throws -> Data {
        guard let connection, isOpen, receivingGeneration == nil else { throw IoTError.notConnected }
        let token = generation
        receivingGeneration = token
        defer { if receivingGeneration == token { receivingGeneration = nil } }
        do {
            return try await withTaskCancellationHandler {
                while true {
                    try validate(token)
                    if let frame = try decoder.nextFrame() {
                        switch frame.opcode {
                        case .text, .binary, .continuation:
                            if let message = try assembler.consume(frame) { return message }
                            continue
                        case .ping:
                            try await NWConnectionAsync.send(connection, WebSocketFrameCodec.encodeFrame(.pong, payload: frame.payload))
                            try validate(token)
                            return Data()
                        case .pong: return Data()
                        case .close: throw IoTError.transport("server closed WebSocket")
                        }
                    }
                    let chunk = try await NWConnectionAsync.receiveChunk(connection)
                    try validate(token)
                    decoder.append(chunk)
                }
            } onCancel: { connection.cancel() }
        } catch {
            if generation == token { await close() }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    deinit { connection?.cancel() }

    public func close() async {
        generation &+= 1
        isOpen = false
        receivingGeneration = nil
        let conn = connection
        connection = nil
        decoder = WebSocketFrameDecoder()
        assembler = WebSocketMessageAssembler()
        // Teardown must not depend on a send callback from an already dead connection.
        conn?.cancel()
    }

    /// The deadline in open() covers the entire HTTP upgrade, not only TCP establishment.
    private func readUntilHeaderEnd(_ connection: NWConnection, generation token: UInt64) async throws -> Data {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        while true {
            let chunk = try await NWConnectionAsync.receiveChunk(connection)
            try validate(token)
            buffer.append(chunk)
            if let range = buffer.range(of: separator) {
                guard buffer.distance(from: buffer.startIndex, to: range.upperBound) <= 8192 else { throw IoTError.invalidResponse }
                let remainder = buffer[range.upperBound...]
                if !remainder.isEmpty { decoder.append(Data(remainder)) }
                return Data(buffer[..<range.upperBound])
            }
            if buffer.count > 8192 { throw IoTError.invalidResponse }
        }
    }

}

#endif
