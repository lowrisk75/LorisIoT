import Foundation
import Testing
@testable import IoTGovee

struct GoveeLANMessageTests {
    @Test func partialStatusDoesNotInventOffOrBlack() throws {
        let message = try GoveeLANMessage.decode(Data(#"{"msg":{"cmd":"devStatus","data":{"brightness":42}}}"#.utf8))
        guard case .status(let status) = message else { Issue.record("Expected status"); return }
        #expect(status.brightness == 42)
        #expect(status.onOff == nil)
        #expect(status.color == nil)
        #expect(status.colorTemInKelvin == nil)
    }

    @Test(arguments: [
        #"{"onOff":2}"#, #"{"onOff":true}"#, #"{"brightness":101}"#,
        #"{"brightness":-1}"#, #"{"brightness":0.5}"#, #"{"brightness":"25"}"#,
        #"{"color":{"r":256,"g":0,"b":0}}"#, #"{"colorTemInKelvin":1000}"#, #"{}"#
    ])
    func rejectsInvalidStatus(fields: String) {
        let data = Data(("{\"msg\":{\"cmd\":\"devStatus\",\"data\":" + fields + "}}").utf8)
        #expect(throws: (any Error).self) { try GoveeLANMessage.decode(data) }
    }

    @Test func discoveryRequiresCompleteIdentity() throws {
        let valid = #"{"msg":{"cmd":"scan","data":{"device":"AA:BB:CC:DD:EE:FF:00:11","sku":"H6022","ip":"192.168.3.9"}}}"#
        guard case .discovery(let value) = try GoveeLANMessage.decode(Data(valid.utf8)) else {
            Issue.record("Expected discovery"); return
        }
        #expect(value.sku == "H6022")
        for bad in [valid.replacingOccurrences(of: "192.168.3.9", with: "attacker.example"),
                    valid.replacingOccurrences(of: "AA:BB:CC:DD:EE:FF:00:11", with: ""),
                    valid.replacingOccurrences(of: "H6022", with: "../x")] {
            #expect(throws: (any Error).self) { try GoveeLANMessage.decode(Data(bad.utf8)) }
        }
    }

    @Test func rejectsNoiseAndOversizedDatagrams() {
        for data in [Data([0xff]), Data("[]".utf8), Data(repeating: 32, count: 8193),
                     Data(#"{"msg":{"cmd":"turn","data":{"value":1}}}"#.utf8)] {
            #expect(throws: (any Error).self) { try GoveeLANMessage.decode(data) }
        }
    }
}
