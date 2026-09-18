import Foundation
import Testing
@testable import IoTGovee

#if canImport(Darwin)
import Darwin
struct GoveeLANTransportTests {
    @Test(arguments: ["example.com", "0.0.0.0", "255.255.255.255", "239.255.255.250", "127.0.0.1:4003"])
    func rejectsNonUnicastEndpoints(host: String) async {
        await #expect(throws: GoveeLANTransport.Failure.invalidEndpoint) {
            try await GoveeLANTransport().query(.status, host: host)
        }
    }

    @Test func cancelledTaskDoesNotStartAnExchange() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await GoveeLANTransport().query(.status, host: "127.0.0.1")
        }
        await #expect(throws: (any Error).self) { try await task.value }
    }

    @Test func noReplyHasBoundedTimeout() async {
        let transport = GoveeLANTransport(receivePort: 0, discoveryPort: 9, statusPort: 9)
        let start = ContinuousClock.now
        await #expect(throws: GoveeLANTransport.Failure.timeout) {
            try await transport.query(.status, host: "127.0.0.1", timeout: 0.1)
        }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func realUDPDiscardsNoiseBeforeReturningPartialState() async throws {
        let port = try responder([
            Data([0xff]),
            Data(#"{"msg":{"cmd":"turn","data":{"value":1}}}"#.utf8),
            Data(#"{"msg":{"cmd":"devStatus","data":{"brightness":37}}}"#.utf8)
        ])
        let transport = GoveeLANTransport(receivePort: 0, discoveryPort: port, statusPort: port)
        let message = try await transport.query(.status, host: "127.0.0.1", timeout: 1)
        guard case .status(let state) = message else { Issue.record("Missing status"); return }
        #expect(state.brightness == 37)
        #expect(state.onOff == nil)
    }

    @Test func discoveryDoesNotRedirectToAnAdvertisedDifferentHost() async throws {
        let port = try responder([
            Data(#"{"msg":{"cmd":"scan","data":{"device":"AA:BB:CC:DD:EE:FF:00:11","sku":"H6022","ip":"192.168.3.9"}}}"#.utf8)
        ])
        let transport = GoveeLANTransport(receivePort: 0, discoveryPort: port, statusPort: port)
        await #expect(throws: GoveeLANTransport.Failure.timeout) {
            try await transport.query(.discovery, host: "127.0.0.1", timeout: 0.15)
        }
    }

    @Test func cancellationInterruptsAnOutstandingReceive() async throws {
        let transport = GoveeLANTransport(receivePort: 0, discoveryPort: 9, statusPort: 9)
        let task = Task { try await transport.query(.status, host: "127.0.0.1", timeout: 5) }
        try await Task.sleep(for: .milliseconds(75))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: GoveeLANTransport.Failure.cancelled) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func nativeSendDeliversOnlyTheEncodedCommand() async throws {
        let capture = PacketCapture()
        let port = try responder([], onRequest: { capture.save($0) })
        let transport = GoveeLANTransport(receivePort: 0, discoveryPort: port, statusPort: port)
        try await transport.send(.brightness(42), host: "127.0.0.1")
        let deadline = ContinuousClock.now + .seconds(1)
        while capture.value == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(capture.value == (try GoveeLANCommand.brightness(42).encoded()))
    }

    private func responder(_ messages: [Data], onRequest: @escaping @Sendable (Data) -> Void = { _ in }) throws -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw GoveeLANTransport.Failure.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { Darwin.close(fd); throw GoveeLANTransport.Failure.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { Darwin.close(fd); throw GoveeLANTransport.Failure.socket }
        let port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global().async {
            defer { Darwin.close(fd) }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, 2000) > 0 else { return }
            var peer = sockaddr_in()
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            var buffer = [UInt8](repeating: 0, count: 1024)
            let received = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &size)
                }
            }
            guard received > 0 else { return }
            onRequest(Data(buffer.prefix(received)))
            for message in messages {
                _ = message.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &peer) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, bytes.baseAddress, bytes.count, 0, $0, size)
                        }
                    }
                }
            }
        }
        return port
    }
}

private final class PacketCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var packet: Data?
    var value: Data? { lock.lock(); defer { lock.unlock() }; return packet }
    func save(_ data: Data) { lock.lock(); packet = data; lock.unlock() }
}
#endif
