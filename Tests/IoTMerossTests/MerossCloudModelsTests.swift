import Foundation
import Testing
import IoTCore
@testable import IoTMeross

#if canImport(Darwin)
struct MerossCloudModelsTests {
    // python3 -c 'import hashlib;print(hashlib.md5(b"23x17ahWarFH6w29"+b"1700000000000"+b"abcdefghijklmnop"+b"eyJhIjoxfQ==").hexdigest())'
    @Test func cloudSignatureMatchesReferenceVector() {
        let sign = MerossCloudRequest.sign(secret: MerossCloudRequest.secret, timestampMs: 1_700_000_000_000,
                                           nonce: "abcdefghijklmnop", encodedParams: "eyJhIjoxfQ==")
        #expect(sign == "4429d9d7299ab278f7a78ea250ccd948")
    }
    @Test func requestCarriesBase64ParamsAndHeaders() throws {
        let request = try MerossCloudRequest.build(baseURL: URL(string: MerossRegion.eu.rawValue)!, path: "/v1/Auth/signIn",
                                                   params: ["a": .number(1)], token: nil, nonce: "abcdefghijklmnop", timestampMs: 1_700_000_000_000)
        #expect(request.url?.absoluteString == "https://iotx-eu.meross.com/v1/Auth/signIn")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic ")
        #expect(request.value(forHTTPHeaderField: "vender") == "meross")
        let body = try #require(request.httpBody)
        let json = try JSONDecoder().decode(MerossJSON.self, from: body)
        #expect(json["params"]?.stringValue == "eyJhIjoxfQ==")
        #expect(json["nonce"]?.stringValue == "abcdefghijklmnop")
        #expect(json["timestamp"]?.intValue == 1_700_000_000_000)
        #expect(json["sign"]?.stringValue?.count == 32)
        let authed = try MerossCloudRequest.build(baseURL: URL(string: MerossRegion.eu.rawValue)!, path: "/v1/Device/devList",
                                                  params: [:], token: "tok", nonce: "abcdefghijklmnop", timestampMs: 1)
        #expect(authed.value(forHTTPHeaderField: "Authorization") == "Basic tok")
    }
    @Test func decodesSignInAndDeviceList() throws {
        let signIn = #"{"apiStatus":0,"info":"Success","data":{"token":"t","key":"k","userid":"42","email":"e@x","domain":"https://iotx-eu.meross.com","mqttDomain":"mqtt-eu.meross.com"}}"#
        let envelope = try JSONDecoder().decode(MerossCloudEnvelope.self, from: Data(signIn.utf8))
        #expect(envelope.apiStatus == MerossCloudEnvelope.ok)
        let response = try #require(MerossSignInResponse(data: envelope.data))
        #expect(response.key == "k" && response.userid == "42" && response.mqttDomain == "mqtt-eu.meross.com")
        let list = #"{"apiStatus":0,"data":[{"uuid":"u1","devName":"Diffuser","deviceType":"mod100","fmwareVersion":"2.1.5","onlineStatus":1,"channels":[{}]},{"uuid":"u2","devName":"Strip","deviceType":"mss425f","fmwareVersion":"6.1.8","onlineStatus":2,"channels":[{},{"devName":"A"},{"devName":"B"},{"devName":"C"},{"devName":"D"}]}]}"#
        let devices = MerossCloudDevice.list(from: try JSONDecoder().decode(MerossCloudEnvelope.self, from: Data(list.utf8)).data)
        #expect(devices.count == 2)
        #expect(devices[0].deviceType == "mod100" && devices[0].channelCount == 1 && devices[0].isOnline)
        #expect(devices[1].channelCount == 5 && !devices[1].isOnline)
    }
    @Test func redirectEnvelopeExposesDomains() throws {
        let text = #"{"apiStatus":1030,"info":"redirect","data":{"domain":"https://iotx-us.meross.com","mqttDomain":"mqtt-us.meross.com"}}"#
        let envelope = try JSONDecoder().decode(MerossCloudEnvelope.self, from: Data(text.utf8))
        #expect(envelope.apiStatus == MerossCloudEnvelope.redirectRegion)
        #expect(envelope.data?["domain"]?.stringValue == "https://iotx-us.meross.com")
    }
}
#endif
