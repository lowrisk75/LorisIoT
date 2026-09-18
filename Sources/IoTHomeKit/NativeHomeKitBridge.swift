import Foundation
import IoTCore
#if canImport(HomeKit) && !os(macOS)
@preconcurrency import HomeKit

@MainActor
final class NativeHomeKitBridge: HomeKitDeviceTransport {
    private let homeID: UUID?
    private var manager: HMHomeManager?
    nonisolated init(homeID: UUID?) { self.homeID = homeID }

    func disconnect() { manager = nil }
    private func home() async throws -> HMHome {
        if manager == nil { manager = HMHomeManager() }
        guard let manager else { throw IoTError.notConfigured }
        for _ in 0..<15 {
            try Task.checkCancellation()
            guard manager.homes.count <= 64 else { throw IoTError.invalidResponse }
            if let homeID {
                if let home = manager.homes.first(where: { $0.uniqueIdentifier == homeID }) { return home }
            } else if let home = manager.primaryHome ?? (manager.homes.count == 1 ? manager.homes.first : nil) {
                return home
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw IoTError.notConfigured
    }
    private func power(in accessory: HMAccessory) -> HMCharacteristic? {
        accessory.services.flatMap(\.characteristics).first { $0.characteristicType == HMCharacteristicTypePowerState }
    }
    private func characteristic(_ deviceID: DeviceID, in home: HMHome) throws -> HMCharacteristic {
        guard let id = UUID(uuidString: deviceID.rawValue),
              let accessory = home.accessories.first(where: { $0.uniqueIdentifier == id }),
              let characteristic = power(in: accessory) else { throw IoTError.notConfigured }
        return characteristic
    }
    func devices() async throws -> [HomeKitDeviceDescription] {
        let home = try await home()
        guard home.accessories.count <= 1000 else { throw IoTError.invalidResponse }
        #if os(iOS) || os(visionOS)
        let timers = true
        #else
        let timers = false
        #endif
        return home.accessories.compactMap { accessory in
            guard let power = power(in: accessory) else { return nil }
            return HomeKitDeviceDescription(id: .init(rawValue: accessory.uniqueIdentifier.uuidString),
                name: accessory.name,
                kind: accessory.services.contains(where: { $0.serviceType == HMServiceTypeLightbulb }) ? .light : .switchDevice,
                readable: power.properties.contains(HMCharacteristicPropertyReadable),
                writable: power.properties.contains(HMCharacteristicPropertyWritable), supportsTimers: timers)
        }
    }
    func readPower(_ deviceID: DeviceID) async throws -> Bool {
        let characteristic = try characteristic(deviceID, in: await home())
        guard characteristic.properties.contains(HMCharacteristicPropertyReadable) else {
            throw IoTError.notSupported("This HomeKit characteristic cannot be read")
        }
        try await mutate { characteristic.readValue(completionHandler: $0) }
        guard let value = characteristic.value as? Bool else { throw IoTError.invalidResponse }
        return value
    }
    func setPower(_ deviceID: DeviceID, on: Bool) async throws {
        let characteristic = try characteristic(deviceID, in: await home())
        guard characteristic.properties.contains(HMCharacteristicPropertyWritable) else {
            throw IoTError.notSupported("This HomeKit characteristic cannot be written")
        }
        try await mutate { characteristic.writeValue(NSNumber(value: on), completionHandler: $0) }
    }
    func createTimer(_ schedule: DeviceSchedule, name: String) async throws {
        #if os(iOS) || os(visionOS)
        try HomeKitScheduleValidation.validate(schedule, deviceID: schedule.deviceID, now: Date())
        let home = try await home()
        let characteristic = try characteristic(schedule.deviceID, in: home)
        guard case .setPower(let on) = schedule.command,
              !home.triggers.contains(where: { $0.name == name }),
              !home.actionSets.contains(where: { $0.name == name }) else { throw IoTError.unconfirmed }
        let set: HMActionSet = try await callback { resolve in
            home.addActionSet(withName: name) { set, error in
                if let error { resolve(.failure(error)) }
                else if let set { resolve(.success(set)) }
                else { resolve(.failure(IoTError.invalidResponse)) }
            }
        }
        let action = HMCharacteristicWriteAction(characteristic: characteristic, targetValue: NSNumber(value: on))
        try await mutate { set.addAction(action, completionHandler: $0) }
        let trigger = HMTimerTrigger(name: name, fireDate: schedule.start, recurrence: nil)
        try await mutate { home.addTrigger(trigger, completionHandler: $0) }
        try await mutate { trigger.addActionSet(set, completionHandler: $0) }
        // New triggers start disabled. Verify every construction step before enabling.
        guard trigger.actionSets.count == 1, trigger.actionSets.first?.uniqueIdentifier == set.uniqueIdentifier,
              actionMatches(set, schedule: schedule), !trigger.isEnabled else { throw IoTError.unconfirmed }
        if schedule.isEnabled { try await mutate { trigger.enable(true, completionHandler: $0) } }
        #else
        throw IoTError.notSupported("HomeKit timer provisioning is unavailable on this platform")
        #endif
    }
    private func actionMatches(_ set: HMActionSet, schedule: DeviceSchedule) -> Bool {
        guard set.actions.count == 1, let action = set.actions.first as? HMCharacteristicWriteAction<NSNumber>,
              action.characteristic.characteristicType == HMCharacteristicTypePowerState,
              action.characteristic.service?.accessory?.uniqueIdentifier.uuidString == schedule.deviceID.rawValue,
              case .setPower(let on) = schedule.command else { return false }
        return action.targetValue.boolValue == on
    }
    private func matches(_ timer: HMTimerTrigger, schedule: DeviceSchedule, name: String) -> Bool {
        timer.name == name && timer.fireDate == schedule.start && timer.recurrence == nil
            && timer.isEnabled == schedule.isEnabled && timer.actionSets.count == 1
            && timer.actionSets.first.map { $0.name == name && actionMatches($0, schedule: schedule) } == true
    }
    func timerMatches(_ schedule: DeviceSchedule, name: String) async throws -> Bool {
        let home = try await home()
        let triggers = home.triggers.filter { $0.name == name }
        let sets = home.actionSets.filter { $0.name == name }
        guard triggers.count == 1, sets.count == 1, let trigger = triggers.first as? HMTimerTrigger,
              trigger.actionSets.first?.uniqueIdentifier == sets.first?.uniqueIdentifier else { return false }
        return matches(trigger, schedule: schedule, name: name)
    }
    func removeTimer(_ schedule: DeviceSchedule, name: String) async throws {
        #if os(iOS) || os(visionOS)
        let home = try await home()
        let triggers = home.triggers.filter { $0.name == name }
        let sets = home.actionSets.filter { $0.name == name }
        guard triggers.count <= 1, sets.count <= 1 else { throw IoTError.unconfirmed }
        if let trigger = triggers.first {
            guard let timer = trigger as? HMTimerTrigger, matches(timer, schedule: schedule, name: name) else {
                throw IoTError.unconfirmed
            }
            try await mutate { home.removeTrigger(trigger, completionHandler: $0) }
        }
        if let set = sets.first {
            guard actionMatches(set, schedule: schedule),
                  !home.triggers.contains(where: { $0.actionSets.contains(where: { $0.uniqueIdentifier == set.uniqueIdentifier }) }) else {
                throw IoTError.unconfirmed
            }
            try await mutate { home.removeActionSet(set, completionHandler: $0) }
        }
        guard !home.triggers.contains(where: { $0.name == name }),
              !home.actionSets.contains(where: { $0.name == name }) else { throw IoTError.unconfirmed }
        #else
        throw IoTError.notSupported("HomeKit timer removal is unavailable on this platform")
        #endif
    }

    private func mutate(_ start: (@escaping @Sendable ((any Error)?) -> Void) -> Void) async throws {
        let _: Void = try await callback { resolve in
            start { error in
                if let error { resolve(.failure(error)) } else { resolve(.success(())) }
            }
        }
    }
    private func callback<Value: Sendable>(
        _ start: (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        let gate = HomeKitCallback<Value>()
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(20)); gate.finish(.failure(IoTError.timeout)) }
            catch {}
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if gate.install(continuation) { start { gate.finish($0) } }
            }
        } onCancel: { gate.finish(.failure(CancellationError())) }
    }
}

/// Each callback owns its own completion gate. A late callback cannot complete a subsequent operation.
private final class HomeKitCallback<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?
    func install(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock(); continuation.resume(with: result); return false
        }
        self.continuation = continuation; lock.unlock(); return true
    }
    func finish(_ result: Result<Value, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation; self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
#else
struct NativeHomeKitBridge: HomeKitDeviceTransport {
    init(homeID: UUID?) {}
    func devices() async throws -> [HomeKitDeviceDescription] { throw IoTError.notSupported("HomeKit is unavailable") }
    func disconnect() async {}
    func readPower(_ deviceID: DeviceID) async throws -> Bool { throw IoTError.notSupported("HomeKit is unavailable") }
    func setPower(_ deviceID: DeviceID, on: Bool) async throws { throw IoTError.notSupported("HomeKit is unavailable") }
    func createTimer(_ schedule: DeviceSchedule, name: String) async throws { throw IoTError.notSupported("HomeKit is unavailable") }
    func timerMatches(_ schedule: DeviceSchedule, name: String) async throws -> Bool { throw IoTError.notSupported("HomeKit is unavailable") }
    func removeTimer(_ schedule: DeviceSchedule, name: String) async throws { throw IoTError.notSupported("HomeKit is unavailable") }
}
#endif
