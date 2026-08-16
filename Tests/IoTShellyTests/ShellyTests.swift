import Testing
import Foundation
@testable import IoTShelly
import IoTCore

/// Mock RPC: answers per method; can throw to simulate an unreachable device.
struct MockRPC: ShellyRPC {
    let handler: @Sendable (_ method: String, _ params: [String: any Sendable]) throws -> [String: any Sendable]
    func call(host: String, password: String?, method: String, params: [String: any Sendable]) async throws -> [String: any Sendable] {
        try handler(method, params)
    }
}

@Suite struct ShellyDigestTests {
    @Test func sha256KnownVectors() {
        #expect(ShellyDigest.sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(ShellyDigest.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func parseChallenge() {
        let f = ShellyDigest.parseChallenge(#"Digest qop="auth", realm="shelly", nonce="42", algorithm=SHA-256"#)
        #expect(f["realm"] == "shelly")
        #expect(f["nonce"] == "42")
    }

    @Test func digestHeaderMatchesFormula() {
        let h = ShellyDigest.header(challenge: #"Digest qop="auth", realm="shelly", nonce="abc""#,
                                    password: "secret", cnonce: "cnce")!
        #expect(h.contains(#"username="admin""#))
        #expect(h.contains(#"uri="/rpc""#))
        let ha1 = ShellyDigest.sha256Hex("admin:shelly:secret")
        let ha2 = ShellyDigest.sha256Hex("dummy_method:dummy_uri")
        let expected = ShellyDigest.sha256Hex("\(ha1):abc:00000001:cnce:auth:\(ha2)")
        #expect(h.contains("response=\"\(expected)\""))
    }

    @Test func timespecIsDailyCron() {
        #expect(ShellyClient.timespec(hour: 6, minute: 42) == "0 42 6 * * *")
    }
}

@Suite struct ShellyProviderTests {
    private func provider(_ handler: @escaping @Sendable (String, [String: any Sendable]) throws -> [String: any Sendable],
                          cloud: ShellyCloudConfig? = nil) -> ShellyProvider {
        ShellyProvider(devices: [ShellyDeviceConfig(id: "plug1", name: "Coffee", host: "10.0.0.5", mac: "aabbcc")],
                       cloud: cloud, rpc: MockRPC(handler: handler))
    }

    @Test func controlAppliedWhenConfirmed() async throws {
        let p = provider { method, _ in
            switch method {
            case "Switch.Set": return [:]
            case "Switch.GetStatus": return ["output": true]
            default: return ["methods": ["Switch.Set", "Schedule.Create"]]
            }
        }
        let control = try #require(try await p.capabilities(for: "plug1").control)
        let r = try await control.execute(SetPowerCommand(deviceID: "plug1", isOn: true))
        #expect(r.outcome == .applied)
    }

    @Test func controlUncertainWhenUnreachableAndNoCloud() async throws {
        // Switch.Set throws (device offline), no cloud → cannot confirm → .uncertain.
        let p = provider { method, _ in
            if method == "Switch.Set" { throw IoTError.timeout }
            if method == "Shelly.ListMethods" { return ["methods": ["Switch.Set"]] }
            return [:]
        }
        let control = try #require(try await p.capabilities(for: "plug1").control)
        let r = try await control.execute(SetPowerCommand(deviceID: "plug1", isOn: true))
        #expect(r.outcome == .uncertain)
    }

    @Test func devicesExposeControlAndSchedule() async throws {
        let p = provider { _, _ in ["methods": ["Switch.Set", "Schedule.Create"]] }
        let devices = try await p.devices()
        #expect(devices.first?.kind == .outlet)
        let caps = try await p.capabilities(for: "plug1")
        #expect(caps.control != nil)
        #expect(caps.schedule != nil)
        #expect(caps.readState != nil)
    }
}

@Suite struct ShellyCloudSecurityTests {
    actor RecordingHTTP: ShellyCloudHTTP {
        private(set) var request: URLRequest?
        let data: Data
        let status: Int

        init(json: String, status: Int = 200) {
            self.data = Data(json.utf8)
            self.status = status
        }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            self.request = request
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return (data, response)
        }

        func recordedRequest() -> URLRequest? { request }
    }

    @Test func cloudHostRejectsCredentialExfiltrationShapes() {
        #expect(ShellyCloudClient.normalizedHost("https://shelly-59-eu.shelly.cloud")
                == "shelly-59-eu.shelly.cloud")
        #expect(ShellyCloudClient.normalizedHost("https://api.shelly.cloud@attacker.invalid") == nil)
        #expect(ShellyCloudClient.normalizedHost("https://shelly-59-eu.shelly.cloud/path") == nil)
        #expect(ShellyCloudClient.normalizedHost("https://shelly-59-eu.shelly.cloud?next=attacker.invalid") == nil)
        #expect(ShellyCloudClient.normalizedHost("http://shelly-59-eu.shelly.cloud") == nil)
        #expect(ShellyCloudClient.normalizedHost("https://attacker.invalid") == nil)
    }

    @Test func listRequestEncodesSecretAndParsesFixturesFailClosed() async throws {
        let http = RecordingHTTP(json: #"""
        {"isok":true,"data":{"devices":{
          "AABBCC":{"name":"Coffee","type":"SHPLG-S","online":1},
          "DDEEFF":{"name":"Bedroom","code":"SNSW","online":false},
          "112233":{"name":"Unknown state"},
          "BAD":"not-an-object",
          "":{"name":"missing id","online":true}
        }}}
        """#)

        let devices = await ShellyCloudClient.listDevices(
            server: "shelly-59-eu.shelly.cloud", authKey: "a&b+c=", http: http)

        #expect(devices.map(\.id) == ["ddeeff", "aabbcc", "112233"])
        #expect(devices.first { $0.id == "aabbcc" }?.online == true)
        #expect(devices.first { $0.id == "ddeeff" }?.type == "SNSW")
        #expect(devices.first { $0.id == "112233" }?.online == false)

        let request = try #require(await http.recordedRequest())
        #expect(request.url?.absoluteString == "https://shelly-59-eu.shelly.cloud/interface/device/list")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let requestBody = try #require(request.httpBody)
        #expect(String(data: requestBody, encoding: .utf8) == "auth_key=a%26b%2Bc%3D")
    }

    @Test func listRejectsUnsuccessfulResponses() async {
        let rejected = RecordingHTTP(json: #"{"isok":false,"data":{"devices":{}}}"#)
        #expect(await ShellyCloudClient.listDevices(
            server: "shelly-59-eu.shelly.cloud", authKey: "x", http: rejected).isEmpty)

        let error = RecordingHTTP(json: #"{"isok":true,"data":{"devices":{}}}"#, status: 401)
        #expect(await ShellyCloudClient.listDevices(
            server: "shelly-59-eu.shelly.cloud", authKey: "x", http: error).isEmpty)
    }

    @Test func setSwitchEncodesSecretInQueryAndBuildsJSONBody() async throws {
        let http = RecordingHTTP(json: "{}")
        let ok = await ShellyCloudClient.setSwitch(
            server: "https://shelly-59-eu.shelly.cloud/", authKey: "a&b+c=",
            deviceID: "aabbcc", channel: 2, on: true, http: http)
        #expect(ok)

        let request = try #require(await http.recordedRequest())
        let requestURL = try #require(request.url)
        let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
        #expect(components.host == "shelly-59-eu.shelly.cloud")
        #expect(components.path == "/v2/devices/api/set/switch")
        #expect(components.queryItems == [URLQueryItem(name: "auth_key", value: "a&b+c=")])
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["id"] as? String == "aabbcc")
        #expect(body["channel"] as? Int == 2)
        #expect(body["on"] as? Bool == true)
    }

    @Test func productionTransportRejectsEveryRedirect() {
        let transport = ShellyCloudURLSessionHTTP()
        let original = URL(string: "https://shelly-59-eu.shelly.cloud/interface/device/list")!
        let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": "https://attacker.invalid/"])!
        let redirected = URLRequest(url: URL(string: "https://attacker.invalid/")!)
        var followed: URLRequest? = redirected
        transport.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: original),
                             willPerformHTTPRedirection: response, newRequest: redirected) {
            followed = $0
        }
        #expect(followed == nil)
    }
}

// MARK: - BLE-RPC framing (pure — the GATT shell is device-gated)

@Suite struct ShellyBLEFramingTests {

    @Test func lengthPrefixIsBigEndian32() {
        #expect(ShellyBLEFraming.lengthPrefix(for: Data(count: 0x0102)) == Data([0, 0, 0x01, 0x02]))
        #expect(ShellyBLEFraming.lengthPrefix(for: Data()) == Data([0, 0, 0, 0]))
    }

    @Test func expectedLengthRoundTripsAndCaps() throws {
        let payload = Data(repeating: 7, count: 300)
        let prefix = ShellyBLEFraming.lengthPrefix(for: payload)
        #expect(try ShellyBLEFraming.expectedLength(from: prefix) == 300)
        // 2 MB declared > 1 MB cap → typed transport error, not a silent huge alloc.
        let huge = Data([0x00, 0x20, 0x00, 0x00])
        #expect(throws: IoTError.self) { try ShellyBLEFraming.expectedLength(from: huge) }
        #expect(throws: IoTError.invalidResponse) { try ShellyBLEFraming.expectedLength(from: Data([1, 2])) }
    }

    @Test func chunkingCoversPayloadExactly() {
        let payload = Data((0..<53).map { UInt8($0) })
        let chunks = ShellyBLEFraming.chunks(payload, mtu: 20)
        #expect(chunks.count == 3)
        #expect(chunks.map(\.count) == [20, 20, 13])
        #expect(chunks.reduce(Data(), +) == payload)
    }

    @Test func reassemblerCompletesAcrossChunkBoundaries() {
        let frame = Data(#"{"id":1,"result":{"output":true}}"#.utf8)
        var reassembler = ShellyBLEFraming.Reassembler(expected: frame.count)
        var result: Data?
        for chunk in ShellyBLEFraming.chunks(frame, mtu: 5) {
            result = reassembler.append(chunk)
        }
        #expect(result == frame)
    }

    @Test func requestAndResponseUseTheHTTPRPCEnvelope() throws {
        let frame = try ShellyBLEFraming.requestFrame(id: 1, method: "Switch.Set", params: ["id": 0, "on": true])
        let json = try JSONSerialization.jsonObject(with: frame) as? [String: Any]
        #expect(json?["method"] as? String == "Switch.Set")

        let ok = Data(#"{"id":1,"result":{"was_on":false}}"#.utf8)
        #expect(try ShellyBLEFraming.parseResponse(ok)["was_on"] as? Bool == false)

        let denied = Data(#"{"id":1,"error":{"code":401,"message":"Unauthorized"}}"#.utf8)
        #expect(throws: IoTError.authenticationFailed(reason: "Unauthorized")) {
            _ = try ShellyBLEFraming.parseResponse(denied)
        }
    }
}

// MARK: - Frame-embedded digest auth (BLE / RPC 401 → auth object)

@Suite struct ShellyBLEDigestAuthTests {

    static let challenge = #"{"auth_type":"digest","nonce":1638000000,"nc":1,"realm":"shellyplus1-test","algorithm":"SHA-256"}"#

    @Test func rpcAuthMatchesGoldenVector() {
        // Golden values computed independently (python hashlib) — freezing the digest scheme:
        // ha1 = SHA256("admin:shellyplus1-test:secret"), ha2 = SHA256("dummy_method:dummy_uri"),
        // response = SHA256("ha1:1638000000:1:12345:auth:ha2").
        let auth = ShellyBLEFraming.rpcAuth(challengeMessage: Self.challenge, password: "secret", cnonce: 12345)
        #expect(auth?["response"] as? String == "93f0cf19035ba26cb78296dd465de07be3ca2891868d0f3d46131cf61d901cfb")
        #expect(auth?["username"] as? String == "admin")
        #expect(auth?["realm"] as? String == "shellyplus1-test")
        #expect(auth?["nonce"] as? Int == 1_638_000_000)
        #expect(auth?["cnonce"] as? Int == 12345)
        #expect(auth?["algorithm"] as? String == "SHA-256")
    }

    @Test func ha2IsTheFixedDummyPair() {
        // The scheme hashes "dummy_method:dummy_uri" regardless of the actual RPC — spec quirk
        // worth freezing (a well-meaning "fix" here would break auth on every device).
        #expect(ShellyDigest.sha256Hex("dummy_method:dummy_uri")
                == "6370ec69915103833b5222b368555393393f098bfbfbb59f47e0590af135f062")
    }

    @Test func unparseableChallengeReturnsNil() {
        #expect(ShellyBLEFraming.rpcAuth(challengeMessage: "Unauthorized", password: "x") == nil)
        #expect(ShellyBLEFraming.rpcAuth(challengeMessage: #"{"realm":"r"}"#, password: "x") == nil)   // no nonce
    }

    @Test func authedFrameCarriesTopLevelAuthObject() throws {
        let auth = ShellyBLEFraming.rpcAuth(challengeMessage: Self.challenge, password: "secret", cnonce: 7)!
        let frame = try ShellyBLEFraming.requestFrame(id: 2, method: "Switch.Set",
                                                      params: ["id": 0, "on": true], auth: auth)
        let json = try JSONSerialization.jsonObject(with: frame) as? [String: Any]
        #expect((json?["auth"] as? [String: Any])?["username"] as? String == "admin")
        #expect(json?["method"] as? String == "Switch.Set")
    }
}
