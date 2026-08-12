import Foundation

/// Stops hammering a server that's down. `closed → open(until) → halfOpen → closed|open`. Opens after
/// `failureThreshold` consecutive failures; while open, `allow()` is false until the cooldown passes,
/// then one trial (half-open) decides. Cooldown extends exponentially on repeated opens.
/// Generalized from Lumen `CircuitBreaker`. Injectable clock keeps it deterministically testable.
public actor CircuitBreaker {
    public enum State: Sendable, Equatable { case closed, open, halfOpen }

    private let failureThreshold: Int
    private let baseCooldown: Double        // seconds
    private let maxCooldown: Double
    private let now: @Sendable () -> Date

    private var consecutiveFailures = 0
    private var openUntil: Date?
    private var openCount = 0               // drives exponential cooldown growth

    public init(failureThreshold: Int = 5,
                baseCooldown: Double = 30,
                maxCooldown: Double = 300,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.failureThreshold = max(1, failureThreshold)
        self.baseCooldown = baseCooldown
        self.maxCooldown = maxCooldown
        self.now = now
    }

    public var state: State {
        guard let openUntil else { return .closed }
        return now() >= openUntil ? .halfOpen : .open
    }

    /// May a call proceed? True when closed or when the cooldown has elapsed (half-open trial).
    public func allow() -> Bool {
        switch state {
        case .closed, .halfOpen: return true
        case .open: return false
        }
    }

    public func recordSuccess() {
        consecutiveFailures = 0
        openUntil = nil
        openCount = 0
    }

    public func recordFailure() {
        consecutiveFailures += 1
        // Re-open immediately if a half-open trial failed, or once the threshold is hit.
        if state == .halfOpen || consecutiveFailures >= failureThreshold {
            openCount += 1
            let cooldown = min(maxCooldown, baseCooldown * pow(2, Double(openCount - 1)))
            openUntil = now().addingTimeInterval(cooldown)
            consecutiveFailures = 0
        }
    }
}
