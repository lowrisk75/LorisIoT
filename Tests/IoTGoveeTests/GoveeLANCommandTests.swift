import Foundation
import Testing
import IoTCore
@testable import IoTGovee

struct GoveeLANCommandTests {
    @Test func absolutePowerAndBrightnessWireValues() throws {
        #expect(String(decoding: try GoveeLANCommand.power(false).encoded(), as: UTF8.self)
                == #"{"msg":{"cmd":"turn","data":{"value":0}}}"#)
        let command = try GoveeLANCommand(payload: .setLevel(try UnitInterval(0.425)))
        #expect(command == .brightness(43))
        #expect(String(decoding: try command.encoded(), as: UTF8.self)
                == #"{"msg":{"cmd":"brightness","data":{"value":43}}}"#)
    }

    @Test(arguments: [
        GoveeLANCommand.brightness(-1), .brightness(101), .rgb(red: 256, green: 0, blue: 0),
        .rgb(red: 0, green: -1, blue: 0), .temperature(kelvin: 0), .temperature(kelvin: 9001)
    ])
    func rejectsInsteadOfSilentlyClamping(command: GoveeLANCommand) {
        #expect(throws: IoTError.invalidResponse) { try command.encoded() }
    }

    @Test func rejectsArbitraryActionsAndColorFields() {
        #expect(throws: (any Error).self) {
            try GoveeLANCommand(payload: .invokeAction(name: "ptReal", arguments: [:]))
        }
        #expect(throws: (any Error).self) {
            try GoveeLANCommand(payload: .setAttribute(name: "color", value: .object([
                "r": .integer(1), "g": .integer(2), "b": .integer(3), "extra": .integer(4)
            ])))
        }
    }

    @Test func whiteModeCannotConfirmRGBEvenWithMatchingChannels() throws {
        let bytes = Data(#"{"msg":{"cmd":"devStatus","data":{"color":{"r":0,"g":0,"b":0},"colorTemInKelvin":4000}}}"#.utf8)
        guard case .status(let status) = try GoveeLANMessage.decode(bytes) else { return }
        #expect(!GoveeLANCommand.rgb(red: 0, green: 0, blue: 0).matches(status))
        #expect(GoveeLANCommand.temperature(kelvin: 4000).matches(status))
        #expect(!GoveeLANCommand.power(false).matches(status))
    }
}
