import Foundation
import Testing
import IoTCore
@testable import IoTMeross

#if canImport(Darwin)
/// Test suite for MerossCloudSession. Marked serialized because the signIn method
/// hard-codes MerossRegion.eu (iotx-eu.meross.com), so concurrent tests would interfere
/// with each other's registered handlers for that host.
@Suite(.serialized)
struct MerossCloudSessionTests {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MerossStubProtocol.self]
        return URLSession(configuration: config)
    }
    private let signInOK = #"{"apiStatus":0,"data":{"token":"t","key":"k","userid":"42","email":"e@x","domain":"https://iotx-eu.meross.com","mqttDomain":"mqtt-eu"}}"#

    @Test func signInHashesPasswordAndReturnsAccount() async throws {
        MerossStubProtocol.register(host: "iotx-eu.meross.com") { request in
            let bodyData = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n > 0 { data.append(buffer, count: n) } else { break } }
                return data
            } ?? Data()
            let body = (try? JSONDecoder().decode(MerossJSON.self, from: bodyData))
            let params = body?["params"]?.stringValue.flatMap { Data(base64Encoded: $0) }.flatMap { try? JSONDecoder().decode(MerossJSON.self, from: $0) }
            #expect(params?["email"]?.stringValue == "e@x")
            #expect(params?["password"]?.stringValue == MerossCloudRequest.md5Hex("secret"))
            #expect(params?["password"]?.stringValue != "secret")
            #expect(params?["encryption"]?.intValue == 1)
            #expect(request.url?.host == "iotx-eu.meross.com")
            return (200, Data(self.signInOK.utf8))
        }
        let account = try await MerossCloudSession(session: session()).signIn(email: "e@x", password: "secret", region: .eu)
        #expect(account.key == "k" && account.userId == "42" && account.domain == "https://iotx-eu.meross.com")
    }
    @Test func wrongPasswordIsAuthenticationFailure() async {
        MerossStubProtocol.register(host: "iotx-eu.meross.com") { _ in (200, Data(#"{"apiStatus":1004,"info":"Wrong"}"#.utf8)) }
        await #expect(throws: IoTError.authenticationFailed(reason: "meross:1004")) {
            try await MerossCloudSession(session: session()).signIn(email: "e@x", password: "x", region: .eu)
        }
    }
    @Test func redirectIsFollowedOnce() async throws {
        nonisolated(unsafe) var hosts: [String] = []
        MerossStubProtocol.register(host: "iotx-eu.meross.com") { request in
            hosts.append(request.url?.host ?? "")
            return (200, Data(#"{"apiStatus":1030,"data":{"domain":"https://iotx-us.meross.com","mqttDomain":"mqtt-us"}}"#.utf8))
        }
        MerossStubProtocol.register(host: "iotx-us.meross.com") { request in
            hosts.append(request.url?.host ?? "")
            return (200, Data(self.signInOK.utf8))
        }
        _ = try await MerossCloudSession(session: session()).signIn(email: "e@x", password: "x", region: .eu)
        #expect(hosts == ["iotx-eu.meross.com", "iotx-us.meross.com"])

        hosts = []
        MerossStubProtocol.register(host: "iotx-eu.meross.com") { request in
            hosts.append(request.url?.host ?? "")
            return (200, Data(#"{"apiStatus":1030,"data":{"domain":"https://iotx-ap.meross.com"}}"#.utf8))
        }
        MerossStubProtocol.register(host: "iotx-ap.meross.com") { request in
            hosts.append(request.url?.host ?? "")
            return (200, Data(#"{"apiStatus":1030,"data":{"domain":"https://iotx-us.meross.com"}}"#.utf8))
        }
        await #expect(throws: IoTError.invalidResponse) {
            try await MerossCloudSession(session: session()).signIn(email: "e@x", password: "x", region: .eu)
        }
    }
    @Test func deviceListUsesTokenAndAccountDomain() async throws {
        let account = MerossAccount(userId: "42", key: "k", token: "tok", domain: "https://iotx-us.meross.com", mqttDomain: "", email: "e@x")
        MerossStubProtocol.register(host: "iotx-us.meross.com") { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic tok")
            #expect(request.url?.absoluteString == "https://iotx-us.meross.com/v1/Device/devList")
            return (200, Data(#"{"apiStatus":0,"data":[{"uuid":"u1","devName":"D","deviceType":"mod100","fmwareVersion":"1","onlineStatus":1,"channels":[{}]}]}"#.utf8))
        }
        let devices = try await MerossCloudSession(session: session()).devices(account: account)
        #expect(devices.map(\.uuid) == ["u1"])
    }
    /// The bearer token only ever goes to Meross: an account domain naming another host is refused.
    @Test func accountDomainOutsideMerossIsRefusedBeforeSendingTheToken() async throws {
        nonisolated(unsafe) var requests = 0
        MerossStubProtocol.register(host: "attacker.invalid") { _ in requests += 1; return (200, Data(#"{"apiStatus":0,"data":[]}"#.utf8)) }
        for domain in ["https://attacker.invalid", "https://meross.com.attacker.invalid", "http://iotx-eu.meross.com"] {
            let account = MerossAccount(userId: "42", key: "k", token: "tok", domain: domain, mqttDomain: "", email: "e@x")
            await #expect(throws: IoTError.notConfigured) { _ = try await MerossCloudSession(session: session()).devices(account: account) }
        }
        #expect(requests == 0)
    }
    @Test func logoutPostsToProfileLogout() async throws {
        let account = MerossAccount(userId: "42", key: "k", token: "tok", domain: "https://iotx-eu.meross.com", mqttDomain: "", email: "e@x")
        nonisolated(unsafe) var path = ""
        MerossStubProtocol.register(host: "iotx-eu.meross.com") { request in path = request.url?.path ?? ""; return (200, Data(#"{"apiStatus":0}"#.utf8)) }
        try await MerossCloudSession(session: session()).logout(account: account)
        #expect(path == "/v1/Profile/logout")
    }
}
#endif
