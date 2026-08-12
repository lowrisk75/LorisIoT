import Foundation

// MARK: - Typed identities (provider-scoped; "same MAC ≠ same device")

public struct ProviderID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

public struct DeviceID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

public struct CommandID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

public struct CapabilityID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
    public static let control: Self = "iot.core.control"
    public static let readState: Self = "iot.core.read-state"
    public static let schedule: Self = "iot.core.schedule"
    public static let subscribe: Self = "iot.core.subscribe"
    public static let actions: Self = "iot.core.actions"
}

// MARK: - Closed, serializable value model

public enum UnitSymbol: String, Codable, Hashable, Sendable {
    case percent, celsius, fahrenheit, kelvin, watt, kilowattHour, volt, ampere, lux, second, degree, ppm, none
}

/// A JSON-like but closed & Sendable value — a provider can never inject a non-Sendable reference.
public indirect enum StateValue: Codable, Hashable, Sendable {
    case null, bool(Bool), integer(Int64), decimal(Double), string(String), data(Data), date(Date)
    case array([StateValue]), object([String: StateValue])
}

public struct StateAttribute: Codable, Hashable, Sendable {
    public let value: StateValue
    public let unit: UnitSymbol?
    public let displayName: String?
    public init(value: StateValue, unit: UnitSymbol? = nil, displayName: String? = nil) {
        self.value = value; self.unit = unit; self.displayName = displayName
    }
}

public enum DeviceAvailability: String, Codable, Hashable, Sendable { case online, degraded, offline, unknown }
public enum StateOrigin: String, Codable, Hashable, Sendable { case local, cloud, bridge, cache, optimistic }

/// Never assume device clocks are synced. `localSequence` gives deterministic process order.
public struct StateRevision: Codable, Hashable, Sendable, Comparable {
    public let localSequence: UInt64
    public let providerSequence: UInt64?
    public init(localSequence: UInt64, providerSequence: UInt64? = nil) {
        self.localSequence = localSequence; self.providerSequence = providerSequence
    }
    public static func < (l: StateRevision, r: StateRevision) -> Bool { l.localSequence < r.localSequence }
}

public struct DeviceState: Codable, Hashable, Sendable {
    public let deviceID: DeviceID
    public let availability: DeviceAvailability
    public let primaryValue: StateValue?
    public let attributes: [String: StateAttribute]
    public let observedAt: Date
    public let receivedAt: Date
    public let origin: StateOrigin
    public let revision: StateRevision
    public init(deviceID: DeviceID, availability: DeviceAvailability, primaryValue: StateValue? = nil,
                attributes: [String: StateAttribute] = [:], observedAt: Date, receivedAt: Date = Date(),
                origin: StateOrigin, revision: StateRevision) {
        self.deviceID = deviceID; self.availability = availability; self.primaryValue = primaryValue
        self.attributes = attributes; self.observedAt = observedAt; self.receivedAt = receivedAt
        self.origin = origin; self.revision = revision
    }
}

// MARK: - Device + capability descriptors (what's POSSIBLE)

public enum DeviceKind: String, Codable, Hashable, Sendable {
    case bridge, light, outlet, switchDevice, sensor, thermostat, lock, cover, fan, camera, speaker, appliance, scene, unknown
}

public enum CapabilityOperation: String, Codable, Hashable, Sendable {
    case control, readState, schedule, subscribe, invokeAction
}

public struct CapabilityDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: CapabilityID
    public let operations: Set<CapabilityOperation>
    public let metadata: [String: StateValue]
    public init(id: CapabilityID, operations: Set<CapabilityOperation>, metadata: [String: StateValue] = [:]) {
        self.id = id; self.operations = operations; self.metadata = metadata
    }
}

public struct Device: Codable, Hashable, Sendable, Identifiable {
    public let id: DeviceID
    public let providerID: ProviderID
    public let nativeID: String
    public let name: String
    public let kind: DeviceKind
    public let manufacturer: String?
    public let model: String?
    public let firmwareVersion: String?
    public let capabilities: [CapabilityDescriptor]
    public init(id: DeviceID, providerID: ProviderID, nativeID: String, name: String, kind: DeviceKind,
                manufacturer: String? = nil, model: String? = nil, firmwareVersion: String? = nil,
                capabilities: [CapabilityDescriptor]) {
        self.id = id; self.providerID = providerID; self.nativeID = nativeID; self.name = name
        self.kind = kind; self.manufacturer = manufacturer; self.model = model
        self.firmwareVersion = firmwareVersion; self.capabilities = capabilities
    }
}

// MARK: - Plumbing error (transport/auth). Domain outcomes use CommandReceipt.

public enum IoTError: Error, Sendable, Equatable {
    case notConfigured, notConnected
    case authenticationFailed(reason: String)
    case invalidResponse, unconfirmed, timeout, cancelled
    case notSupported(String), transport(String)
    /// The server 30x-redirected a cleartext upgrade to an HTTPS origin (Caddy/Traefik/nginx
    /// auto-TLS). The caller should pin the upgraded base URL and reconnect over WSS.
    case redirected(toHTTPS: String)
}
