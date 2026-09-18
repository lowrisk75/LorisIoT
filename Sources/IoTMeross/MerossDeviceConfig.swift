import Foundation
import IoTCore

#if canImport(Darwin)
public struct MerossDeviceConfig: Sendable, Hashable {
    public let uuid: String
    public let host: String
    public let name: String
    public let model: String
    public let firmware: String?
    public let channelCount: Int
    public var id: DeviceID { .init(rawValue: "meross:" + uuid) }
    public init(uuid: String, host: String, name: String, model: String, firmware: String?, channelCount: Int) {
        self.uuid = uuid; self.host = host; self.name = name; self.model = model
        self.firmware = firmware; self.channelCount = max(1, channelCount)
    }

    /// Targeted identity read only (`System.All`): no ability probe, no control. Matches the reply uuid
    /// against the account's device list so a foreign device on that address is refused.
    public static func discover(host: String, key: String, known: [MerossCloudDevice]) async throws -> MerossDeviceConfig {
        try await discover(host: host, key: key, known: known, client: MerossLANTransport())
    }

    static func discover(host: String, key: String, known: [MerossCloudDevice],
                         client: any MerossLANClient) async throws -> MerossDeviceConfig {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MerossLANTransport.url(host: host) != nil, !key.isEmpty, !known.isEmpty, known.count <= 256 else { throw IoTError.notConfigured }
        let request = MerossMessage.request(method: .get, namespace: MerossNamespace.systemAll, payload: .object([:]), key: key)
        let reply = try await MerossProvider.exchange(request, host: host, client: client)
        guard case .ack(let all) = reply, let identity = MerossStateMapper.identity(all: all),
              let device = known.first(where: { $0.uuid == identity.uuid }) else { throw IoTError.invalidResponse }
        return MerossDeviceConfig(uuid: device.uuid, host: host, name: device.devName, model: device.deviceType,
                                  firmware: identity.firmware, channelCount: device.channelCount)
    }
}
#endif
