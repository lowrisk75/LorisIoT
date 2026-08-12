import Foundation
#if canImport(Network)
import Network
#endif

public struct NetworkStatus: Sendable, Equatable {
    public enum Interface: String, Sendable { case wifi, cellular, wired, other, none }
    public var isConnected: Bool
    public var interface: Interface
    public var isExpensive: Bool      // cellular / hotspot
    public var isConstrained: Bool    // Low Data Mode

    public init(isConnected: Bool, interface: Interface, isExpensive: Bool, isConstrained: Bool) {
        self.isConnected = isConnected
        self.interface = interface
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    public static let unknown = NetworkStatus(isConnected: true, interface: .other,
                                              isExpensive: false, isConstrained: false)
}

/// Wraps `NWPathMonitor` as an `AsyncStream<NetworkStatus>` — the shared reachability primitive.
/// Generalized from Éclair `NetworkStatusMonitor`. Reconnect logic keys off interface changes here
/// (not screen-lock wifi flicker). No-op fallback on platforms without Network.framework.
public final class NetworkStatusMonitor: Sendable {
    #if canImport(Network)
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.lorislabs.iot.netmonitor")
    #endif

    public init() {}

    /// A stream that yields the current status immediately and on every path change.
    public func stream() -> AsyncStream<NetworkStatus> {
        AsyncStream { continuation in
            #if canImport(Network)
            monitor.pathUpdateHandler = { path in
                continuation.yield(Self.map(path))
            }
            monitor.start(queue: queue)
            continuation.onTermination = { [monitor] _ in monitor.cancel() }
            #else
            continuation.yield(.unknown)
            continuation.finish()
            #endif
        }
    }

    #if canImport(Network)
    private static func map(_ path: NWPath) -> NetworkStatus {
        let interface: NetworkStatus.Interface = {
            if path.usesInterfaceType(.wifi) { return .wifi }
            if path.usesInterfaceType(.cellular) { return .cellular }
            if path.usesInterfaceType(.wiredEthernet) { return .wired }
            return path.status == .satisfied ? .other : .none
        }()
        return NetworkStatus(isConnected: path.status == .satisfied,
                             interface: interface,
                             isExpensive: path.isExpensive,
                             isConstrained: path.isConstrained)
    }
    #endif
}
