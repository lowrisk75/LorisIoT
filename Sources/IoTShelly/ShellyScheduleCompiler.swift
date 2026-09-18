import Foundation
import IoTCore

/// Produces only the requested recurrence. Year support must be qualified for the actual firmware.
public enum ShellyScheduleCompiler {
    public static func timespec(for schedule: DeviceSchedule, deviceTimeZone: TimeZone,
                                supportsYear: Bool = false, now: Date = Date()) throws -> String {
        guard case .setPower = schedule.command else { throw IoTError.notSupported("Shelly schedules support power") }
        guard schedule.start.timeIntervalSince1970.isFinite else { throw IoTError.notConfigured }
        guard schedule.start.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) == 0 else {
            throw IoTError.notSupported("Shelly schedules require whole seconds; fractional seconds are never rounded")
        }
        if let requested = schedule.timeZoneIdentifier {
            guard let zone = TimeZone(identifier: requested) else { throw IoTError.notConfigured }
            if schedule.recurrence != .once && zone.identifier != deviceTimeZone.identifier {
                throw IoTError.notSupported("Recurring schedule timezone differs from the device")
            }
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = deviceTimeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: schedule.start)
        let prefix = "\(c.second ?? 0) \(c.minute ?? 0) \(c.hour ?? 0)"
        switch schedule.recurrence {
        case .daily: return "\(prefix) * * *"
        case .weekly(let days):
            guard !days.isEmpty else { throw IoTError.notConfigured }
            let names = [1: "MON", 2: "TUE", 3: "WED", 4: "THU", 5: "FRI", 6: "SAT", 7: "SUN"]
            return "\(prefix) * * \(days.map(\.rawValue).sorted().compactMap { names[$0] }.joined(separator: ","))"
        case .once:
            guard supportsYear else { throw IoTError.notSupported("One-shot scheduling is not qualified for this firmware") }
            guard schedule.start > now else { throw IoTError.notConfigured }
            guard let year = c.year, (1970...2199).contains(year) else { throw IoTError.notConfigured }
            // Firmware-specific fold semantics cannot faithfully express every absolute instant.
            let dayStart = calendar.startOfDay(for: schedule.start)
            let wall = DateComponents(hour: c.hour, minute: c.minute, second: c.second)
            let first = calendar.nextDate(after: dayStart.addingTimeInterval(-1), matching: wall,
                                          matchingPolicy: .strict, repeatedTimePolicy: .first)
            let last = calendar.nextDate(after: dayStart.addingTimeInterval(-1), matching: wall,
                                         matchingPolicy: .strict, repeatedTimePolicy: .last)
            guard first == last else { throw IoTError.notSupported("One-shot time is ambiguous during the timezone transition") }
            return "\(prefix) \(c.day!) \(c.month!) * \(c.year!)"
        }
    }
}
