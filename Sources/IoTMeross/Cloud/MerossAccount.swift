import Foundation

#if canImport(Darwin)
/// What survives login. Never the password. Stored by MerossAccountStore in the Keychain.
public struct MerossAccount: Codable, Hashable, Sendable {
    public let userId: String
    public let key: String
    public let token: String
    public let domain: String
    public let mqttDomain: String
    public let email: String
    public init(userId: String, key: String, token: String, domain: String, mqttDomain: String, email: String) {
        self.userId = userId; self.key = key; self.token = token
        self.domain = domain; self.mqttDomain = mqttDomain; self.email = email
    }
}

public enum MerossRegion: String, CaseIterable, Sendable, Identifiable {
    case eu = "https://iotx-eu.meross.com"
    case us = "https://iotx-us.meross.com"
    case ap = "https://iotx-ap.meross.com"
    public var id: Self { self }
    public var displayName: String { switch self { case .eu: "Europe"; case .us: "Americas"; case .ap: "Asia-Pacific" } }
}

public struct MerossCloudDevice: Codable, Hashable, Sendable, Identifiable {
    public let uuid: String
    public let devName: String
    public let deviceType: String
    public let fmwareVersion: String
    public let onlineStatus: Int
    public let channelCount: Int
    public var id: String { uuid }
    public var isOnline: Bool { onlineStatus == 1 }
}
#endif
