import Foundation
import Testing
@testable import IoTHomeAssistant
import IoTCore

@Suite struct HAReliabilityRegressionTests {
    @Test func lightBeingOnDoesNotConfirmRequestedBrightness() async throws {
        let http = MockHTTP { method, _, _ in
            if method == "POST" { return (Data("[]".utf8), 200) }
            return (Data(#"{"entity_id":"light.lamp","state":"on","attributes":{"brightness":25}}"#.utf8), 200)
        }
        let provider = HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "https://ha.invalid")!), token: "test", http: http)
        let control = try #require(try await provider.capabilities(for: "light.lamp").control)
        let receipt = try await control.execute(SetLevelCommand(deviceID: "light.lamp", level: UnitInterval(0.8)))
        #expect(receipt.outcome != .applied)
    }

    @Test func readOnlyEntitiesDoNotAdvertiseControl() async throws {
        let provider = HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "https://ha.invalid")!), token: "test", http: MockHTTP { _, _, _ in (Data(), 200) })
        #expect(try await provider.capabilities(for: "sensor.temperature").control == nil)
    }

    @Test func aConfiguredHelperAloneIsNotAProvenAutomation() async throws {
        let provider = HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "https://ha.invalid")!), token: "test", http: MockHTTP { _, _, _ in (Data(), 200) }, wakeHelperEntity: "input_datetime.wake")
        #expect(try await provider.capabilities(for: "switch.plug").schedule == nil)
    }

    @Test func serverAddressRejectsEmbeddedCredentialsAndNonHTTPProtocols() {
        #expect(HAConfig.normalize("https://user:secret@host.invalid") == nil)
        #expect(HAConfig.normalize("file:///etc/passwd") == nil)
        #expect(HAConfig.normalize("https://host.invalid?token=secret") == nil)
    }

    @Test func serviceDataCannotExpandTheSelectedTarget() async throws {
        let http = HATargetBoundaryProbe()
        let rest = HARestClient(http: http)
        for key in ["entity_id", "device_id", "area_id", "floor_id", "label_id", "target"] {
            await #expect(throws: IoTError.notConfigured) {
                try await rest.callService(domain: "switch", service: "turn_on", entityID: "switch.fixture",
                                           data: [key: "another-target"])
            }
        }
        #expect(await http.calls == 0)
    }

    @Test func entityAndServiceIdentifiersCannotAlterTheRESTPath() async throws {
        let http = HATargetBoundaryProbe()
        let rest = HARestClient(http: http)
        for entity in ["switch.fixture/../../config", "switch.fixture?target=all", "switch.fixture%2fother", "switch.fixture#fragment", "switch.", ".fixture"] {
            await #expect(throws: IoTError.notConfigured) {
                try await rest.setState(entityID: entity, state: "on")
            }
            await #expect(throws: IoTError.notConfigured) {
                _ = try await rest.stateData(entityID: entity)
            }
        }
        await #expect(throws: IoTError.notConfigured) {
            try await rest.callService(domain: "switch/other", service: "turn_on", entityID: "switch.fixture")
        }
        await #expect(throws: IoTError.notConfigured) {
            try await rest.callService(domain: "switch", service: "turn_on?target=all", entityID: "switch.fixture")
        }
        #expect(await http.calls == 0)
    }
}

/// Home Assistant receives a rounded `brightness_pct` and converts it itself — brightness =
/// round(pct × 255 / 100), and 0 % turns the light off. A correctly applied level must confirm.
@Suite struct HABrightnessConfirmationTests {
    @Test(arguments: [0.1749, 0.004, 0.5, 1.0])
    func correctlyAppliedLevelConfirmsAcrossPercentRounding(level: Double) async throws {
        let lamp = SimulatedHALamp()
        let http = MockHTTP { method, _, body in lamp.handle(method: method, body: body) }
        let provider = HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "https://ha.invalid")!), token: "test", http: http)
        let control = try #require(try await provider.capabilities(for: "light.lamp").control)
        let receipt = try await control.execute(SetLevelCommand(deviceID: "light.lamp", level: UnitInterval(level)))
        #expect(receipt.outcome == .applied, "level \(level) applied by HA but reported \(receipt.outcome)")
    }
}

private final class SimulatedHALamp: @unchecked Sendable {
    private let lock = NSLock()
    private var percent = 0
    func handle(method: String, body: Data?) -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        if method == "POST" {
            let data = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            percent = data["brightness_pct"] as? Int ?? percent
            return (Data("[]".utf8), 200)
        }
        let brightness = Int((Double(percent) * 255 / 100).rounded())
        let state = percent == 0 ? #"{"entity_id":"light.lamp","state":"off","attributes":{}}"#
            : #"{"entity_id":"light.lamp","state":"on","attributes":{"brightness":\#(brightness)}}"#
        return (Data(state.utf8), 200)
    }
}

private actor HATargetBoundaryProbe: HAHTTP {
    private(set) var calls = 0
    func send(method: String, path: String, body: Data?) -> (Data, Int) {
        calls += 1
        return (Data("{}".utf8), 200)
    }
}
