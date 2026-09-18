import Foundation
import Security

public protocol CredentialStore: Actor {
    func read(account: String) async throws -> Data?
    func write(_ data: Data, account: String) async throws
    func remove(account: String) async throws
}

public struct CredentialStoreError: Error, Sendable, Equatable {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
}

/// App-scoped secrets, never synced to iCloud. An explicit access group enables authorized extensions.
public actor KeychainCredentialStore: CredentialStore {
    private let service: String
    private let accessGroup: String?
    public init(service: String, accessGroup: String? = nil) {
        self.service = service; self.accessGroup = accessGroup
    }
    private func query(_ account: String) throws -> [String: Any] {
        guard !service.isEmpty, !account.isEmpty else { throw IoTError.notConfigured }
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecAttrSynchronizable as String: false]
        if let accessGroup { result[kSecAttrAccessGroup as String] = accessGroup }
        return result
    }
    public func read(account: String) throws -> Data? {
        var query = try query(account)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError(status: status) }
        guard let data = result as? Data, data.count <= 65536 else { throw IoTError.invalidResponse }
        return data
    }
    public func write(_ data: Data, account: String) throws {
        guard data.count <= 65536 else { throw IoTError.notConfigured }
        let query = try query(account)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard status == errSecSuccess else { throw CredentialStoreError(status: status) }
        } else if updated != errSecSuccess { throw CredentialStoreError(status: updated) }
    }
    public func remove(account: String) throws {
        let status = SecItemDelete(try query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError(status: status) }
    }
}

/// Explicit fixture store; do not use for production credentials.
public actor MemoryCredentialStore: CredentialStore {
    private var values: [String: Data] = [:]
    public init() {}
    public func read(account: String) -> Data? { values[account] }
    public func write(_ data: Data, account: String) { values[account] = data }
    public func remove(account: String) { values[account] = nil }
}
