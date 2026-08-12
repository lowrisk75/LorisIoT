import Foundation

/// Pure, testable retry/backoff policy — no clock, no networking. Backoff table + steady-state delay +
/// reconnect-storm suppression (only reset after a session lives ≥ `stableSessionSeconds`).
/// Generalized from Éclair `OBDReconnectPolicy` + Lumen's WebSocket backoff.
public struct RetryPolicy: Sendable, Equatable {
    /// Delays (seconds) for attempts 1,2,3… capped at the last value for further attempts.
    public let backoff: [Double]
    /// A session must survive at least this long before the backoff index resets to 0 — defeats a
    /// proxy that idle-closes at a fixed cadence.
    public let stableSessionSeconds: Double
    /// After exhausting `backoff`, keep retrying at this cadence (nil = give up).
    public let steadyStateSeconds: Double?

    public init(backoff: [Double] = [1, 2, 4, 8, 16, 30],
                stableSessionSeconds: Double = 30,
                steadyStateSeconds: Double? = 60) {
        self.backoff = backoff.isEmpty ? [1] : backoff
        self.stableSessionSeconds = stableSessionSeconds
        self.steadyStateSeconds = steadyStateSeconds
    }

    /// Delay before the given 1-based attempt. Attempts past the table use `steadyStateSeconds`
    /// (or the last backoff value if steady-state is nil).
    public func delay(forAttempt attempt: Int) -> Double {
        let a = max(1, attempt)
        if a <= backoff.count { return backoff[a - 1] }
        return steadyStateSeconds ?? backoff[backoff.count - 1]
    }

    /// Whether to keep retrying at this attempt. Infinite unless `steadyStateSeconds` is nil, in
    /// which case we stop once the backoff table is exhausted.
    public func shouldRetry(attempt: Int) -> Bool {
        steadyStateSeconds != nil || attempt <= backoff.count
    }

    /// Decide the next attempt index given how long the just-ended session lasted. A session that
    /// survived ≥ `stableSessionSeconds` resets to attempt 1; a short-lived one keeps ramping.
    public func nextAttempt(afterSessionLasting seconds: Double, previousAttempt: Int) -> Int {
        seconds >= stableSessionSeconds ? 1 : previousAttempt + 1
    }
}
