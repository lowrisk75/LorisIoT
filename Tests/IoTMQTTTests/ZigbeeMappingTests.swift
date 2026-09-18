import Foundation
import Testing
@testable import IoTMQTT
import IoTCore

@Suite struct ZigbeeMappingTests {
    private let inventory = Data(#"""
    [{"ieee_address":"sensor-1","friendly_name":"room/temperature","supported":true,
      "definition":{"exposes":[
        {"type":"numeric","property":"temperature","access":1,"unit":"°C"},
        {"type":"numeric","property":"humidity","access":1,"unit":"%"},
        {"type":"numeric","property":"battery","access":1,"unit":"%"}]}}]
    """#.utf8)

    /// A retained inventory entry must not be able to aim state or command topics at the bridge or another device.
    @Test func friendlyNamesThatAliasReservedTopicsAreIgnored() throws {
        for name in ["bridge/request/permit_join", "lamp/set", "lamp/get", "room//lamp", "/lamp", "lamp/", "room/set/lamp",
                     "lamp/availability"] {
            let row = #"[{"ieee_address":"x","friendly_name":"\#(name)","supported":true,"definition":{"exposes":[{"type":"numeric","property":"temperature","access":1}]}}]"#
            #expect(try Zigbee2MQTTDiscovery.devices(from: Data(row.utf8)).isEmpty, "\(name) should be ignored")
        }
    }

    /// Two devices sharing a friendly name would share state and command topics: the inventory is refused.
    @Test func duplicateFriendlyNamesAreRefused() {
        let rows = #"[{"ieee_address":"a","friendly_name":"lamp","supported":true,"definition":{"exposes":[{"type":"numeric","property":"temperature","access":1}]}},{"ieee_address":"b","friendly_name":"lamp","supported":true,"definition":{"exposes":[{"type":"numeric","property":"temperature","access":1}]}}]"#
        #expect(throws: IoTError.invalidResponse) { _ = try Zigbee2MQTTDiscovery.devices(from: Data(rows.utf8)) }
    }

    @Test func discoversReadOnlySensorWithUnitsAndTimestamp() throws {
        let map = try #require(try Zigbee2MQTTDiscovery.devices(from: inventory).first)
        #expect(!map.supportsControl)
        #expect(map.stateTopic == "zigbee2mqtt/room/temperature")
        let value = try #require(map.decodeState(Data(#"{"temperature":23.58,"humidity":56,"last_seen":"2026-05-30T15:45:26.946Z"}"#.utf8)))
        #expect(value.value == .decimal(23.58))
        #expect(value.attributes["temperature"]?.unit == .celsius)
        #expect(value.attributes["humidity"]?.unit == .percent)
        #expect(value.observedAt != nil)
        #expect(value.observedAt! < Date(timeIntervalSince1970: 1_788_800_000))
    }

    @Test func rejectsBooleanTemperatureAndAbsentMeasurement() throws {
        let map = try #require(try Zigbee2MQTTDiscovery.devices(from: inventory).first)
        #expect(map.decodeState(Data(#"{"temperature":true}"#.utf8)) == nil)
        #expect(map.decodeState(Data(#"{"humidity":54}"#.utf8)) == nil)
        #expect(map.decodeState(Data(#"{"temperature":"24.1"}"#.utf8)) == nil)
    }

    @Test func untrustedDiscoveryCannotIntroduceWildcardSubscriptions() {
        #expect(throws: (any Error).self) { try Zigbee2MQTTDiscovery.devices(from: inventory, baseTopic: "#") }
        #expect(!Zigbee2MQTTDiscovery.validTopic("room/+"))
    }
}
