import Foundation
import Testing
import IoTCore
@testable import IoTMeross

#if canImport(Darwin)
actor FakeCloud: MerossCloudClient {
    var signIns = 0, logouts = 0
    var failLogout = false
    let account = MerossAccount(userId: "42", key: "fixture-key", token: "tok", domain: "https://iotx-eu.meross.com", mqttDomain: "", email: "e@x")
    func signIn(email: String, password: String, region: MerossRegion) async throws -> MerossAccount { signIns += 1; return account }
    func devices(account: MerossAccount) async throws -> [MerossCloudDevice] { [] }
    func logout(account: MerossAccount) async throws { logouts += 1; if failLogout { throw IoTError.transport("down") } }
    func setFailLogout(_ value: Bool) { failLogout = value }
}

struct MerossAccountStoreTests {
    @Test func signInPersistsAccountWithoutPassword() async throws {
        let keychain = MemoryCredentialStore()
        let store = MerossAccountStore(store: keychain, cloud: FakeCloud())
        #expect(try await store.current() == nil)
        let account = try await store.signIn(email: "e@x", password: "secret", region: .eu)
        #expect(account.key == "fixture-key")
        let raw = try #require(await keychain.read(account: "meross.account"))
        #expect(!String(decoding: raw, as: UTF8.self).contains("secret"))
        #expect(try await store.current() == account)
    }
    @Test func logoutRemovesLocallyEvenWhenCloudFails() async throws {
        let keychain = MemoryCredentialStore()
        let cloud = FakeCloud()
        await cloud.setFailLogout(true)
        let store = MerossAccountStore(store: keychain, cloud: cloud)
        _ = try await store.signIn(email: "e@x", password: "secret", region: .eu)
        await store.logout()
        #expect(await cloud.logouts == 1)
        #expect(try await store.current() == nil)
        #expect(await keychain.read(account: "meross.account") == nil)
    }
}
#endif
