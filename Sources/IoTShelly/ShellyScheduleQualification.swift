import Foundation
import IoTCore

/// Read-only qualification. Never probes a firmware by creating an active or disabled schedule.
public enum ShellyScheduleQualification {
    public static func verifyClock(client: ShellyClient, now: @Sendable () -> Date = { Date() }) async throws {
        let started = now()
        let status = try await client.call(method: "Sys.GetStatus")
        let finished = now()
        guard let timestamp = status["unixtime"] as? Double, timestamp.isFinite,
              finished >= started, finished.timeIntervalSince(started) <= 5,
              timestamp >= started.timeIntervalSince1970 - 5,
              timestamp <= finished.timeIntervalSince1970 + 5 else {
            throw IoTError.notSupported("The device clock is not synchronized closely enough for scheduling")
        }
    }

    public static func oneShotTimespec(_ schedule: DeviceSchedule, client: ShellyClient,
                                      deviceTimeZone: TimeZone, now: Date = Date()) async throws -> String {
        guard schedule.recurrence == .once else { throw IoTError.notConfigured }
        let methods = await client.listMethods()
        guard methods.contains("Schedule.Eval") else {
            throw IoTError.notSupported("This firmware cannot qualify exact one-shot scheduling without a device write")
        }
        let timespec = try ShellyScheduleCompiler.timespec(for: schedule, deviceTimeZone: deviceTimeZone,
            supportsYear: true, now: now)
        let before = try await client.call(method: "Schedule.Eval", params: ["timespec": timespec,
            "now": now.timeIntervalSince1970] as [String: any Sendable])
        let after = try await client.call(method: "Schedule.Eval", params: ["timespec": timespec,
            "now": schedule.start.timeIntervalSince1970 + 1] as [String: any Sendable])
        guard before["next"] as? Double == schedule.start.timeIntervalSince1970,
              after["prev"] as? Double == schedule.start.timeIntervalSince1970,
              after["next"] == nil || after["next"] is NSNull else { throw IoTError.unconfirmed }
        return timespec
    }
}
