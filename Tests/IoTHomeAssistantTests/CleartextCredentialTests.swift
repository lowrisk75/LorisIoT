import Foundation
import Testing
import IoTCore
@testable import IoTHomeAssistant

/// A bearer token must never cross a public network in cleartext. Private LAN and tailnet hosts keep
/// working over plain HTTP, which is the common real-world Home Assistant deployment.
@Suite struct HACleartextCredentialTests {
    @Test func normalizeRefusesCleartextToAPublicHost() {
        #expect(HAConfig.normalize("http://example.com:8123") == nil)
        #expect(HAConfig.normalize("http://192.168.3.230:8123") != nil)
        #expect(HAConfig.normalize("http://homeassistant.local:8123") != nil)
        #expect(HAConfig.normalize("https://example.com") != nil)
        #expect(HAConfig.normalize("example.com") != nil) // defaults to https
    }

    @Test func tokenIsNeverReadForACleartextPublicOrigin() async {
        let reads = TokenReads()
        let http = HAURLSessionHTTP(baseURL: URL(string: "http://example.com:8123")!,
                                    tokenProvider: { await reads.increment(); return "secret" })
        await #expect(throws: (any Error).self) { _ = try await http.send(method: "GET", path: "api/", body: nil) }
        #expect(await reads.count == 0)
    }
}

private actor TokenReads {
    private(set) var count = 0
    func increment() { count += 1 }

    /// A refusal decided before any byte leaves proves nothing was sent: it must not read as "may have happened".
    @Test func commandsRefusedBeforeSendingAreErrorsNotUncertain() async throws {
        let provider = HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "http://203.0.113.5:8123")!), token: "fixture")
        let control = try #require(try await provider.capabilities(for: "light.lamp").control)
        await #expect(throws: IoTError.self) { _ = try await control.execute(SetPowerCommand(deviceID: "light.lamp", isOn: true)) }
        await #expect(throws: IoTError.self) {
            _ = try await control.execute(SetLevelCommand(deviceID: "light.lamp", level: UnitInterval(0.5)))
        }
    }

    @Test func rejectedCredentialsFailBrightnessLikePower() async throws {
        let http = MockHTTP { _, _, _ in (Data("{}".utf8), 401) }
        let provider = HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "https://ha.invalid")!), token: "fixture", http: http)
        let control = try #require(try await provider.capabilities(for: "light.lamp").control)
        await #expect(throws: IoTError.authenticationFailed(reason: "HTTP 401")) {
            _ = try await control.execute(SetLevelCommand(deviceID: "light.lamp", level: UnitInterval(0.5)))
        }
    }
}
