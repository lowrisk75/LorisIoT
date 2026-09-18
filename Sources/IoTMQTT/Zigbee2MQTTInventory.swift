import Foundation
import IoTCore

extension Zigbee2MQTTDiscovery {
    /// Owns this transport for the finite discovery request and closes it on every exit.
    /// Supply a dedicated client ID, not a running provider's transport.
    public static func discover(using transport: any MQTTTransport, baseTopic: String = "zigbee2mqtt",
                                timeout: TimeInterval = 8) async throws -> [MQTTDeviceMap] {
        guard validTopic(baseTopic), timeout.isFinite, timeout > 0, timeout <= 60 else { throw IoTError.notConfigured }
        let topic = "\(baseTopic)/bridge/devices"
        let frames = await transport.messages()
        do {
            try await transport.connect()
            try await transport.subscribe(topic: topic)
            let maps = try await withThrowingTaskGroup(of: [MQTTDeviceMap].self) { group in
                group.addTask {
                    for await frame in frames where frame.topic == topic {
                        try Task.checkCancellation()
                        return try devices(from: frame.payload, baseTopic: baseTopic)
                    }
                    throw IoTError.notConnected
                }
                group.addTask { try await Task.sleep(for: .seconds(timeout)); throw IoTError.timeout }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            await transport.disconnect()
            return maps
        } catch {
            await transport.disconnect()
            throw error
        }
    }
}
