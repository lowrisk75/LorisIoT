import Foundation
import Testing
import IoTCore
@testable import IoTMatter
#if canImport(Matter)
import Matter
import Security

struct NativeMatterTests {
    @Test func persistedRootKeySignsWithTheSamePublicIdentityAfterReopen() throws {
        let representation = try MatterRootSigner.generateRepresentation()
        let first = try MatterRootSigner(privateRepresentation: representation)
        let reopened = try MatterRootSigner(privateRepresentation: representation)
        #expect(try first.publicRepresentation() == reopened.publicRepresentation())
        let message = Data("root-signing-contract".utf8)
        let signature = reopened.signMessageECDSA_DER(message)
        #expect(SecKeyVerifySignature(first.copyPublicKey(), .ecdsaSignatureMessageX962SHA256,
            message as CFData, signature as CFData, nil))
        let certificate = try MTRCertificates.createRootCertificate(first, issuerID: 1, fabricID: 123)
        #expect(MTRCertificates.keypair(reopened, matchesCertificate: certificate))
        #expect(throws: MatterFabricError.corruptStorage) { try MatterRootSigner(privateRepresentation: Data(count: 20)) }
    }
    @Test @MainActor func emptyTrustAndInvalidKeychainNamespaceAreRejectedBeforeStartingMatter() {
        #expect(throws: MatterFabricError.invalidConfiguration) {
            try MatterFabric.create(service: "test.fabric", vendorID: 0x1234, fabricID: 123, trustedPAAs: [])
        }
        #expect(throws: MatterFabricError.invalidConfiguration) { try MatterKeychainStorage(service: "") }
        #expect(throws: MatterFabricError.invalidConfiguration) { try MatterKeychainStorage(service: "other/service") }
    }
    private func row(_ cluster: UInt32, type: String, value: Any? = nil, endpoint: UInt16 = 1) -> [String: Any] {
        var data: [String: Any] = [MTRTypeKey: type]
        data[MTRValueKey] = value
        return [MTRAttributePathKey: MTRAttributePath(endpointID: NSNumber(value: endpoint), clusterID: NSNumber(value: cluster), attributeID: 0), MTRDataKey: data]
    }
    @Test func nativeTLVNullAndSignedTemperatureAreDecodedWithoutFloatOrBoolCoercion() throws {
        let rows = try MatterNativeDecoder.result([row(0x0402, type: MTRSignedIntegerValueType, value: NSNumber(value: -100)), row(0x0405, type: MTRNullValueType)], error: nil).get()
        let values = try MatterNativeDecoder.measurements(rows, endpoint: 1, allowed: [.temperature, .humidity])
        #expect(values[.temperature] == .integer(-100))
        #expect(values[.humidity] == .null)
        for bad: Any in [NSNumber(value: true), NSNumber(value: 12.5)] {
            #expect(throws: IoTError.invalidResponse) {
                try MatterNativeDecoder.result([row(0x0402, type: MTRSignedIntegerValueType, value: bad)], error: nil).get()
            }
        }
    }
    @Test func foreignPathsDuplicatesAndPerPathFailuresCannotBecomeSensorEvidence() throws {
        let valid = row(0x0402, type: MTRSignedIntegerValueType, value: NSNumber(value: 2100))
        let foreign = row(0x0402, type: MTRSignedIntegerValueType, value: NSNumber(value: 2100), endpoint: 2)
        var failed = valid; failed[MTRErrorKey] = NSError(domain: "fixture", code: 1)
        for raw in [[valid, valid], [foreign], [failed]] {
            #expect(throws: IoTError.invalidResponse) {
                try MatterNativeDecoder.measurements(MatterNativeDecoder.result(raw, error: nil).get(), endpoint: 1, allowed: [.temperature])
            }
        }
    }
    @Test func reservedEndpointsAndNonIntegerServerListsAreRejected() throws {
        #expect(throws: IoTError.invalidResponse) {
            try MatterNativeDecoder.result([row(0x0402, type: MTRSignedIntegerValueType,
                value: NSNumber(value: 2100), endpoint: .max)], error: nil).get()
        }
        for bad in [NSNumber(value: 1026.0), NSNumber(value: true), NSNumber(value: -1)] {
            let entries: [[String: Any]] = [[MTRDataKey: [MTRTypeKey: MTRUnsignedIntegerValueType, MTRValueKey: bad]]]
            #expect(throws: IoTError.invalidResponse) {
                try MatterNativeDecoder.result([row(0x001D, type: MTRArrayValueType, value: entries)], error: nil).get()
            }
        }
    }
    @Test @MainActor func callbackLossTimesOutAndLateCompletionIsHarmless() async throws {
        let callbacks = CallbackBox<Int>()
        do {
            let _: Int = try await matterReadWithDeadline(timeout: .milliseconds(20)) { callbacks.save($0) }
            Issue.record("Missing callback must time out")
        } catch { #expect(error as? IoTError == .timeout) }
        callbacks.finish(42); callbacks.finish(43)
    }
    @Test @MainActor func cancellationDoesNotWaitForANativeCallback() async throws {
        let callbacks = CallbackBox<Int>()
        let task = Task { () throws -> Int in try await matterReadWithDeadline { callbacks.save($0) } }
        while !callbacks.installed { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch { #expect(error is CancellationError) }
        callbacks.finish(99)
    }
    @Test @MainActor func invalidInventoryIsRejectedBeforeTheControllerFactoryRuns() throws {
        #expect(throws: IoTError.notConfigured) {
            try MatterProvider.usingExclusiveController(fabricIdentity: UUID(), sensors: [], makeController: { throw IoTError.unconfirmed })
        }
        let sensor = try MatterSensorConfiguration(nodeID: 1, endpointID: 1, name: "Room")
        #expect(throws: IoTError.notConfigured) {
            try MatterProvider.usingExclusiveController(fabricIdentity: UUID(), sensors: [sensor, sensor], makeController: { throw IoTError.unconfirmed })
        }
    }
}
private final class CallbackBox<Value: Sendable>: @unchecked Sendable {
    let lock = NSLock()
    private var callback: (@Sendable (Result<Value, any Error>) -> Void)?
    var installed: Bool { lock.withLock { callback != nil } }
    func save(_ value: @escaping @Sendable (Result<Value, any Error>) -> Void) { lock.withLock { callback = value } }
    func finish(_ value: Value) { lock.withLock { callback }?(.success(value)) }
}
#endif
