import Foundation
import Testing
import IoTCore
@testable import IoTHomeAssistant

struct HAColourTests {
    @Test(arguments: [0, 8, 20])
    func confirmsFixtureAndExposesRestoreColour(drift: Int) async throws {
        let http = MockHTTP { method, path, body in
            if method == "POST" {
                #expect(path == "api/services/light/turn_on")
                let data = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any]
                #expect(data?["rgb_color"] as? [Int] == [100, 50, 25])
                #expect(data?["brightness_pct"] as? Int == 43)
                return (Data("[]".utf8), 200)
            }
            return (Data("{\"entity_id\":\"light.fixture\",\"state\":\"on\",\"attributes\":{\"rgb_color\":[\(100 + drift),50,25],\"brightness\":110}}".utf8), 200)
        }
        let control = HAControlCapability(rest: HARestClient(http: http), deviceID: "light.fixture", seq: SequenceGen())
        let result = try await control.execute(SetColorCommand(deviceID: "light.fixture", color: .init(red: 100, green: 50, blue: 25), level: try UnitInterval(0.425)))
        #expect(result.outcome == (drift <= 8 ? .applied : .rejected))
        #expect(result.state?.attributes["color"]?.value == .array([.integer(Int64(100 + drift)), .integer(50), .integer(25)]))
    }

    @Test(arguments: [true, false])
    func transportFailureIsUncertain(failSend: Bool) async throws {
        let control = HAControlCapability(rest: HARestClient(http: FailingColourHTTP(failSend: failSend)), deviceID: "light.fixture", seq: SequenceGen())
        let result = try await control.execute(SetColorCommand(deviceID: "light.fixture", color: .init(red: 1, green: 2, blue: 3)))
        #expect(result.outcome == .uncertain)
    }

    @Test(arguments: ["[]", "[255,2]", "[300,2,3]", "[-1,2,3]", "[255,2,3,4]"])
    func malformedRGBDoesNotConfirmOrExposeRestoreValue(rgb: String) async throws {
        let bytes = Data("{\"entity_id\":\"light.fixture\",\"state\":\"on\",\"attributes\":{\"rgb_color\":\(rgb)}}".utf8)
        let control = HAControlCapability(rest: HARestClient(http: MockHTTP { method, _, _ in
            (method == "POST" ? Data("[]".utf8) : bytes, 200)
        }), deviceID: "light.fixture", seq: SequenceGen())
        let result = try await control.execute(SetColorCommand(deviceID: "light.fixture", color: .init(red: 255, green: 2, blue: 3)))
        #expect(result.outcome == .rejected)
        #expect(result.state?.attributes["color"] == nil)
    }

    @Test func brightnessMismatchRejectsAndOmittedLevelDoesNotConstrainBrightness() async throws {
        let control = HAControlCapability(rest: HARestClient(http: MockHTTP { method, _, _ in
            (Data((method == "POST" ? "[]" : #"{"entity_id":"light.fixture","state":"on","attributes":{"rgb_color":[1,2,3],"brightness":20}}"#).utf8), 200)
        }), deviceID: "light.fixture", seq: SequenceGen())
        let color = RGBColor(red: 1, green: 2, blue: 3)
        #expect(try await control.execute(SetColorCommand(deviceID: "light.fixture", color: color, level: try UnitInterval(0.5))).outcome == .rejected)
        #expect(try await control.execute(SetColorCommand(deviceID: "light.fixture", color: color)).outcome == .applied)
    }
}

private struct FailingColourHTTP: HAHTTP {
    let failSend: Bool
    func send(method: String, path: String, body: Data?) async throws -> (Data, Int) {
        if failSend || method != "POST" { throw IoTError.transport("fixture") }
        return (Data("[]".utf8), 200)
    }
}
