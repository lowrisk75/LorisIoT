import Foundation
import Testing
import IoTCore
@testable import IoTShelly

@Suite struct ShellyInventoryTests {
    @Test func sensorDoesNotInventARelay() async throws {
        let client = ShellyClient(host: "fixture", rpc: MockRPC { method, _ in
            if method == "Shelly.GetDeviceInfo" { return ["id": "sensor", "model": "sensor", "gen": 3, "mac": "aabbccddeeff"] }
            if method == "Shelly.GetStatus" { return ["temperature:0": ["tC": 20.0]] }
            return ["components": [[String: String]]()]
        })
        #expect(try await client.probe().switchCount == 0)
    }
    @Test func invalidIdentityAndFailedInventoryAreSurfaced() async {
        for mode in 0..<2 {
            let client = ShellyClient(host: "fixture", rpc: MockRPC { method, _ in
                if method == "Shelly.GetDeviceInfo" {
                    return mode == 0 ? [:] : ["id": "plug", "model": "plug", "gen": 2, "mac": "aabbccddeeff"]
                }
                throw IoTError.timeout
            })
            await #expect(throws: (any Error).self) { try await client.probe() }
        }
    }
    @Test func plugReadPreservesMeasuredPowerVoltageAndTemperature() async throws {
        let provider = ShellyProvider(devices: [.init(id: "plug", name: "Plug", host: "fixture")], rpc: MockRPC { method, _ in
            if method == "Switch.GetStatus" {
                return ["id": 0, "output": true, "apower": 23.6, "voltage": 229.4, "current": 0.17,
                        "temperature": ["tC": 32.1], "aenergy": ["total": 2500.0]]
            }
            return ["methods": ["Switch.GetStatus", "Switch.Set"]]
        })
        let read = try #require(try await provider.capabilities(for: "plug").readState)
        let state = try await read.state()
        #expect(state.attributes["power"]?.value == .decimal(23.6))
        #expect(state.attributes["voltage"]?.unit == .volt)
        #expect(state.attributes["device_temperature"]?.value == .decimal(32.1))
        #expect(state.attributes["energy"]?.value == .decimal(2.5))
    }
}

@Suite struct ShellyReadOnlyHardwareTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LORISIOT_READONLY_SHELLY_HOST"] != nil))
    func readsIdentityStatusAndMethodsWithoutAnyCommand() async throws {
        let host = try #require(ProcessInfo.processInfo.environment["LORISIOT_READONLY_SHELLY_HOST"])
        let client = ShellyClient(host: host, rpc: ShellyURLSessionRPC())
        let info = try await client.probe()
        #expect(info.generation >= 2)
        let status = try await client.call(method: "Switch.GetStatus", params: ["id": 0])
        #expect(status["output"] is Bool)
        #expect((await client.listMethods()).contains("Switch.GetStatus"))
        try await ShellyScheduleQualification.verifyClock(client: client)
    }
}
