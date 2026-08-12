import Foundation
import Security

/// Namespaced Keychain wrapper. Secrets default to **device-only** (`ThisDeviceOnly`) and **private
/// to the app**. Pass `accessGroup` to opt a specific secret into cross-app sharing via an App Group
/// (`kSecAttrAccessGroup`) — so LorisLabs apps signed under the same team can share, e.g., one Home
/// Assistant token, while everything else stays isolated. Generalized from Éclair `KeychainStore` +
/// Lumen `KeychainService`.
public struct KeychainStore: Sendable {
    public let service: String
    /// Non-nil = this store's items are shared across apps in the given keychain access group.
    public let accessGroup: String?

    public init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery(account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func string(account: String) -> String? {
        data(account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func data(account: String) -> Data? {
        var q = baseQuery(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Set (or clear when `value` is nil) a secret. Delete-then-add so it always replaces cleanly.
    @discardableResult
    public func set(_ value: String?, account: String) -> Bool {
        set(value.map { Data($0.utf8) }, account: account)
    }

    @discardableResult
    public func set(_ value: Data?, account: String) -> Bool {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var q = baseQuery(account: account)
        q[kSecValueData as String] = value
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func remove(account: String) -> Bool {
        SecItemDelete(baseQuery(account: account) as CFDictionary) == errSecSuccess
    }
}
