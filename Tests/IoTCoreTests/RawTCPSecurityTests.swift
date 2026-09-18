import Foundation
import Testing
@testable import IoTCore

@Suite struct RawTCPSecurityTests {
    @Test func requestCannotInjectHeadersOrTargets() {
        for headers in [["Authorization": "Bearer x\r\nX-Injected: yes"], ["Bad Name": "x"], ["cookie": "x", "Cookie": "y"]] {
            #expect(throws: IoTError.self) { try WebSocketHandshake.upgradeRequest(host: "localhost", path: "/ws", key: "k", extraHeaders: headers) }
        }
        #expect(throws: IoTError.self) { try WebSocketHandshake.upgradeRequest(host: "localhost", path: "/ws HTTP/1.1\r\n", key: "k") }
    }
    @Test func fragmentsAreBoundedAndUTF8ValidatedAsAWhole() throws {
        var assembler = WebSocketMessageAssembler(maxPayloadBytes: 4)
        #expect(try assembler.consume(.init(opcode: .text, payload: Data([0xC3]), isFinal: false)) == nil)
        #expect(try assembler.consume(.init(opcode: .continuation, payload: Data([0xA9]))) == Data("é".utf8))
        #expect(throws: IoTError.self) { try assembler.consume(.init(opcode: .continuation, payload: Data())) }
        #expect(try assembler.consume(.init(opcode: .binary, payload: Data([1, 2, 3]), isFinal: false)) == nil)
        #expect(throws: IoTError.self) { try assembler.consume(.init(opcode: .continuation, payload: Data([4, 5]))) }
    }
    @Test func status101WithoutAcceptProofIsNotAWebSocketHandshake() {
        let header = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".utf8)
        #expect(WebSocketHandshake.parseUpgradeResponse(header) != .accepted)
    }
    @Test func malformedStatusCannotMatchASubstring() {
        #expect(WebSocketHandshake.parseUpgradeResponse(Data("HTTP/1.1 1011 Invalid\r\n\r\n".utf8)) != .accepted)
    }
    @Test func serverFramesCannotBeMasked() {
        var decoder = WebSocketFrameDecoder()
        decoder.append(Data([0x81, 0x81, 0, 0, 0, 0, 65]))
        #expect(throws: (any Error).self) { try decoder.nextFrame() }
    }
    @Test func unnegotiatedExtensionsAndFragmentedControlFramesAreRejected() {
        for header in [[UInt8(0xC1), 0], [UInt8(0x09), 0]] {
            var decoder = WebSocketFrameDecoder(); decoder.append(Data(header))
            #expect(throws: (any Error).self) { try decoder.nextFrame() }
        }
    }
}
