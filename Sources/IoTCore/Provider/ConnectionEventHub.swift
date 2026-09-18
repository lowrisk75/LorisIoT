import Foundation

/// Multicast connection observations. New listeners receive the latest observation immediately.
/// Status is replaceable; a slow listener gets the newest state instead of growing an unbounded queue.
public actor ConnectionEventHub {
    private var current: ProviderConnectionEvent
    private var continuations: [UUID: AsyncStream<ProviderConnectionEvent>.Continuation] = [:]

    public init(providerID: ProviderID) {
        current = ProviderConnectionEvent(providerID: providerID, state: .disconnected)
    }

    public func publish(_ state: ProviderConnectionState, reason: String? = nil) {
        guard current.state != state || current.reason != reason else { return }
        current = ProviderConnectionEvent(providerID: current.providerID, state: state, reason: reason)
        for continuation in continuations.values { continuation.yield(current) }
    }

    public func events() -> AsyncStream<ProviderConnectionEvent> {
        let key = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[key] = continuation
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in Task { await self?.remove(key) } }
        }
    }

    private func remove(_ key: UUID) { continuations[key] = nil }
    public func finish() {
        let pending = continuations.values
        continuations = [:]
        for continuation in pending { continuation.finish() }
    }
}
