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
