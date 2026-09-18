import Foundation
import IoTCore
#if canImport(Darwin)
import Darwin

/// A bounded discovery result. Conflicts are quarantined for the whole scan, never resolved
/// by whichever unauthenticated UDP packet happened to arrive last.
struct GoveeDiscoveryInventory {
    private var records: [String: GoveeLANMessage.Discovery] = [:]
    private var rejectedIDs: Set<String> = []
    private var rejectedHosts: Set<String> = []
    private var seen = 0
    var hasConflicts: Bool { !rejectedIDs.isEmpty }
    var devices: [GoveeDeviceConfig] {
        records.values.sorted { $0.device < $1.device }.map {
            GoveeDeviceConfig(device: $0.device, model: $0.sku, host: $0.ip, name: "Govee " + $0.sku)
        }
    }
    mutating func receive(_ data: Data, source: String) throws {
        seen += 1
        guard seen <= 512 else { throw IoTError.transport("Govee discovery response limit exceeded") }
        guard case .discovery(let found) = try? GoveeLANMessage.decode(data), found.ip == source else { return }
        let id = found.device.uppercased()
        guard !rejectedIDs.contains(id), !rejectedHosts.contains(source) else { return }
        let collisions = records.filter {
            ($0.key == id && ($0.value.ip != found.ip || $0.value.sku != found.sku))
            || ($0.key != id && $0.value.ip == found.ip)
        }
        if !collisions.isEmpty {
            rejectedIDs.insert(id); rejectedHosts.insert(source)
            for (key, value) in collisions {
                rejectedIDs.insert(key); rejectedHosts.insert(value.ip); records[key] = nil
            }
            return
        }
        guard records[id] != nil || records.count < 64 else {
            throw IoTError.transport("Govee discovery device limit exceeded")
        }
        records[id] = found
    }
}

public struct GoveeDiscoveryNetwork: Hashable, Identifiable, Sendable {
    public let interfaceName: String
    public let address: String
    public var id: String { interfaceName + ":" + address }
}

public enum GoveeDiscovery {
    /// Reads local interface metadata only. Excludes loopback and point-to-point/VPN links.
    /// Enumeration does not send discovery packets or select a network on the user's behalf.
    public static func localNetworks() throws -> [GoveeDiscoveryNetwork] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { throw IoTError.transport("Network interfaces unavailable") }
        defer { if let first { freeifaddrs(first) } }
        var cursor = first
        var networks: Set<GoveeDiscoveryNetwork> = []
        while let current = cursor {
            let entry = current.pointee
            cursor = entry.ifa_next
            let required = UInt32(IFF_UP | IFF_RUNNING | IFF_MULTICAST)
            guard entry.ifa_flags & required == required,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  let raw = entry.ifa_addr, raw.pointee.sa_family == sa_family_t(AF_INET),
                  let name = String(validatingCString: entry.ifa_name) else { continue }
            var ipv4 = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &text, socklen_t(text.count)) != nil else { continue }
            let address = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            networks.insert(GoveeDiscoveryNetwork(interfaceName: name, address: address))
            guard networks.count <= 32 else { throw IoTError.transport("Too many network interfaces") }
        }
        return networks.sorted { $0.id < $1.id }
    }
    /// Read-only multicast on an explicitly selected local IPv4 interface. No auto-retry.
    /// The caller owns local-network permission and must pause other Govee exchanges first.
    public static func scan(interfaceAddress: String, duration: TimeInterval = 2) async throws -> [GoveeDeviceConfig] {
        guard duration.isFinite, duration > 0, duration <= 5 else { throw IoTError.notConfigured }
        var local = in_addr()
        guard interfaceAddress.withCString({ inet_pton(AF_INET, $0, &local) }) == 1,
              local.s_addr != INADDR_ANY, local.s_addr != INADDR_BROADCAST,
              UInt32(bigEndian: local.s_addr) >> 28 != 0xe else { throw IoTError.notConfigured }
        let address = local.s_addr
        let cancelled = DiscoveryCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try collect(address: address, duration: duration, cancelled: cancelled)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancelled.cancel() }
    }

    private static func collect(address: in_addr_t, duration: TimeInterval,
                                cancelled: DiscoveryCancellation) throws -> [GoveeDeviceConfig] {
        try cancelled.check()
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw IoTError.transport("Govee discovery socket unavailable") }
        defer { Darwin.close(fd) }
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = UInt16(4002).bigEndian
        // Bind wildcard without reuse to prevent ambiguous ownership with provider sockets.
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw IoTError.transport("Govee reply port unavailable") }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw IoTError.transport("Govee discovery socket setup failed") }
        var interface = in_addr(s_addr: address)
        var ttl: UInt8 = 1
        guard setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &interface, socklen_t(MemoryLayout<in_addr>.size)) == 0,
              setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, 1) == 0 else {
            throw IoTError.transport("Govee discovery interface unavailable")
        }
        var group = local
        group.sin_port = UInt16(4001).bigEndian
        group.sin_addr.s_addr = inet_addr("239.255.255.250")
        try cancelled.check()
        let payload = GoveeLANMessage.discoveryQuery
        let sent = payload.withUnsafeBytes { bytes in
            withUnsafePointer(to: &group) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == payload.count else { throw IoTError.transport("Govee discovery request failed") }
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        var inventory = GoveeDiscoveryInventory()
        var buffer = [UInt8](repeating: 0, count: 8193)
        while ProcessInfo.processInfo.systemUptime < deadline {
            try cancelled.check()
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let wait = max(1, min(50, Int32((deadline - ProcessInfo.processInfo.systemUptime) * 1000)))
            let ready = Darwin.poll(&pollDescriptor, 1, wait)
            if ready < 0 {
                if errno == EINTR { continue }
                throw IoTError.transport("Govee discovery receive failed")
            }
            guard ready > 0 else { continue }
            guard pollDescriptor.revents & Int16(POLLIN) != 0 else { throw IoTError.transport("Govee discovery socket failed") }
            var source = sockaddr_in()
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &source) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &size) }
            }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw IoTError.transport("Govee discovery receive failed")
            }
            guard source.sin_family == sa_family_t(AF_INET) else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &source.sin_addr, &text, socklen_t(text.count)) != nil else { continue }
            let peer = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            try inventory.receive(Data(buffer.prefix(count)), source: peer)
        }
        try cancelled.check()
        guard !inventory.hasConflicts else { throw IoTError.invalidResponse }
        return inventory.devices
    }
}

private final class DiscoveryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = stopped; lock.unlock()
        if value { throw IoTError.cancelled }
    }
}
#endif
