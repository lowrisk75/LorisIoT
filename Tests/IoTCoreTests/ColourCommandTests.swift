import Foundation
import Testing
import IoTCore

struct ColourCommandTests {
    @Test(arguments: [nil, try! UnitInterval(0), try! UnitInterval(0.425), try! UnitInterval(1)])
    func colourPayloadAndCommandRoundTrip(level: UnitInterval?) throws {
        let color = RGBColor(red: 0, green: 128, blue: 255)
        let payload = CommandPayload.setColor(color, level: level)
        #expect(try JSONDecoder().decode(CommandPayload.self, from: JSONEncoder().encode(payload)) == payload)
        let command = SetColorCommand(deviceID: "light.fixture", color: color, level: level)
        #expect(try JSONDecoder().decode(SetColorCommand.self, from: JSONEncoder().encode(command)) == command)
        #expect(command.payload == payload)
        #expect(color.maxChannelDistance(to: .init(red: 20, green: 128, blue: 255)) == 20)
    }
}
