import Foundation
import Security
#if canImport(Matter)
@preconcurrency import Matter

/// All Matter stack data, including credentials, uses private, non-synchronizing device-only
/// Keychain items. This store never reads passwords belonging to another integration.
public final class MatterKeychainStorage: NSObject, MTRStorage, @unchecked Sendable {
    let secrets: MatterKeychainSecrets
    private let lock = NSLock()
    private var failed = false
    public init(service: String) throws {
        guard service.utf8.count <= 200, service.split(separator: ".").count >= 2,
              service.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0) }) else {
            throw MatterFabricError.invalidConfiguration
        }
        secrets = MatterKeychainSecrets(service: service)
        super.init()
    }
    var storageFailed: Bool { lock.withLock { failed } }
    private func recordFailure() { lock.withLock { failed = true } }
    public func storageData(forKey key: String) -> Data? {
        do { return try secrets.read("stack/" + key) }
        catch { recordFailure(); return nil }
    }
    public func setStorageData(_ value: Data, forKey key: String) -> Bool {
        do { try secrets.write(value, key: "stack/" + key, insertOnly: false); return true }
        catch { recordFailure(); return false }
    }
    public func removeStorageData(forKey key: String) -> Bool {
        do { return try secrets.remove("stack/" + key) }
        catch { recordFailure(); return false }
    }
}

struct MatterKeychainSecrets: MatterSecretStorage {
    let service: String
    private func query(_ key: String) throws -> [String: Any] {
        guard !key.isEmpty, key.utf8.count <= 1024 else { throw MatterFabricError.invalidConfiguration }
        return [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true]
    }
    func read(_ key: String) throws -> Data? {
        var request = try query(key)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw MatterFabricError.storageUnavailable }
        return data
    }
    func write(_ data: Data, key: String, insertOnly: Bool) throws {
        guard data.count <= 262_144 else { throw MatterFabricError.invalidConfiguration }
        let request = try query(key)
        let changes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if !insertOnly {
            let status = SecItemUpdate(request as CFDictionary, changes as CFDictionary)
            if status == errSecSuccess { return }
            guard status == errSecItemNotFound else { throw MatterFabricError.storageUnavailable }
        }
        var addition = request; changes.forEach { addition[$0.key] = $0.value }
        let status = SecItemAdd(addition as CFDictionary, nil)
        if status == errSecDuplicateItem {
            if insertOnly { throw MatterFabricError.alreadyExists }
            guard SecItemUpdate(request as CFDictionary, changes as CFDictionary) == errSecSuccess else {
                throw MatterFabricError.storageUnavailable
            }
        } else if status != errSecSuccess { throw MatterFabricError.storageUnavailable }
    }
    func remove(_ key: String) throws -> Bool {
        let status = SecItemDelete(try query(key) as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw MatterFabricError.storageUnavailable }
        return true
    }
}
#endif
