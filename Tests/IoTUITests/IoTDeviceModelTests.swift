import Foundation
import Testing
import IoTCore
@testable import IoTUI

@Suite @MainActor struct IoTDeviceModelTests {
    @Test func olderReceiptCannotConfirmAgainstNewerContradictoryState() async {
        let provider = RevisionUIProvider()
        let model = IoTDeviceModel(device: UIProvider.device, provider: provider)
        await model.refresh()
        #expect(model.state?.revision.localSequence == 10)
        await model.setPower(true)
        #expect(model.state?.primaryValue == .bool(false))
        #expect(model.state?.revision.localSequence == 10)
        #expect(model.phase == .uncertain)
    }

    @Test func staleMatchingReceiptDoesNotConfirmAnExplicitStop() async {
        let provider = UIProvider(outcome: .applied)
        let model = IoTDeviceModel(device: UIProvider.device, provider: provider)
        let observation = Task { await model.observe() }
        defer { observation.cancel() }
        for _ in 0..<100 where !model.canControl { await Task.yield() }
        await model.setPower(false)
        #expect(model.phase == .uncertain)
        observation.cancel(); await observation.value
    }
    @Test func acceptedIsNotDisplayedAsApplied() async throws {
        let provider = UIProvider(outcome: .accepted)
        let model = IoTDeviceModel(device: UIProvider.device, provider: provider)
        let observation = Task { await model.observe() }
        defer { observation.cancel() }
        for _ in 0..<100 where !model.canControl { await Task.yield() }
        #expect(model.canControl)
        await model.setPower(true)
        #expect(model.phase == .accepted)
        #expect(model.state?.primaryValue == .bool(false))
        observation.cancel(); await observation.value
    }

    @Test func inconsistentAppliedReceiptIsReportedAsUncertain() async throws {
        let provider = UIProvider(outcome: .applied)
        let model = IoTDeviceModel(device: UIProvider.device, provider: provider)
        let observation = Task { await model.observe() }
        defer { observation.cancel() }
        for _ in 0..<100 where !model.canControl { await Task.yield() }
        await model.setPower(true)
        #expect(model.phase == .uncertain)
        #expect(!model.diagnosticSummary.contains("token"))
        observation.cancel(); await observation.value
    }
}
private actor UIProvider: DeviceProvider {
    nonisolated let id: ProviderID = "fixture"
    nonisolated let displayName = "Fixture"
    static let device = Device(id: "plug", providerID: "fixture", nativeID: "plug", name: "Plug", kind: .outlet, capabilities: [])
    let outcome: CommandOutcome
    init(outcome: CommandOutcome) { self.outcome = outcome }
    func connect() {}
    func disconnect() {}
    func devices() -> [Device] { [Self.device] }
    func capabilities(for deviceID: DeviceID) -> DeviceCapabilitySet {
        DeviceCapabilitySet(descriptors: [], control: UIControl(outcome: outcome), readState: UIRead())
    }
    func connectionEvents() -> AsyncStream<ProviderConnectionEvent> { AsyncStream { $0.finish() } }
}
private func fixtureState() -> DeviceState {
    DeviceState(deviceID: "plug", availability: .online, primaryValue: .bool(false),
                observedAt: .distantPast, receivedAt: .distantPast, origin: .cache, revision: .init(localSequence: 0))
}
private actor UIRead: ReadStateCapability {
    nonisolated let descriptor = CapabilityDescriptor(id: .readState, operations: [.readState])
    func state() -> DeviceState { fixtureState() }
}
private actor UIControl: ControlCapability {
    nonisolated let descriptor = CapabilityDescriptor(id: .control, operations: [.control])
    let outcome: CommandOutcome
    init(outcome: CommandOutcome) { self.outcome = outcome }
    func execute<C: DeviceCommand>(_ command: C) -> CommandReceipt {
        CommandReceipt(commandID: command.id, deviceID: command.deviceID, outcome: outcome, state: fixtureState())
    }
}

private actor RevisionUIProvider: DeviceProvider, ReadStateCapability, ControlCapability {
    nonisolated let id: ProviderID = "fixture"
    nonisolated let displayName = "Revision fixture"
    nonisolated let descriptor = CapabilityDescriptor(id: .control, operations: [.control, .readState])
    func connect() {}
    func disconnect() {}
    func devices() -> [Device] { [UIProvider.device] }
    func capabilities(for deviceID: DeviceID) -> DeviceCapabilitySet {
        DeviceCapabilitySet(descriptors: [], control: self, readState: self)
    }
    func connectionEvents() -> AsyncStream<ProviderConnectionEvent> { AsyncStream { $0.finish() } }
    func state() -> DeviceState { observation(on: false, sequence: 10) }
    func execute<C: DeviceCommand>(_ command: C) -> CommandReceipt {
        CommandReceipt(commandID: command.id, deviceID: command.deviceID, outcome: .applied,
                       state: observation(on: true, sequence: 9))
    }
    private func observation(on: Bool, sequence: UInt64) -> DeviceState {
        DeviceState(deviceID: "plug", availability: .online, primaryValue: .bool(on),
                    observedAt: Date(), receivedAt: Date(), origin: .cache,
                    revision: .init(localSequence: sequence))
    }
}
