import Foundation
import IoTCore

#if canImport(Darwin)
/// Owns the persisted account. Local revocation always wins: logout clears the Keychain item even if Meross is unreachable.
public actor MerossAccountStore {
    private let store: any CredentialStore
    private let cloud: any MerossCloudClient
    private let accountName: String
    private var cached: MerossAccount?

    public init(store: any CredentialStore, cloud: any MerossCloudClient, account: String = "meross.account") {
        self.store = store; self.cloud = cloud; accountName = account
    }

    public func current() async throws -> MerossAccount? {
        if let cached { return cached }
        guard let data = try await store.read(account: accountName) else { return nil }
        guard let account = try? JSONDecoder().decode(MerossAccount.self, from: data) else {
            try await store.remove(account: accountName); return nil
        }
        cached = account
        return account
    }

    public func signIn(email: String, password: String, region: MerossRegion) async throws -> MerossAccount {
        let account = try await cloud.signIn(email: email, password: password, region: region)
        try await store.write(try JSONEncoder().encode(account), account: accountName)
        cached = account
        return account
    }

    public func logout() async {
        var account: MerossAccount? = cached
        if account == nil, let data = try? await store.read(account: accountName) {
            account = try? JSONDecoder().decode(MerossAccount.self, from: data)
        }
        if let account { try? await cloud.logout(account: account) }
        try? await store.remove(account: accountName)
        cached = nil
    }
}
#endif
