import Foundation

/// Where a control call runs. This alone does not establish Local Network authorization or reachability.
public enum ExecutionContext: Sendable, Equatable {
    case app
    case systemExtension

    /// Historical preference retained for source compatibility. Use an explicit routing policy.
    @available(*, deprecated, message: "Execution context does not establish network permission. Use TransportRoutingPolicy.")
    public var prefersRemoteTransport: Bool { self == .systemExtension }
}

/// Caller-selected routing, independent of extension identity. Fallback still requires replay safety.
public enum TransportRoutingPolicy: Sendable, Equatable {
    case localOnly, localFirst, remoteOnly, remoteFirst
}
