import Foundation
import Testing
@testable import IoTCore

@Suite struct CoreReliabilityRegressionTests {
    @Test func corruptCheckpointCannotBlockAnExplicitStop() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("broken checkpoint".utf8).write(to: url)
        let device = ConfirmingActuator(initiallyOn: true)
        let safe = SafeActuator(device, limits: .init(maxContinuousRuntime: 60),
            runtimeStore: FileActuatorRuntimeStore(url: url))
        #expect(try await safe.setOn(false).isOn == false)
        #expect(await device.stops == 1)
        #expect(try await FileActuatorRuntimeStore(url: url).startedAt() == nil)
    }

    @Test func missingCheckpointDoesNotInventRuntimeForAnAlreadyRunningDevice() async {
        let device = ConfirmingActuator(initiallyOn: true)
        let safe = SafeActuator(device, limits: .init(maxContinuousRuntime: 60))
        await #expect(throws: (any Error).self) { try await safe.setOn(true) }
        #expect(await device.starts == 0)
        #expect(await device.stops == 0)
    }

    /// A start awaits network I/O; a stop pressed meanwhile must be honoured, and must win: the start
    /// completing after it cannot leave the device running.
    @Test func explicitStopIsNeverRefusedWhileAStartIsInFlight() async throws {
        let device = GatedActuator()
        let safe = SafeActuator(device, limits: .init(maxContinuousRuntime: 60))
        let start = Task { try await safe.setOn(true) }
        await device.waitUntilStartEntered()
        // The stop is sent at once; its answer waits for the overlapped start to resolve.
        let stop = Task { try await safe.setOn(false) }
        while await device.stops == 0 { await Task.yield() }
        await device.releasePendingStart()
        let stopped = try await stop.value
        #expect(stopped.isOn == false)
        _ = try? await start.value
        #expect(await device.read().isOn == false)
    }

    /// A stop that lands while a start is still reading its checkpoint must not leave a start time behind.
    @Test func stopOvertakingAStartBeforeTheWireLeavesNoRuntimeCheckpoint() async throws {
        let device = ConfirmingActuator(initiallyOn: false)
        let store = GatedRuntimeStore()
        await store.gateNextRead()
        let safe = SafeActuator(device, limits: .init(maxContinuousRuntime: 60), runtimeStore: store)
        let start = Task { try await safe.setOn(true) }
        await store.waitUntilReadEntered()
        _ = try await safe.setOn(false)
        await store.releaseRead()
        _ = try? await start.value
        #expect(await device.read().isOn == false)
        #expect(await store.value == nil, "device is off but a start time was persisted")
    }

    /// A stop still on the wire must not erase the checkpoint of a newer start that completed meanwhile.
    @Test func slowStopDoesNotEraseTheCheckpointOfANewerStart() async throws {
        let device = SlowStopActuator()
        let store = GatedRuntimeStore()
        let safe = SafeActuator(device, limits: .init(maxContinuousRuntime: 60), runtimeStore: store)
        let stop = Task { try await safe.setOn(false) }
        await device.waitUntilStopEntered()
        _ = try await safe.setOn(true)
        await device.releaseStop()
        _ = try? await stop.value
        #expect(await device.read().isOn == true)
        #expect(await store.value != nil, "device is running without a runtime checkpoint")
    }

    /// The ON executes but its response is lost after a stop already cleared the way: the device must
    /// never be left running without a checkpoint.
    @Test func stopOverlappingAStartWhoseResponseIsLostNeverLeavesAnUncheckpointedRun() async throws {
        let device = LostResponseActuator()
        let store = GatedRuntimeStore()
        let safe = SafeActuator(device, limits: .init(maxContinuousRuntime: 60), runtimeStore: store)
        let start = Task { try await safe.setOn(true) }
        await device.waitUntilStartEntered()
        let stop = Task { try await safe.setOn(false) }
        while await device.stops == 0 { await Task.yield() }
        await device.releasePendingStart()
        _ = try? await start.value
        #expect(try await stop.value.isOn == false)
        let on = await device.read().isOn == true
        let checkpoint = await store.value
        #expect(!(on && checkpoint == nil), "device running without a runtime checkpoint")
        #expect(on == false, "the explicit stop was overridden by the late start")
    }

    /// A stop issued while a start is on the wire cannot know the order at the relay. If that start's
    /// corrective OFF then fails, the stop must not clear the checkpoint when its own reply arrives.
    @Test func overlappingStopDoesNotClearTheCheckpointAfterAFailedCorrectiveStop() async throws {
        let device = ScriptedOverlapActuator()
        let store = GatedRuntimeStore()
        let safe = SafeActuator(device, limits: .init(maxContinuousRuntime: 60), runtimeStore: store)
        let start = Task { try await safe.setOn(true) }
        await device.waitUntilStartEntered()
        let stop = Task { try await safe.setOn(false) }
        await device.waitUntilStopEntered()
        await device.releaseStart()          // ON lands after the stop's OFF; the corrective OFF then fails
        _ = try? await start.value
        await device.releaseStop()           // the overlapping stop's delayed "off" reply
        let stopResult = try? await stop.value
        let on = await device.read().isOn == true
        let checkpoint = await store.value
        #expect(!(on && checkpoint == nil), "device running without a runtime checkpoint")
        #expect(!(on && stopResult?.isOn == false), "stop reported confirmed OFF while the device is ON")
    }

    /// A slow stop resuming while a newer start is saving its checkpoint must not wipe that checkpoint.
    @Test func slowStopResumingDuringANewerStartsSaveDoesNotWipeIt() async throws {
        let device = SlowStopActuator()
        let store = GatedRuntimeStore()
        await store.seed(Date().addingTimeInterval(-1))
        let safe = SafeActuator(device, limits: .init(maxContinuousRuntime: 60), runtimeStore: store)
        let stop = Task { try await safe.setOn(false) }
        await device.waitUntilStopEntered()
        await store.gateNextWrite()
        let start = Task { try await safe.setOn(true) }
        await store.waitUntilWriteEntered()
        await device.releaseStop()
        _ = try? await stop.value
        await store.releaseWrite()
        _ = try? await start.value
        let on = await device.read().isOn == true
        let checkpoint = await store.value
        #expect(!(on && checkpoint == nil), "device running without a runtime checkpoint")
    }

    /// A start that never resolves cannot hold an overlapping stop's answer forever, nor let it claim OFF.
    @Test func stopOverlappingAHungStartAnswersUnconfirmedWithinItsBound() async throws {
        let device = GatedActuator()
        let safe = SafeActuator(device, limits: .init(maxContinuousRuntime: 60))
        await safe.setOverlapResolutionTimeout(.milliseconds(100))
        let start = Task { try await safe.setOn(true) }
        await device.waitUntilStartEntered()
        let began = ContinuousClock.now
        await #expect(throws: SafetyError.stopUnconfirmed) { _ = try await safe.setOn(false) }
        #expect(ContinuousClock.now - began < .seconds(2))
        #expect(await device.stops == 1)
        await device.releasePendingStart()
        _ = try? await start.value
    }

    @Test func decodingCannotBypassValidatedLevel() throws {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(UnitInterval.self, from: Data(#"{"value":2}"#.utf8))
        }
        #expect(try JSONDecoder().decode(UnitInterval.self, from: Data(#"{"value":0.5}"#.utf8)).value == 0.5)
    }

    @Test func failedForcedStopDoesNotForgetRunningDevice() async throws {
        let clock = MutableClock()
        let physical = FailingStopActuator()
        let safe = SafeActuator(physical, limits: SafetyLimits(maxContinuousRuntime: 60), now: { clock.now })
        _ = try await safe.setOn(true)
        clock.advance(61)
        _ = try? await safe.setOn(true)
        _ = try? await safe.setOn(true)
        #expect(await physical.starts == 1)
        #expect(await physical.stops == 2)
    }

    @Test func runtimeCheckpointSurvivesActorRecreationAndFailedStop() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = MutableClock()
        let physical = FailingStopActuator()
        let first = SafeActuator(physical, limits: .init(maxContinuousRuntime: 60),
            runtimeStore: FileActuatorRuntimeStore(url: url), now: { clock.now })
        _ = try await first.setOn(true)
        let started = clock.now
        clock.advance(61)
        let next = SafeActuator(physical, limits: .init(maxContinuousRuntime: 60),
            runtimeStore: FileActuatorRuntimeStore(url: url), now: { clock.now })
        await #expect(throws: SafetyError.stopUnconfirmed) { try await next.setOn(true) }
        #expect(await physical.starts == 1)
        #expect(try await FileActuatorRuntimeStore(url: url).startedAt() == started)
    }
}

private actor FailingStopActuator: Actuator {
    nonisolated let vendor = "test"
    private(set) var starts = 0
    private(set) var stops = 0
    func read() async throws -> ActuatorState { ActuatorState(isOn: starts > 0) }
    func setOn(_ on: Bool) async throws -> ActuatorState {
        if on { starts += 1; return ActuatorState(isOn: true) }
        stops += 1
        throw IoTError.timeout
    }
}

/// Start blocks inside the physical command until released, like a slow relay or network timeout.
private actor GatedActuator: Actuator {
    nonisolated let vendor = "test"
    private var on = false
    private(set) var starts = 0
    private(set) var stops = 0
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func read() -> ActuatorState { .init(isOn: on) }
    func setOn(_ value: Bool) async -> ActuatorState {
        if value {
            starts += 1; entered = true
            enteredWaiter?.resume(); enteredWaiter = nil
            await withCheckedContinuation { release = $0 }
            on = true
        } else {
            stops += 1; on = false
        }
        return .init(isOn: on)
    }
    func waitUntilStartEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func releasePendingStart() { release?.resume(); release = nil }
}

private actor ConfirmingActuator: Actuator {
    nonisolated let vendor = "test"
    private var on: Bool
    private(set) var starts = 0
    private(set) var stops = 0
    init(initiallyOn: Bool) { on = initiallyOn }
    func read() -> ActuatorState { .init(isOn: on) }
    func setOn(_ value: Bool) -> ActuatorState {
        on = value
        if value { starts += 1 } else { stops += 1 }
        return .init(isOn: on)
    }
}

private actor GatedRuntimeStore: ActuatorRuntimeStore {
    private(set) var value: Date?
    private var gated = false
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func gateNextRead() { gated = true }
    func startedAt() async -> Date? {
        if gated {
            gated = false; entered = true
            enteredWaiter?.resume(); enteredWaiter = nil
            await withCheckedContinuation { release = $0 }
        }
        return value
    }
    private var writeGated = false
    private var writeEntered = false
    private var writeWaiter: CheckedContinuation<Void, Never>?
    private var writeRelease: CheckedContinuation<Void, Never>?
    func seed(_ date: Date?) { value = date }
    func gateNextWrite() { writeGated = true }
    /// Like a real store, the write is applied synchronously; only the return is held back.
    func setStartedAt(_ date: Date?) async {
        value = date
        guard writeGated else { return }
        writeGated = false; writeEntered = true
        writeWaiter?.resume(); writeWaiter = nil
        await withCheckedContinuation { writeRelease = $0 }
    }
    func waitUntilWriteEntered() async {
        if writeEntered { return }
        await withCheckedContinuation { writeWaiter = $0 }
    }
    func releaseWrite() { writeRelease?.resume(); writeRelease = nil }
    func waitUntilReadEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func releaseRead() { release?.resume(); release = nil }
}

/// The relay switches off at once, but the confirmation of the stop is held back.
private actor SlowStopActuator: Actuator {
    nonisolated let vendor = "test"
    private var on = true
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func read() -> ActuatorState { .init(isOn: on) }
    func setOn(_ value: Bool) async -> ActuatorState {
        on = value
        guard !value, !entered else { return .init(isOn: value) }
        entered = true
        enteredWaiter?.resume(); enteredWaiter = nil
        await withCheckedContinuation { release = $0 }
        return .init(isOn: false)
    }
    func waitUntilStopEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func releaseStop() { release?.resume(); release = nil }
}

/// The ON reaches the relay, but its response never comes back.
private actor LostResponseActuator: Actuator {
    nonisolated let vendor = "test"
    private var on = false
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func read() -> ActuatorState { .init(isOn: on) }
    private(set) var stops = 0
    func setOn(_ value: Bool) async throws -> ActuatorState {
        guard value else { stops += 1; on = false; return .init(isOn: false) }
        entered = true
        enteredWaiter?.resume(); enteredWaiter = nil
        await withCheckedContinuation { release = $0 }
        on = true
        throw IoTError.timeout
    }
    func waitUntilStartEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func releasePendingStart() { release?.resume(); release = nil }
}

/// Start ON is held; the first OFF switches the relay off at once but its reply is held; the ON then
/// lands (relay on); any further OFF fails.
private actor ScriptedOverlapActuator: Actuator {
    nonisolated let vendor = "test"
    private var on = false
    private var offs = 0
    private var startEntered = false, stopEntered = false
    private var startWaiter: CheckedContinuation<Void, Never>?, stopWaiter: CheckedContinuation<Void, Never>?
    private var startRelease: CheckedContinuation<Void, Never>?, stopRelease: CheckedContinuation<Void, Never>?
    func read() -> ActuatorState { .init(isOn: on) }
    func setOn(_ value: Bool) async throws -> ActuatorState {
        if value {
            startEntered = true; startWaiter?.resume(); startWaiter = nil
            await withCheckedContinuation { startRelease = $0 }
            on = true
            return .init(isOn: true)
        }
        offs += 1
        guard offs == 1 else { throw IoTError.timeout }
        on = false
        stopEntered = true; stopWaiter?.resume(); stopWaiter = nil
        await withCheckedContinuation { stopRelease = $0 }
        return .init(isOn: false)
    }
    func waitUntilStartEntered() async { if startEntered { return }; await withCheckedContinuation { startWaiter = $0 } }
    func waitUntilStopEntered() async { if stopEntered { return }; await withCheckedContinuation { stopWaiter = $0 } }
    func releaseStart() { startRelease?.resume(); startRelease = nil }
    func releaseStop() { stopRelease?.resume(); stopRelease = nil }
}
