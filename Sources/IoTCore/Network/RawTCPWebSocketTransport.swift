import Foundation
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
    ]

    static func randomKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
    }

    /// Build the HTTP/1.1 upgrade request. `extraHeaders` carries auth (Basic, Cookie,
    /// CF-Access service tokens, forward-auth) — reserved names are filtered out.
    static func upgradeRequest(host: String, path: String, key: String,
                               extraHeaders: [String: String] = [:]) -> Data {
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
        return Data(lines.utf8)
    }

    /// Parse the raw response header block. Detects Caddy/nginx/Traefik auto-HTTPS 30x redirects
    /// so an `http://`-configured server doesn't perma-fail the live channel (Lumen 2026-05-22).
    static func parseUpgradeResponse(_ data: Data) -> WebSocketUpgradeResult {
        guard let text = String(data: data, encoding: .utf8) else {
            return .rejected(statusLine: "<binary>")
        }
        let statusLine = text.split(separator: "\r\n", maxSplits: 1,
                                    omittingEmptySubsequences: false).first.map(String.init) ?? text
        if statusLine.contains(" 101") { return .accepted }
        let isRedirect = [" 301", " 302", " 307", " 308"].contains { statusLine.contains($0) }
        if isRedirect, let location = httpsLocation(in: text) {
            return .redirectToHTTPS(location)
        }
        return .rejected(statusLine: String(statusLine.prefix(200)))
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
        var length = UInt64(b[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard b.count >= 4 else { return nil }
            length = UInt64(b[2]) << 8 | UInt64(b[3])
            offset = 4
        } else if length == 127 {
            guard b.count >= 10 else { return nil }
            length = 0
            for i in 0..<8 { length = length << 8 | UInt64(b[2 + i]) }
            offset = 10
        }
        guard length <= UInt64(WebSocketFrameCodec.maxPayloadBytes) else {
            throw IoTError.transport("WebSocket frame exceeds \(WebSocketFrameCodec.maxPayloadBytes)B cap")
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
        return WebSocketFrame(opcode: opcode, payload: payload)
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

    public func open() async throws {
        guard let host = url.host(), !host.isEmpty else {
            throw IoTError.transport("no host in \(url.absoluteString)")
        }
        let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) ?? .http
        let conn = NWConnection(host: .init(host), port: port, using: .tcp)
        connection = conn
        decoder = WebSocketFrameDecoder()

        try await Self.waitReady(conn, timeout: connectTimeout)

        let request = WebSocketHandshake.upgradeRequest(
            host: host, path: url.path, key: WebSocketHandshake.randomKey(),
            extraHeaders: extraHeaders)
        try await Self.sendRaw(conn, request)

        let response = try await readUntilHeaderEnd(conn)
        switch WebSocketHandshake.parseUpgradeResponse(response) {
        case .accepted:
            break
        case .redirectToHTTPS(let location):
            await close()
            throw IoTError.redirected(toHTTPS: location)
        case .rejected(let statusLine):
            await close()
            throw IoTError.transport("WebSocket upgrade rejected: \(statusLine)")
        }
    }

    public func send(_ data: Data) async throws {
        guard let connection else { throw IoTError.notConnected }
        let frame = WebSocketFrameCodec.encodeFrame(sendsText ? .text : .binary, payload: data)
        try await Self.sendRaw(connection, frame)
    }

    /// Keep-alive for the `RealtimeSocketClient` ping hook. Errors are swallowed — a dead socket
    /// is detected by the watchdog's staleness check, not by ping delivery.
    public func sendPing() async {
        guard let connection else { return }
        try? await Self.sendRaw(connection, WebSocketFrameCodec.encodeFrame(.ping))
    }

    public func receive() async throws -> Data {
        while true {
            guard let connection else { throw IoTError.notConnected }
            if let frame = try decoder.nextFrame() {
                switch frame.opcode {
                case .text, .binary, .continuation:
                    return frame.payload
                case .ping:
                    try? await Self.sendRaw(connection, WebSocketFrameCodec.encodeFrame(.pong, payload: frame.payload))
                    return Data()          // liveness signal upstream; decodes to nil
                case .pong:
                    return Data()          // liveness signal upstream; decodes to nil
                case .close:
                    await close()
                    throw IoTError.transport("server closed WebSocket")
                }
            }
            decoder.append(try await Self.receiveChunk(connection))
        }
    }

    public func close() async {
        guard let conn = connection else { return }
        connection = nil
        // Best-effort close frame, then tear down. Cancelling makes any in-flight receive throw —
        // exactly what the RealtimeSocketClient watchdog relies on.
        conn.send(content: WebSocketFrameCodec.encodeFrame(.close),
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - NWConnection plumbing

    /// Resume-once continuation guard. `nonisolated(unsafe)` state is lock-protected.
    private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func resume(_ cont: CheckedContinuation<T, any Error>, with result: Result<T, any Error>) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            guard first else { return }
            cont.resume(with: result)
        }
        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
    }

    /// Wait for `.ready` with a hard timeout. Ported fix (Lumen 2026-05-31): the timeout is
    /// DISARMED once the connection resolves — a live session must never be killed at T+timeout.
    /// `.waiting` fails fast instead of hanging on an unroutable LAN address.
    private static func waitReady(_ connection: NWConnection, timeout: Double) async throws {
        let once = ResumeOnce<Void>()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(cont, with: .success(()))
                case .failed(let error): once.resume(cont, with: .failure(error))
                case .cancelled: once.resume(cont, with: .failure(IoTError.cancelled))
                case .waiting(let error):
                    connection.cancel()
                    once.resume(cont, with: .failure(error))
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                guard !once.isDone else { return }
                connection.cancel()    // forces .cancelled → resumes via the state handler
                once.resume(cont, with: .failure(IoTError.timeout))
            }
        }
    }

    private static func sendRaw(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private static func receiveChunk(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let content, !content.isEmpty {
                    cont.resume(returning: content)
                } else if isComplete {
                    cont.resume(throwing: IoTError.transport("TCP stream ended"))
                } else {
                    cont.resume(throwing: IoTError.invalidResponse)
                }
            }
        }
    }

    /// Read raw bytes until the `\r\n\r\n` end of the HTTP upgrade response (8 KB cap). Any body
    /// bytes beyond the separator are fed to the frame decoder — servers may pipeline the first
    /// frame into the same TCP segment.
    private func readUntilHeaderEnd(_ connection: NWConnection) async throws -> Data {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        while true {
            buffer.append(try await Self.receiveChunk(connection))
            if let range = buffer.range(of: separator) {
                let remainder = buffer[range.upperBound...]
                if !remainder.isEmpty { decoder.append(Data(remainder)) }
                return Data(buffer[..<range.upperBound])
            }
            if buffer.count > 8192 { throw IoTError.invalidResponse }
        }
    }

}

#endif
