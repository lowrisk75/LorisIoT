import Testing
import Foundation
@testable import IoTCore
#if canImport(Network)
import Network
#endif

// MARK: - Handshake

@Suite struct WebSocketHandshakeTests {

    @Test func upgradeRequestCarriesRequiredHeadersAndExtras() {
        let data = WebSocketHandshake.upgradeRequest(
            host: "cam.local", path: "/ws", key: "KEY==",
            extraHeaders: ["Authorization": "Basic abc", "Cookie": "frigate=1",
                           "Upgrade": "spoofed", "Sec-WebSocket-Version": "7"])
        let text = String(data: data, encoding: .utf8)!
        #expect(text.hasPrefix("GET /ws HTTP/1.1\r\n"))
        #expect(text.contains("Host: cam.local\r\n"))
        #expect(text.contains("Upgrade: websocket\r\n"))
        #expect(text.contains("Sec-WebSocket-Key: KEY==\r\n"))
        #expect(text.contains("Sec-WebSocket-Version: 13\r\n"))
        #expect(text.contains("Authorization: Basic abc\r\n"))
        #expect(text.contains("Cookie: frigate=1\r\n"))
        // Reserved headers can't be overridden by extras.
        #expect(!text.contains("spoofed"))
        #expect(!text.contains("Sec-WebSocket-Version: 7"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test func emptyPathBecomesRoot() {
        let text = String(data: WebSocketHandshake.upgradeRequest(host: "h", path: "", key: "k"),
                          encoding: .utf8)!
        #expect(text.hasPrefix("GET / HTTP/1.1\r\n"))
    }

    @Test func accepts101() {
        let response = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n".utf8)
        #expect(WebSocketHandshake.parseUpgradeResponse(response) == .accepted)
    }

    @Test func redirect308WithHTTPSLocationIsSurfaced() {
        let response = Data("HTTP/1.1 308 Permanent Redirect\r\nLocation: https://cam.example:8443/ws\r\n\r\n".utf8)
        #expect(WebSocketHandshake.parseUpgradeResponse(response)
                == .redirectToHTTPS("https://cam.example:8443/ws"))
    }

    @Test func redirectToHTTPTargetIsRejectedNotFollowed() {
        let response = Data("HTTP/1.1 301 Moved\r\nLocation: http://other.example/ws\r\n\r\n".utf8)
        guard case .rejected = WebSocketHandshake.parseUpgradeResponse(response) else {
            Issue.record("cross-scheme http redirect must not be surfaced as redirectToHTTPS")
            return
        }
    }

    @Test func plainRejectionKeepsStatusLine() {
        let response = Data("HTTP/1.1 401 Unauthorized\r\n\r\n".utf8)
        #expect(WebSocketHandshake.parseUpgradeResponse(response)
                == .rejected(statusLine: "HTTP/1.1 401 Unauthorized"))
    }

    @Test func locationHeaderNameIsCaseInsensitive() {
        // nginx emits mixed-case header names in the wild (Lumen user reports).
        #expect(WebSocketHandshake.httpsLocation(in: "HTTP/1.1 308 x\r\nlocation: https://a.b/\r\n")
                == "https://a.b/")
    }
}

// MARK: - Framing

@Suite struct WebSocketFrameCodecTests {

    private func decodeAll(_ data: Data, chunkSize: Int = .max) throws -> [WebSocketFrame] {
        var decoder = WebSocketFrameDecoder()
        var frames: [WebSocketFrame] = []
        var remaining = data
        while !remaining.isEmpty {
            let chunk = remaining.prefix(chunkSize)
            remaining.removeFirst(chunk.count)
            decoder.append(Data(chunk))
            while let frame = try decoder.nextFrame() { frames.append(frame) }
        }
        return frames
    }

    @Test func maskedTextFrameRoundTrips() throws {
        let payload = Data(#"{"topic":"events"}"#.utf8)
        let wire = WebSocketFrameCodec.encodeFrame(.text, payload: payload, mask: [1, 2, 3, 4])
        let frames = try decodeAll(wire)
        #expect(frames == [WebSocketFrame(opcode: .text, payload: payload)])
    }

    @Test func unmaskedServerFrameDecodes() throws {
        // Servers send unmasked frames: FIN|text, len=5, "hello".
        var wire = Data([0x81, 0x05])
        wire.append(Data("hello".utf8))
        let frames = try decodeAll(wire)
        #expect(frames == [WebSocketFrame(opcode: .text, payload: Data("hello".utf8))])
    }

    @Test func extended16BitLengthRoundTrips() throws {
        let payload = Data(repeating: 0xAB, count: 300)
        let wire = WebSocketFrameCodec.encodeFrame(.binary, payload: payload, mask: [9, 9, 9, 9])
        let frames = try decodeAll(wire)
        #expect(frames.first?.payload == payload)
    }

    @Test func extended64BitLengthRoundTrips() throws {
        let payload = Data(repeating: 0xCD, count: 70_000)
        let wire = WebSocketFrameCodec.encodeFrame(.binary, payload: payload, mask: [0, 0, 0, 0])
        let frames = try decodeAll(wire)
        #expect(frames.first?.payload == payload)
    }

    @Test func byteByByteFeedingReassemblesFrames() throws {
        // Chunk boundaries never align with frame boundaries on real TCP.
        let a = WebSocketFrameCodec.encodeFrame(.text, payload: Data("one".utf8), mask: [5, 6, 7, 8])
        let b = WebSocketFrameCodec.encodeFrame(.text, payload: Data("two".utf8), mask: [5, 6, 7, 8])
        let frames = try decodeAll(a + b, chunkSize: 1)
        #expect(frames.map { String(data: $0.payload, encoding: .utf8) } == ["one", "two"])
    }

    @Test func controlFramesDecode() throws {
        let ping = WebSocketFrameCodec.encodeFrame(.ping, payload: Data("p".utf8), mask: [1, 1, 1, 1])
        let close = WebSocketFrameCodec.encodeFrame(.close, mask: [2, 2, 2, 2])
        let frames = try decodeAll(ping + close)
        #expect(frames.map(\.opcode) == [.ping, .close])
        #expect(frames[0].payload == Data("p".utf8))
    }

    @Test func oversizedFrameThrowsInsteadOfBuffering() {
        // Header declares 32 MB (> 16 MB cap) — must throw immediately, not accumulate.
        var wire = Data([0x82, 127])
        let declared = UInt64(32_000_000)
        for shift in stride(from: 56, through: 0, by: -8) { wire.append(UInt8((declared >> UInt64(shift)) & 0xFF)) }
        var decoder = WebSocketFrameDecoder()
        decoder.append(wire)
        #expect(throws: IoTError.self) { _ = try decoder.nextFrame() }
    }

    @Test func unknownOpcodeThrows() {
        var decoder = WebSocketFrameDecoder()
        decoder.append(Data([0x83, 0x00]))   // opcode 0x3 is reserved
        #expect(throws: IoTError.self) { _ = try decoder.nextFrame() }
    }

    @Test func incompleteFrameReturnsNilNotGarbage() throws {
        var decoder = WebSocketFrameDecoder()
        decoder.append(Data([0x81]))         // half a header
        #expect(try decoder.nextFrame() == nil)
    }
}

// MARK: - Loopback integration (localhost NWListener — no external device)

#if canImport(Network)

/// Minimal WebSocket server on 127.0.0.1: accepts the upgrade (or replies with a canned response)
/// then pushes `frames` to the client. Exists to prove the NWConnection plumbing end-to-end.
private final class LoopbackWSServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16

    init(response: String? = nil, frames: [Data] = []) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                let head = response ?? "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
                var out = Data(head.utf8)
                for payload in frames {
                    var frame = Data([0x81, UInt8(payload.count)])   // unmasked server text frame
                    frame.append(payload)
                    out.append(frame)
                }
                conn.send(content: out, completion: .contentProcessed { _ in })
            }
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        ready.wait()
        port = listener.port?.rawValue ?? 0
    }

    deinit { listener.cancel() }
}

@Suite struct RawTCPWebSocketTransportLoopbackTests {

    @Test func handshakesAndReceivesFramesOverRealTCP() async throws {
        let payloads = [Data(#"{"n":1}"#.utf8), Data(#"{"n":2}"#.utf8)]
        let server = try LoopbackWSServer(frames: payloads)
        let transport = RawTCPWebSocketTransport(
            url: URL(string: "http://127.0.0.1:\(server.port)/ws")!, connectTimeout: 5)
        try await transport.open()
        let first = try await transport.receive()
        let second = try await transport.receive()
        #expect([first, second] == payloads)
        await transport.close()
    }

    @Test func httpsRedirectSurfacesTypedError() async throws {
        let server = try LoopbackWSServer(
            response: "HTTP/1.1 308 Permanent Redirect\r\nLocation: https://secure.local/ws\r\n\r\n")
        let transport = RawTCPWebSocketTransport(
            url: URL(string: "http://127.0.0.1:\(server.port)/ws")!, connectTimeout: 5)
        await #expect(throws: IoTError.redirected(toHTTPS: "https://secure.local/ws")) {
            try await transport.open()
        }
    }

    @Test func rejectedUpgradeThrowsTransportError() async throws {
        let server = try LoopbackWSServer(response: "HTTP/1.1 401 Unauthorized\r\n\r\n")
        let transport = RawTCPWebSocketTransport(
            url: URL(string: "http://127.0.0.1:\(server.port)/ws")!, connectTimeout: 5)
        do {
            try await transport.open()
            Issue.record("401 upgrade must throw")
        } catch let error as IoTError {
            guard case .transport = error else {
                Issue.record("expected .transport, got \(error)")
                return
            }
        }
    }

    @Test func worksAsRealtimeSocketClientTransport() async throws {
        // The whole point: plug into RealtimeSocketClient and stream decoded messages.
        let server = try LoopbackWSServer(frames: [Data("alpha".utf8), Data("beta".utf8)])
        let url = URL(string: "http://127.0.0.1:\(server.port)/ws")!
        let client = RealtimeSocketClient<String>(
            makeTransport: { RawTCPWebSocketTransport(url: url, connectTimeout: 5) },
            decode: { data in data.isEmpty ? nil : String(data: data, encoding: .utf8) }
        )
        var received: [String] = []
        for await message in await client.messages() {
            received.append(message)
            if received.count == 2 { await client.stop() }
        }
        #expect(received == ["alpha", "beta"])
    }
}

#endif
