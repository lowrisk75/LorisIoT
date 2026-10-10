import Testing
import Foundation
@testable import IoTHomeAssistant
import IoTCore

@Suite struct HAAreaTests {
    private func provider(_ handler: @escaping @Sendable (String, String, Data?) -> (Data, Int)) -> HomeAssistantProvider {
        HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "http://ha.local:8123")!),
                              token: "TESTTOKEN", http: MockHTTP(handler: handler))
    }

    @Test func roomsComeFromTheTemplateEndpoint() async throws {
        let provider = provider { method, path, body in
            #expect(method == "POST" && path == "api/template")
            let sent = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            #expect(sent.contains("'light.sofa'") && sent.contains("area_name"))
            return (Data(#"{"light.sofa":"Salon","light.stranger":"Cave"}"#.utf8), 200)
        }
        let rooms = try await provider.rooms(for: ["light.sofa", "light.hall"])
        // Only what was asked comes back; a device without a room is absent.
        #expect(rooms == ["light.sofa": "Salon"])
    }

    @Test func aMalformedIdentifierIsNeverPutInTheTemplate() async throws {
        let provider = provider { _, _, body in
            let sent = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            #expect(!sent.contains("states("))
            return (Data("{}".utf8), 200)
        }
        let rooms = try await provider.rooms(for: ["light.a'] %}{{ states('x') }}", "light.ok"])
        #expect(rooms.isEmpty)
    }

    @Test func aRefusalIsAnAuthenticationFailure() async {
        let provider = provider { _, _, _ in (Data(), 401) }
        await #expect(throws: IoTError.self) { _ = try await provider.rooms(for: ["light.sofa"]) }
    }
}
