import Foundation
import Security
#if canImport(Matter)
@preconcurrency import Matter

/// Immutable Security keys, serialized at creation only into the private Keychain record.
/// The legacy borrowed publicKey method is needed by the package's older deployment targets.
final class MatterRootSigner: NSObject, MTRKeypair, @unchecked Sendable {
    private let key: SecKey
    private let publicPart: SecKey
    private let lock = NSLock()
    init(privateRepresentation: Data) throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits as String: 256]
        guard privateRepresentation.count == 97,
              let key = SecKeyCreateWithData(privateRepresentation as CFData, attributes as CFDictionary, nil),
              let publicPart = SecKeyCopyPublicKey(key) else { throw MatterFabricError.corruptStorage }
        self.key = key; self.publicPart = publicPart
        super.init()
    }
    static func generateRepresentation() throws -> Data {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
              let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            throw MatterFabricError.storageUnavailable
        }
        return data
    }
    func publicKey() -> Unmanaged<SecKey> { .passUnretained(publicPart) }
    func copyPublicKey() -> SecKey { publicPart }
    func signMessageECDSA_DER(_ message: Data) -> Data {
        lock.withLock {
            SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, message as CFData, nil) as Data? ?? Data()
        }
    }
    func publicRepresentation() throws -> Data {
        guard let data = SecKeyCopyExternalRepresentation(publicPart, nil) as Data? else {
            throw MatterFabricError.storageUnavailable
        }
        return data
    }
}
#endif
