import Foundation
import IoTCore
#if canImport(HomeKit)
import HomeKit
#endif

/// HomeKit provider. Its unique value is **`HMTimerTrigger` scheduling** — a timed action that fires
/// on the home hub (HomePod/Apple TV) with the iPhone off/suspended: the Apple-native equivalent of
/// Shelly's on-device schedule (the pre-provisioning law). Control/read go through
/// `HMCharacteristic`. Ported from Velya `HomeKitWakeTrigger`.
///
/// Device-gated: HomeKit isn't available in the Simulator and needs the HomeKit entitlement +
/// permission; every path no-ops gracefully without a home. `NSHomeKitUsageDescription` is the host
/// app's responsibility.
public actor HomeKitProvider: DeviceProvider {
    public nonisolated let id: ProviderID = "homekit"
    public nonisolated let displayName = "HomeKit"
    private let seq = SequenceGen()

    #if canImport(HomeKit)
    private var manager: HMHomeManager?
    #endif

    public init() {}

    public func connect() async throws {
        #if canImport(HomeKit)
        _ = await primaryHome()
        #endif
    }
    public func disconnect() async {}

    public func devices() async throws -> [Device] {
        #if canImport(HomeKit)
        guard let home = await primaryHome() else { return [] }
        return await MainActor.run {
            home.accessories.compactMap { acc -> Device? in
                guard powerCharacteristic(in: acc) != nil else { return nil }
                return Device(id: DeviceID(rawValue: acc.uniqueIdentifier.uuidString), providerID: id,
                              nativeID: acc.uniqueIdentifier.uuidString, name: acc.name,
                              kind: isLight(acc) ? .light : .switchDevice,
                              capabilities: [.control, .readState, .schedule].map { CapabilityDescriptor(id: $0, operations: []) })
            }
        }
        #else
        return []
        #endif
    }

    public func capabilities(for deviceID: DeviceID) async throws -> DeviceCapabilitySet {
        DeviceCapabilitySet(
            descriptors: [.readState, .control, .schedule].map { CapabilityDescriptor(id: $0, operations: []) },
            control: HomeKitControlCapability(provider: self, deviceID: deviceID, seq: seq),
            readState: HomeKitReadStateCapability(provider: self, deviceID: deviceID, seq: seq),
            schedule: HomeKitScheduleCapability(provider: self, deviceID: deviceID))
    }

    public func connectionEvents() async -> AsyncStream<ProviderConnectionEvent> {
        let id = self.id
        return AsyncStream { c in c.yield(ProviderConnectionEvent(providerID: id, state: .connected)); c.finish() }
    }

    // MARK: - Capability-facing API (unconditional; no-ops without HomeKit)

    func setPower(_ deviceID: DeviceID, on: Bool) async -> Bool {
        #if canImport(HomeKit)
        guard let (_, ch) = await accessoryAndPower(deviceID) else { return false }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            ch.writeValue(NSNumber(value: on)) { error in c.resume(returning: error == nil) }
        }
        #else
        return false
        #endif
    }

    func readPower(_ deviceID: DeviceID) async -> Bool? {
        #if canImport(HomeKit)
        guard let (_, ch) = await accessoryAndPower(deviceID) else { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool?, Never>) in
            ch.readValue { _ in c.resume(returning: (ch.value as? Bool) ?? (ch.value as? NSNumber)?.boolValue) }
        }
        #else
        return nil
        #endif
    }

    func provisionTimer(_ deviceID: DeviceID, on: Bool, fireDate: Date) async -> String? {
        #if canImport(HomeKit)
        return await provisionTimerHK(deviceID, on: on, fireDate: fireDate)
        #else
        return nil
        #endif
    }

    func clearTimer(named name: String) async {
        #if canImport(HomeKit)
        guard let home = await primaryHome() else { return }
        await removeExisting(named: name, in: home)
        #endif
    }

    // MARK: - HomeKit bridging (internal)

    #if canImport(HomeKit)
    private func primaryHome() async -> HMHome? {
        let m = await ensureManager()
        // HMHomeManager populates asynchronously; poll briefly.
        for _ in 0..<15 {
            if let home = await MainActor.run(body: { m.homes.first }) { return home }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    private func ensureManager() async -> HMHomeManager {
        if let manager { return manager }
        let m = await MainActor.run { HMHomeManager() }
        manager = m
        return m
    }

    private func accessoryAndPower(_ deviceID: DeviceID) async -> (HMAccessory, HMCharacteristic)? {
        guard let home = await primaryHome(), let uuid = UUID(uuidString: deviceID.rawValue) else { return nil }
        return await MainActor.run {
            guard let acc = home.accessories.first(where: { $0.uniqueIdentifier == uuid }),
                  let ch = powerCharacteristic(in: acc) else { return nil }
            return (acc, ch)
        }
    }

    /// Provision an `HMTimerTrigger` + `HMActionSet` that sets the accessory power at `fireDate` on the
    /// home hub — fires with the app dead. Replaces any prior LorisIoT-owned trigger/action-set.
    private func provisionTimerHK(_ deviceID: DeviceID, on: Bool, fireDate: Date) async -> String? {
        guard let home = await primaryHome(), let (_, ch) = await accessoryAndPower(deviceID) else { return nil }
        let setName = "LorisIoT \(deviceID.rawValue)"
        await removeExisting(named: setName, in: home)
        guard let set = try? await addActionSet(named: setName, in: home) else { return nil }
        let action = HMCharacteristicWriteAction(characteristic: ch, targetValue: NSNumber(value: on))
        _ = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            set.addAction(action) { c.resume(returning: $0 == nil) }
        }
        let rounded = Calendar.current.date(bySetting: .second, value: 0, of: fireDate) ?? fireDate
        let trigger = HMTimerTrigger(name: setName, fireDate: rounded, timeZone: nil, recurrence: nil, recurrenceCalendar: nil)
        let added = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            home.addTrigger(trigger) { c.resume(returning: $0 == nil) }
        }
        guard added else { return nil }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in trigger.addActionSet(set) { _ in c.resume() } }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in trigger.enable(true) { _ in c.resume() } }
        return setName
    }

    private func removeExisting(named name: String, in home: HMHome) async {
        for t in home.triggers where t.name == name {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in home.removeTrigger(t) { _ in c.resume() } }
        }
        for s in home.actionSets where s.name == name {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in home.removeActionSet(s) { _ in c.resume() } }
        }
    }

    private func addActionSet(named name: String, in home: HMHome) async throws -> HMActionSet {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<HMActionSet, Error>) in
            home.addActionSet(withName: name) { set, err in
                if let set { c.resume(returning: set) } else { c.resume(throwing: err ?? IoTError.invalidResponse) }
            }
        }
    }
    #endif
}

#if canImport(HomeKit)
@MainActor func powerCharacteristic(in accessory: HMAccessory) -> HMCharacteristic? {
    for service in accessory.services {
        for ch in service.characteristics where ch.characteristicType == HMCharacteristicTypePowerState { return ch }
    }
    return nil
}
@MainActor func isLight(_ accessory: HMAccessory) -> Bool {
    accessory.services.contains { $0.serviceType == HMServiceTypeLightbulb }
}
#endif

// MARK: - Capabilities

func homeKitState(_ on: Bool?, id: DeviceID, seq: UInt64) -> DeviceState {
    DeviceState(deviceID: id, availability: on == nil ? .offline : .online,
                primaryValue: on.map { .bool($0) }, observedAt: Date(), origin: .local,
                revision: StateRevision(localSequence: seq))
}

actor HomeKitControlCapability: ControlCapability {
    public nonisolated let descriptor = CapabilityDescriptor(id: .control, operations: [.control])
    private let provider: HomeKitProvider; private let deviceID: DeviceID; private let seq: SequenceGen
    init(provider: HomeKitProvider, deviceID: DeviceID, seq: SequenceGen) { self.provider = provider; self.deviceID = deviceID; self.seq = seq }
    func execute<C: DeviceCommand>(_ command: C) async throws -> CommandReceipt {
        guard case .setPower(let on) = command.payload else { throw IoTError.notSupported("HomeKit control supports power") }
        func receipt(_ o: CommandOutcome, _ s: DeviceState?) -> CommandReceipt {
            CommandReceipt(commandID: command.id, deviceID: deviceID, outcome: o, state: s)
        }
        guard await provider.setPower(deviceID, on: on) else { return receipt(.uncertain, nil) }
        let now = await provider.readPower(deviceID)
        if now == nil { return receipt(.accepted, nil) }
        return receipt(now == on ? .applied : .rejected, homeKitState(now, id: deviceID, seq: await seq.next()))
    }
}

actor HomeKitReadStateCapability: ReadStateCapability {
    public nonisolated let descriptor = CapabilityDescriptor(id: .readState, operations: [.readState])
    private let provider: HomeKitProvider; private let deviceID: DeviceID; private let seq: SequenceGen
    init(provider: HomeKitProvider, deviceID: DeviceID, seq: SequenceGen) { self.provider = provider; self.deviceID = deviceID; self.seq = seq }
    func state() async throws -> DeviceState {
        homeKitState(await provider.readPower(deviceID), id: deviceID, seq: await seq.next())
    }
}

/// `.schedule` via `HMTimerTrigger` — fires on the home hub with the app dead.
actor HomeKitScheduleCapability: ScheduleCapability {
    public nonisolated let descriptor = CapabilityDescriptor(id: .schedule, operations: [.schedule])
    private let provider: HomeKitProvider; private let deviceID: DeviceID
    private var handle: String?
    init(provider: HomeKitProvider, deviceID: DeviceID) { self.provider = provider; self.deviceID = deviceID }

    func schedules() async throws -> [DeviceSchedule] { [] }
    func upsert(_ schedule: DeviceSchedule) async throws -> DeviceSchedule {
        let on: Bool = { if case .setPower(let v) = schedule.command { return v }; return true }()
        #if canImport(HomeKit)
        handle = await provider.provisionTimer(deviceID, on: on, fireDate: schedule.start)
        guard handle != nil else { throw IoTError.notSupported("HomeKit trigger provisioning failed (no hub?)") }
        return schedule
        #else
        throw IoTError.notSupported("HomeKit unavailable on this platform")
        #endif
    }
    func removeSchedule(id: ScheduleID) async throws {
        #if canImport(HomeKit)
        if let handle { await provider.clearTimer(named: handle); self.handle = nil }
        #endif
    }
}
