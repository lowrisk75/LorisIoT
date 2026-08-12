import Testing
import Foundation
@testable import IoTCore

@Suite struct SafetyEnvelopeTests {
    private func cal() -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func at(_ h: Int, _ m: Int) -> Date {
        cal().date(from: DateComponents(year: 2026, month: 1, day: 1, hour: h, minute: m))!
    }

    @Test func offIsAlwaysAllowed() {
        let d = SafetyEnvelope.evaluate(requestOn: false, runningSince: nil,
                                        limits: SafetyLimits(forbiddenWindows: [0..<1440]),
                                        now: at(3, 0), calendar: cal())
        #expect(d == .allow)   // turning OFF is never blocked, even inside a forbidden window
    }

    @Test func runtimeOverrunForceStopsEvenWithOverride() {
        let started = at(6, 0)
        let d = SafetyEnvelope.evaluate(requestOn: true, runningSince: started,
                                        limits: SafetyLimits(maxContinuousRuntime: 3600,
                                                             overrideProtectionActive: true),
                                        now: at(7, 30), calendar: cal())   // 90 min > 60 min cap
        if case .forceStop = d {} else { Issue.record("expected forceStop, got \(d)") }
    }

    @Test func forbiddenWindowDeniesOn() {
        let d = SafetyEnvelope.evaluate(requestOn: true, runningSince: nil,
                                        limits: SafetyLimits(forbiddenWindows: [(1*60)..<(6*60)]),
                                        now: at(3, 0), calendar: cal())
        if case .deny = d {} else { Issue.record("expected deny, got \(d)") }
    }

    @Test func overrideAllowsOnInsideForbiddenWindow() {
        let d = SafetyEnvelope.evaluate(requestOn: true, runningSince: nil,
                                        limits: SafetyLimits(forbiddenWindows: [(1*60)..<(6*60)],
                                                             overrideProtectionActive: true),
                                        now: at(3, 0), calendar: cal())
        #expect(d == .allow)
    }
}

@Suite struct RetryPolicyTests {
    @Test func delayFollowsTableThenSteadyState() {
        let p = RetryPolicy(backoff: [1, 2, 4], stableSessionSeconds: 30, steadyStateSeconds: 60)
        #expect(p.delay(forAttempt: 1) == 1)
        #expect(p.delay(forAttempt: 3) == 4)
        #expect(p.delay(forAttempt: 4) == 60)   // past the table → steady state
        #expect(p.delay(forAttempt: 99) == 60)
    }

    @Test func stormSuppressionKeepsRampingForShortSessions() {
        let p = RetryPolicy(stableSessionSeconds: 30)
        // a session that died after 2s must NOT reset the backoff
        #expect(p.nextAttempt(afterSessionLasting: 2, previousAttempt: 3) == 4)
        // a session that survived ≥30s resets to attempt 1
        #expect(p.nextAttempt(afterSessionLasting: 45, previousAttempt: 3) == 1)
    }

    @Test func givesUpWhenNoSteadyStateAndTableExhausted() {
        let p = RetryPolicy(backoff: [1, 2], stableSessionSeconds: 30, steadyStateSeconds: nil)
        #expect(p.shouldRetry(attempt: 2))
        #expect(!p.shouldRetry(attempt: 3))
    }
}

/// Mutable injectable clock for deterministic time-based tests.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { _now = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
    func advance(_ s: Double) { lock.lock(); _now = _now.addingTimeInterval(s); lock.unlock() }
}

@Suite struct CircuitBreakerTests {
    @Test func opensAfterThresholdAndRecoversAfterCooldown() async {
        let clock = MutableClock()
        let cb = CircuitBreaker(failureThreshold: 3, baseCooldown: 30, maxCooldown: 300,
                                now: { clock.now })
        #expect(await cb.allow())
        for _ in 0..<3 { await cb.recordFailure() }
        #expect(!(await cb.allow()))              // open
        clock.advance(31)
        #expect(await cb.allow())                 // half-open trial permitted
        await cb.recordSuccess()
        #expect(await cb.allow())                 // closed again
    }

    @Test func halfOpenFailureReopensWithLongerCooldown() async {
        let clock = MutableClock()
        let cb = CircuitBreaker(failureThreshold: 1, baseCooldown: 10, maxCooldown: 300,
                                now: { clock.now })
        await cb.recordFailure()                  // open, cooldown 10s
        clock.advance(11)
        #expect(await cb.allow())                 // half-open
        await cb.recordFailure()                  // trial failed → reopen, cooldown 20s
        clock.advance(11)
        #expect(!(await cb.allow()))              // still open (needs 20s)
        clock.advance(10)
        #expect(await cb.allow())
    }
}
