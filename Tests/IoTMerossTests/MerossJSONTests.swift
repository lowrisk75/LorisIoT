import Foundation
import Testing
import IoTCore
@testable import IoTMeross

#if canImport(Darwin)
struct MerossJSONTests {
    @Test func roundTripsPlainJSON() throws {
        let text = #"{"a":1,"b":[true,null,"x"],"c":{"d":2.5}}"#
        let value = try JSONDecoder().decode(MerossJSON.self, from: Data(text.utf8))
        #expect(value["a"]?.intValue == 1)
        #expect(value["b"]?[0]?.boolValue == true)
        #expect(value["b"]?[1] == .null)
        #expect(value["b"]?[2]?.stringValue == "x")
        #expect(value["c"]?["d"]?.doubleValue == 2.5)
        let encoded = try JSONEncoder().encode(value)
        let again = try JSONDecoder().decode(MerossJSON.self, from: encoded)
        #expect(again == value)
    }
    @Test func convertsToStateValue() {
        let value: MerossJSON = .object(["n": .number(3), "f": .number(1.5), "s": .string("s"), "l": .array([.bool(false)])])
        #expect(value.stateValue() == .object(["n": .integer(3), "f": .decimal(1.5), "s": .string("s"), "l": .array([.bool(false)])]))
    }
    @Test func missingKeysAndWrongTypesAreNil() {
        let value: MerossJSON = .object(["a": .string("1")])
        #expect(value["zz"] == nil)
        #expect(value["a"]?.intValue == nil)
        #expect(value[0] == nil)
    }
}
#endif
