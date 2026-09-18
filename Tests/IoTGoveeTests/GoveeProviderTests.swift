import Foundation
import Testing
import IoTCore
@testable import IoTGovee

#if canImport(Darwin)
struct GoveeProviderTests {
    private let config = GoveeDeviceConfig(device: "AA:BB:CC:DD:EE:FF:00:11", model: "H6022",
                                         host: "127.0.0.1", name: "Fixture")

    @Test func normalizedReadHasUnitsAndNoInventedControl() async throws {
        let fake = Fixture()
        let provider = GoveeProvider(devices: [config], client: fake)
        try await provider.connect()
        let devices = try await provider.devices()
        #expect(devices.count == 1)
        #expect(devices.first?.manufacturer == "Govee")
        let capabilities = try await provider.capabilities(for: config.id)
        #expect(capabilities.control == nil)
        #expect(capabilities.schedule == nil)
        let reader = try #require(capabilities.readState)
        let state = try await reader.state()
        #expect(state.primaryValue == nil)
        #expect(state.attributes["brightness"]?.unit == .percent)
        #expect(state.attributes["brightness"]?.value == .integer(42))
        #expect(state.origin == .local)
        #expect(await fake.discoveryCount == 2)
        await provider.disconnect()
        await #expect(throws: IoTError.notConnected) { try await reader.state() }
    }

    @Test func onboardingDiscoversIdentityWithoutReadingOrChangingPower() async throws {
        let fake = Controlled()
        let found = try await GoveeDeviceConfig.discover(host: " 127.0.0.1 ", client: fake)
        #expect(found.device == config.device)
        #expect(found.model == "H6022")
        #expect(found.name == "Govee H6022")
        #expect(await fake.base.discoveryCount == 1)
        #expect(await fake.base.statusCount == 0)
        #expect(await fake.sends == 0)
    }

    @Test func onboardingRejectsAReplyForAnotherAddress() async {
        await #expect(throws: IoTError.invalidResponse) {
            try await GoveeDeviceConfig.discover(host: "127.0.0.2", client: Fixture())
        }
    }

    @Test func addressReassignmentDoesNotReadAnotherDevice() async throws {
        let fake = Fixture()
        let provider = GoveeProvider(devices: [config], client: fake)
        try await provider.connect()
        let reader = try #require(try await provider.capabilities(for: config.id).readState)
        await fake.replaceIdentity()
        await #expect(throws: IoTError.invalidResponse) { try await reader.state() }
        #expect(await fake.statusCount == 0)
    }

    @Test func duplicateConfigurationFailsBeforeNetwork() async {
        let fake = Fixture()
        let provider = GoveeProvider(devices: [config, config], client: fake)
        await #expect(throws: IoTError.notConfigured) { try await provider.connect() }
        #expect(await fake.discoveryCount == 0)
    }

    @Test func discoveryLeasePausesPollingAndResumesAfterRelease() async throws {
        let fake = Fixture()
        let provider = GoveeProvider(devices: [config], client: fake, observationInterval: .milliseconds(50))
        try await provider.connect()
        let subscriber = try #require(try await provider.capabilities(for: config.id).subscribe)
        let stream = await subscriber.stateChanges()
        let consumer = Task { for try await _ in stream { } }
        let gate = DiscoveryGate()
        let scan = Task {
            try await GoveeProvider.withDiscoveryPaused(providers: [provider]) { await gate.hold() }
        }
        let deadline = ContinuousClock.now + .seconds(1)
        while !(await gate.entered), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await gate.entered)
        let calls = await fake.discoveryCount
        try await Task.sleep(for: .milliseconds(150))
        #expect(await fake.discoveryCount == calls)
        await gate.release()
        try await scan.value
        let resumedDeadline = ContinuousClock.now + .seconds(1)
        while await fake.discoveryCount == calls, ContinuousClock.now < resumedDeadline { await Task.yield() }
        #expect(await fake.discoveryCount > calls)
        await provider.disconnect()
        _ = try? await consumer.value
    }

    @Test func duplicateProviderCannotDeadlockDiscoveryReservation() async {
        let provider = GoveeProvider(devices: [config], client: Fixture())
        await #expect(throws: IoTError.notConfigured) {
            try await GoveeProvider.withDiscoveryPaused(providers: [provider, provider]) { true }
        }
    }

    @Test func subscribersShareTheSameReadAndDisconnectFinishesBoth() async throws {
        let fake = Fixture(blocked: true)
        let provider = GoveeProvider(devices: [config], client: fake)
        try await provider.connect()
        let capability = try #require(try await provider.capabilities(for: config.id).subscribe)
        let first = await capability.stateChanges()
        let second = await capability.stateChanges()
        await fake.releaseStatus()
        var a = first.makeAsyncIterator()
        var b = second.makeAsyncIterator()
        let eventA = try await a.next()
        let eventB = try await b.next()
        guard case .snapshot(let stateA) = eventA, case .snapshot(let stateB) = eventB else {
            Issue.record("Expected shared snapshots"); await provider.disconnect(); return
        }
        #expect(stateA.revision == stateB.revision)
        #expect(await fake.statusCount == 1)
        await provider.disconnect()
        if let _ = try await a.next() { Issue.record("First stream should finish") }
        if let _ = try await b.next() { Issue.record("Second stream should finish") }
    }

    @Test func cancelledLastSubscriberStopsPolling() async throws {
        let fake = Fixture()
        let provider = GoveeProvider(devices: [config], client: fake, observationInterval: .milliseconds(50))
        try await provider.connect()
        let capability = try #require(try await provider.capabilities(for: config.id).subscribe)
        let stream = await capability.stateChanges()
        let task = Task { for try await _ in stream { } }
        let deadline = ContinuousClock.now + .seconds(1)
        while await fake.statusCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await fake.statusCount > 0)
        task.cancel()
        _ = try? await task.value
        // Allow the onTermination actor hop to finish, then check two polling intervals.
        try await Task.sleep(for: .milliseconds(75))
        let stoppedCount = await fake.statusCount
        try await Task.sleep(for: .milliseconds(150))
        #expect(await fake.statusCount == stoppedCount)
        await provider.disconnect()
    }

    @Test func matchingReadbackDoesNotInventTransactionConfirmation() async throws {
        let fake = Controlled()
        let provider = GoveeProvider(devices: [config], client: fake)
        try await provider.connect()
        let control = try #require(try await provider.capabilities(for: config.id).control)
        let command = SetLevelCommand(deviceID: config.id, level: try UnitInterval(0.42))
        let receipt = try await control.execute(command)
        #expect(receipt.outcome == .accepted)
        #expect(receipt.state?.attributes["brightness"]?.value == .integer(42))
        #expect(await fake.sends == 1)
    }

    @Test(arguments: [false, true])
    func commandWaitsForAnActivePollInsteadOfFailingBusy(cancelWhileQueued: Bool) async throws {
        let fake = Controlled(blocked: true)
        let provider = GoveeProvider(devices: [config], client: fake)
        try await provider.connect()
        let capabilities = try await provider.capabilities(for: config.id)
        let subscription = try #require(capabilities.subscribe)
        let control = try #require(capabilities.control)
        let stream = await subscription.stateChanges()
        let consumer = Task { for try await _ in stream { } }
        let deadline = ContinuousClock.now + .seconds(1)
        while await fake.base.statusCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await fake.base.statusCount == 1)
        let command = Task { try await control.execute(SetLevelCommand(deviceID: config.id, level: try UnitInterval(0.42))) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await fake.sends == 0)
        if cancelWhileQueued { command.cancel() }
        await fake.base.releaseStatus()
        let result = await command.result
        await provider.disconnect()
        _ = try? await consumer.value
        if cancelWhileQueued {
            switch result {
            case .success: Issue.record("Cancelled queued command must not dispatch")
            case .failure: break
            }
            #expect(await fake.sends == 0)
        } else {
            let receipt = try result.get()
            #expect(receipt.outcome == .accepted)
            #expect(await fake.sends == 1)
        }
    }

    @Test func failedDispatchIsUncertainAndNeverRetried() async throws {
        let fake = Controlled(fails: true)
        let provider = GoveeProvider(devices: [config], client: fake)
        try await provider.connect()
        let control = try #require(try await provider.capabilities(for: config.id).control)
        let receipt = try await control.execute(SetPowerCommand(deviceID: config.id, isOn: true))
        #expect(receipt.outcome == .uncertain)
        #expect(await fake.sends == 1)
    }

    @Test func handleCannotCommandAnotherDevice() async throws {
        let fake = Controlled()
        let provider = GoveeProvider(devices: [config], client: fake)
        try await provider.connect()
        let control = try #require(try await provider.capabilities(for: config.id).control)
        await #expect(throws: IoTError.notConfigured) {
            try await control.execute(SetPowerCommand(deviceID: "other", isOn: false))
        }
        #expect(await fake.sends == 0)
    }

    @Test func transportTimeoutUsesTheSharedSDKError() async {
        let provider = GoveeProvider(devices: [config], client: Unreachable())
        await #expect(throws: IoTError.timeout) { try await provider.connect() }
        await #expect(throws: IoTError.notConnected) { try await provider.devices() }
    }

    @Test func disconnectRejectsLateUncooperativeReply() async throws {
        let fake = Fixture(slow: true)
        let provider = GoveeProvider(devices: [config], client: fake)
        try await provider.connect()
        let reader = try #require(try await provider.capabilities(for: config.id).readState)
        let pending = Task { try await reader.state() }
        let deadline = ContinuousClock.now + .seconds(1)
        while await fake.statusCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await fake.statusCount == 1)
        await provider.disconnect()
        await #expect(throws: (any Error).self) { try await pending.value }
        await #expect(throws: IoTError.notConnected) { try await provider.devices() }
    }
}

private struct Unreachable: GoveeLANClient {
    func query(_ query: GoveeLANTransport.Query, host: String, timeout: TimeInterval) async throws -> GoveeLANMessage {
        throw GoveeLANTransport.Failure.timeout
    }
}

private actor DiscoveryGate {
    var entered = false
    var released = false
    var pending: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { pending = $0 }
    }
    func release() { released = true; pending?.resume(); pending = nil }
}

private actor Controlled: GoveeLANControlClient {
    let base: Fixture
    var sends = 0
    let fails: Bool
    init(fails: Bool = false, blocked: Bool = false) { self.fails = fails; base = Fixture(blocked: blocked) }
    func query(_ query: GoveeLANTransport.Query, host: String, timeout: TimeInterval) async throws -> GoveeLANMessage {
        try await base.query(query, host: host, timeout: timeout)
    }
    func send(_ command: GoveeLANCommand, host: String) async throws {
        sends += 1
        if fails { throw GoveeLANTransport.Failure.socket }
    }
}

private actor Fixture: GoveeLANClient {
    var discoveryCount = 0
    var statusCount = 0
    var differentIdentity = false
    let slow: Bool
    var blocked: Bool
    var release: CheckedContinuation<Void, Never>?
    init(slow: Bool = false, blocked: Bool = false) { self.slow = slow; self.blocked = blocked }
    func releaseStatus() { blocked = false; release?.resume(); release = nil }
    func replaceIdentity() { differentIdentity = true }
    func query(_ query: GoveeLANTransport.Query, host: String, timeout: TimeInterval) async throws -> GoveeLANMessage {
        switch query {
        case .discovery:
            discoveryCount += 1
            let id = differentIdentity ? "AA:BB:CC:DD:EE:FF:00:22" : "AA:BB:CC:DD:EE:FF:00:11"
            let wire = #"{"msg":{"cmd":"scan","data":{"device":"IDENTITY","sku":"H6022","ip":"127.0.0.1"}}}"#
                .replacingOccurrences(of: "IDENTITY", with: id)
            return try GoveeLANMessage.decode(Data(wire.utf8))
        case .status:
            statusCount += 1
            if blocked { await withCheckedContinuation { release = $0 } }
            if slow { try? await Task.sleep(for: .milliseconds(100)) }
            return try GoveeLANMessage.decode(Data(#"{"msg":{"cmd":"devStatus","data":{"brightness":42}}}"#.utf8))
        }
    }
}
#endif
