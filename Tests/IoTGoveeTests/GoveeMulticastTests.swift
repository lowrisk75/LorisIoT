import Foundation
import Testing
import IoTCore
@testable import IoTGovee
#if canImport(Darwin)
import Darwin

@Suite(.serialized)
struct GoveeMulticastTests {
    @Test func loopbackMulticastDiscoversASimulatedLight() async throws {
        let fixture = try MulticastFixture()
        defer { fixture.close() }
        fixture.respond()
        let devices = try await GoveeDiscovery.scan(interfaceAddress: "127.0.0.1", duration: 1)
        #expect(fixture.request == GoveeLANMessage.discoveryQuery)
        #expect(devices.count == 1)
        #expect(devices.first?.host == "127.0.0.1")
        #expect(devices.first?.model == "H6022")
    }

    @Test func cancellingLiveScanReleasesTheReplyPort() async throws {
        let task = Task { try await GoveeDiscovery.scan(interfaceAddress: "127.0.0.1", duration: 5) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: IoTError.cancelled) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(1))
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { Issue.record("Socket unavailable"); return }
        defer { Darwin.close(descriptor) }
        #expect(bindPort(descriptor, port: 4002) == 0)
    }
}

private func bindPort(_ descriptor: Int32, port: UInt16) -> Int32 {
    var local = sockaddr_in()
    local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    local.sin_family = sa_family_t(AF_INET)
    local.sin_port = port.bigEndian
    return withUnsafePointer(to: &local) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
}

private final class MulticastFixture: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var captured: Data?
    private let completed = DispatchGroup()
    private var started = false
    var request: Data? { lock.lock(); defer { lock.unlock() }; return captured }

    init() throws {
        descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw IoTError.transport("Fixture socket unavailable") }
        guard bindPort(descriptor, port: 4001) == 0 else {
            Darwin.close(descriptor); throw IoTError.transport("Fixture port unavailable")
        }
        var membership = ip_mreq(imr_multiaddr: in_addr(s_addr: inet_addr("239.255.255.250")),
                                 imr_interface: in_addr(s_addr: inet_addr("127.0.0.1")))
        guard setsockopt(descriptor, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership,
                         socklen_t(MemoryLayout<ip_mreq>.size)) == 0 else {
            Darwin.close(descriptor); throw IoTError.transport("Loopback multicast unavailable")
        }
    }

    func respond() {
        started = true
        completed.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { completed.leave() }
            var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&ready, 1, 3000) > 0 else { return }
            var bytes = [UInt8](repeating: 0, count: 8193)
            var source = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &source) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(descriptor, &bytes, bytes.count, 0, $0, &length)
                }
            }
            guard count > 0, source.sin_addr.s_addr == inet_addr("127.0.0.1") else { return }
            let packet = Data(bytes.prefix(count))
            lock.lock(); captured = packet; lock.unlock()
            guard packet == GoveeLANMessage.discoveryQuery else { return }
            let response = Data(#"{"msg":{"cmd":"scan","data":{"device":"AA:BB:CC:DD:EE:FF:00:11","sku":"H6022","ip":"127.0.0.1"}}}"#.utf8)
            _ = response.withUnsafeBytes { data in
                withUnsafePointer(to: &source) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(descriptor, data.baseAddress, data.count, 0, $0, length)
                    }
                }
            }
        }
    }
    func close() {
        if started { completed.wait() }
        Darwin.close(descriptor)
    }
}
#endif
