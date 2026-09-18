import Foundation
#if canImport(Darwin)
import Darwin

public protocol GoveeLANClient: Sendable {
    func query(_ query: GoveeLANTransport.Query, host: String, timeout: TimeInterval) async throws -> GoveeLANMessage
}

public protocol GoveeLANControlClient: GoveeLANClient {
    /// Success means the operating system accepted the datagram, not that the device applied it.
    func send(_ command: GoveeLANCommand, host: String) async throws
}

/// Targeted LAN exchanges. Each exchange owns its socket until completion.
/// Govee replies on port 4002; a bind conflict fails explicitly instead of sharing replies.
/// Source filtering is not authentication: the Govee LAN protocol has no authenticated reply.
public struct GoveeLANTransport: GoveeLANControlClient {
    public enum Failure: Error, Equatable { case invalidEndpoint, busyOrUnavailable, timeout, socket, cancelled }
    public enum Query: Sendable { case discovery, status }
    private let receivePort: UInt16
    private let discoveryPort: UInt16
    private let statusPort: UInt16

    public init() {
        receivePort = 4002; discoveryPort = 4001; statusPort = 4003
    }

    // Test-only port injection; production must listen on the protocol's fixed reply port.
    init(receivePort: UInt16, discoveryPort: UInt16, statusPort: UInt16) {
        self.receivePort = receivePort; self.discoveryPort = discoveryPort; self.statusPort = statusPort
    }

    public func query(_ query: Query, host: String, timeout: TimeInterval = 2) async throws -> GoveeLANMessage {
        guard let result = try await perform(query, command: nil, host: host, timeout: timeout) else {
            throw Failure.socket
        }
        return result
    }

    public func send(_ command: GoveeLANCommand, host: String) async throws {
        let payload = try command.encoded()
        _ = try await perform(.status, command: payload, host: host, timeout: 2)
    }

    private func perform(_ query: Query, command: Data?, host: String,
                         timeout: TimeInterval) async throws -> GoveeLANMessage? {
        guard timeout.isFinite, timeout > 0, timeout <= 5 else { throw Failure.invalidEndpoint }
        var parsed = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &parsed) }) == 1,
              parsed.s_addr != INADDR_ANY, parsed.s_addr != INADDR_BROADCAST,
              (UInt32(bigEndian: parsed.s_addr) >> 28) != 0xe else { throw Failure.invalidEndpoint }
        let address = parsed.s_addr
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try exchange(query, address: address,
                            command: command, timeout: timeout, cancellation: cancellation))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private func exchange(_ query: Query, address: in_addr_t, command: Data?, timeout: TimeInterval,
                          cancellation: CancellationFlag) throws -> GoveeLANMessage? {
        try cancellation.check()
        let socketFD = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { throw Failure.socket }
        defer { Darwin.close(socketFD) }
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = receivePort.bigEndian
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw Failure.busyOrUnavailable }
        guard fcntl(socketFD, F_SETFL, O_NONBLOCK) == 0 else { throw Failure.socket }
        var destination = local
        destination.sin_addr.s_addr = address
        destination.sin_port = (query == .discovery ? discoveryPort : statusPort).bigEndian
        let payload = command ?? (query == .discovery ? GoveeLANMessage.discoveryQuery : GoveeLANMessage.statusQuery)
        try cancellation.check()
        let sent = payload.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(socketFD, bytes.baseAddress, bytes.count, 0, $0,
                                  socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == payload.count else { throw Failure.socket }
        // Never wait for or fabricate an acknowledgement: these commands have no ACK packet.
        // Cancellation after this point cannot retract the datagram.
        if command != nil { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var buffer = [UInt8](repeating: 0, count: 8193)
        while ProcessInfo.processInfo.systemUptime < deadline {
            try cancellation.check()
            var descriptor = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, min(50, Int32((deadline - ProcessInfo.processInfo.systemUptime) * 1000)))
            let result = Darwin.poll(&descriptor, 1, remaining)
            if result < 0 {
                if errno == EINTR { continue }
                throw Failure.socket
            }
            guard result > 0 else { continue }
            guard descriptor.revents & Int16(POLLIN) != 0 else { throw Failure.socket }
            var source = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &source) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.recvfrom(socketFD, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard count >= 0 else {
                if errno == EAGAIN || errno == EINTR { continue }
                throw Failure.socket
            }
            guard source.sin_family == sa_family_t(AF_INET), source.sin_addr.s_addr == address,
                  let message = try? GoveeLANMessage.decode(Data(buffer.prefix(count))) else { continue }
            switch (query, message) {
            case (.status, .status):
                try cancellation.check()
                return message
            case (.discovery, .discovery(let found)):
                var claimed = in_addr()
                guard found.ip.withCString({ inet_pton(AF_INET, $0, &claimed) }) == 1,
                      claimed.s_addr == address else { continue }
                try cancellation.check()
                return message
            default: continue
            }
        }
        try cancellation.check()
        throw Failure.timeout
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw GoveeLANTransport.Failure.cancelled }
    }
}
#endif
