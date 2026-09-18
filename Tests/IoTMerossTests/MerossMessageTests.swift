import Foundation
import Testing
import IoTCore
@testable import IoTMeross

#if canImport(Darwin)
struct MerossMessageTests {
    // python3 -c 'import hashlib;print(hashlib.md5(b"0123456789abcdef0123456789abcdef"+b"fixture-key"+b"1700000000").hexdigest())'
    @Test func signatureMatchesReferenceVector() {
        let sign = MerossMessage.sign(messageId: "0123456789abcdef0123456789abcdef", key: "fixture-key", timestamp: 1_700_000_000)
        #expect(sign == "9c09de0b4e925670fbd4d6bf8db70742")
    }
    @Test func requestBuildsSignedHeaderAndUniqueIDs() {
        let a = MerossMessage.request(method: .get, namespace: "Appliance.System.All", payload: .object([:]),
                                      key: "fixture-key", now: Date(timeIntervalSince1970: 1_700_000_000))
        let b = MerossMessage.request(method: .get, namespace: "Appliance.System.All", payload: .object([:]),
                                      key: "fixture-key", now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(a.header.messageId != b.header.messageId)
        #expect(a.header.messageId.count == 32)
        #expect(a.header.timestamp == 1_700_000_000)
        #expect(a.header.method == .get)
        #expect(a.header.payloadVersion == 1)
        #expect(a.header.sign == MerossMessage.sign(messageId: a.header.messageId, key: "fixture-key", timestamp: 1_700_000_000))
    }
    @Test func replyMustCorrelateAndDecodeErrors() throws {
        let request = MerossMessage.request(method: .set, namespace: "Appliance.Control.ToggleX",
                                            payload: .object(["togglex": .object(["channel": .number(0), "onoff": .number(1)])]),
                                            key: "fixture-key", now: Date(), messageId: "aa" + String(repeating: "0", count: 30))
        let ack = MerossMessage(header: .init(from: "/appliance/uuid/publish", messageId: request.header.messageId, method: .setAck,
                                              namespace: request.header.namespace, payloadVersion: 1, sign: "", timestamp: 1, triggerSrc: nil),
                                payload: .object([:]))
        #expect(try ack.reply(to: request) == .ack(.object([:])))
        let wrong = MerossMessage(header: .init(from: "", messageId: "bb" + String(repeating: "0", count: 30), method: .setAck,
                                                namespace: request.header.namespace, payloadVersion: 1, sign: "", timestamp: 1, triggerSrc: nil),
                                  payload: .object([:]))
        #expect(throws: IoTError.invalidResponse) { try wrong.reply(to: request) }
        let error = MerossMessage(header: .init(from: "", messageId: request.header.messageId, method: .error,
                                                namespace: request.header.namespace, payloadVersion: 1, sign: "", timestamp: 1, triggerSrc: nil),
                                  payload: .object(["error": .object(["code": .number(5001), "detail": .string("sign error")])]))
        #expect(try error.reply(to: request) == .error(code: 5001, detail: "sign error"))
        #expect(MerossDeviceError(code: 5001, detail: "sign error") == .signature)
    }
    @Test func decodesDeviceEnvelope() throws {
        let text = #"{"header":{"from":"/appliance/x/publish","messageId":"abc","method":"GETACK","namespace":"Appliance.System.All","payloadVersion":1,"sign":"s","timestamp":10},"payload":{"all":{}}}"#
        let message = try JSONDecoder().decode(MerossMessage.self, from: Data(text.utf8))
        #expect(message.header.method == .getAck)
        #expect(message.payload["all"] == .object([:]))
    }
}
#endif
