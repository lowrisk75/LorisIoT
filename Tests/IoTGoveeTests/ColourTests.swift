import Foundation
import Testing
import IoTCore
@testable import IoTGovee

struct GoveeColourWireTests {
    @Test func colourFramesWithOptionalRoundedBrightness() throws {
        let color = RGBColor(red: 100, green: 50, blue: 25)
        let single = try GoveeLANCommand(payload: .setColor(color, level: nil))
        #expect(single == .rgb(red: 100, green: 50, blue: 25))
        #expect(String(decoding: try single.encoded(), as: UTF8.self) == #"{"msg":{"cmd":"colorwc","data":{"color":{"b":25,"g":50,"r":100},"colorTemInKelvin":0}}}"#)
        let frames = try GoveeLANCommand.commands(for: .setColor(color, level: try UnitInterval(0.425)))
        #expect(frames == [single, .brightness(43)])
        #expect(String(decoding: try frames[1].encoded(), as: UTF8.self) == #"{"msg":{"cmd":"brightness","data":{"value":43}}}"#)
        #expect(try GoveeLANCommand.commands(for: .setColor(color, level: nil)) == [single])
        #expect(throws: (any Error).self) { try GoveeLANCommand(payload: .setColor(color, level: try UnitInterval(0.5))) }
    }
}

#if canImport(Darwin)
struct GoveeColourProviderTests {
    @Test(arguments: ["match", "colourMismatch", "brightnessMismatch", "failSecondSend", "failReadback"])
    func compositeDispatchAndReadback(scenario: String) async throws {
        let fake = ColourLANFixture(scenario: scenario)
        let config = GoveeDeviceConfig(device: "AA:BB:CC:DD:EE:FF:00:11", model: "H6022", host: "127.0.0.1", name: "Fixture")
        let provider = GoveeProvider(devices: [config], client: fake)
        try await provider.connect()
        let control = try #require(try await provider.capabilities(for: config.id).control)
        let receipt = try await control.execute(SetColorCommand(deviceID: config.id, color: .init(red: 100, green: 50, blue: 25), level: try UnitInterval(0.425)))
        #expect(receipt.outcome == (scenario == "match" ? .accepted : .uncertain))
        #expect(await fake.sent == [.rgb(red: 100, green: 50, blue: 25), .brightness(43)])
        #expect(await fake.reads == (scenario == "failSecondSend" ? 0 : 1))
        await provider.disconnect()
    }

    @Test func colourOnlyDoesNotSendBrightness() async throws {
        let fake = ColourLANFixture(scenario: "brightnessMismatch")
        let config = GoveeDeviceConfig(device: "AA:BB:CC:DD:EE:FF:00:11", model: "H6022", host: "127.0.0.1", name: "Fixture")
        let provider = GoveeProvider(devices: [config], client: fake)
        try await provider.connect()
        let control = try #require(try await provider.capabilities(for: config.id).control)
        let receipt = try await control.execute(SetColorCommand(deviceID: config.id, color: .init(red: 100, green: 50, blue: 25)))
        #expect(receipt.outcome == .accepted)
        #expect(await fake.sent.count == 1)
        await provider.disconnect()
    }
}

private actor ColourLANFixture: GoveeLANControlClient {
    let scenario: String
    var sent: [GoveeLANCommand] = []
    var reads = 0
    init(scenario: String) { self.scenario = scenario }
    func send(_ command: GoveeLANCommand, host: String) async throws {
        sent.append(command)
        if scenario == "failSecondSend", sent.count == 2 { throw IoTError.transport("fixture") }
    }
    func query(_ query: GoveeLANTransport.Query, host: String, timeout: TimeInterval) async throws -> GoveeLANMessage {
        switch query {
        case .discovery:
            return try GoveeLANMessage.decode(Data(#"{"msg":{"cmd":"scan","data":{"device":"AA:BB:CC:DD:EE:FF:00:11","sku":"H6022","ip":"127.0.0.1"}}}"#.utf8))
        case .status:
            reads += 1
            if scenario == "failReadback" { throw IoTError.transport("fixture") }
            let red = scenario == "colourMismatch" ? 120 : 100
            let brightness = scenario == "brightnessMismatch" ? 20 : 43
            return try GoveeLANMessage.decode(Data("{\"msg\":{\"cmd\":\"devStatus\",\"data\":{\"brightness\":\(brightness),\"color\":{\"r\":\(red),\"g\":50,\"b\":25},\"colorTemInKelvin\":0}}}".utf8))
        }
    }
}
#endif
