import Foundation

public enum StateFreshness: String, Sendable, Codable, Equatable {
    case current, stale, unavailable, unknown
}

public extension DeviceState {
    /// Receipt time is local and suitable for age checks; an unsynchronised device clock is not.
    func freshness(at now: Date = Date(), maxAge: TimeInterval = 60) -> StateFreshness {
        guard availability != .offline else { return .unavailable }
        guard primaryValue != nil, availability != .unknown else { return .unknown }
        guard maxAge.isFinite, maxAge >= 0, receivedAt <= now,
              now.timeIntervalSince(receivedAt) <= maxAge, availability == .online else { return .stale }
        return .current
    }

    func withAvailability(_ availability: DeviceAvailability, origin: StateOrigin? = nil) -> DeviceState {
        DeviceState(deviceID: deviceID, availability: availability, primaryValue: primaryValue, primaryUnit: primaryUnit,
                    attributes: attributes, observedAt: observedAt, receivedAt: receivedAt,
                    origin: origin ?? self.origin, revision: revision)
    }
}
