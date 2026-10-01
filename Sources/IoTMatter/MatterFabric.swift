import Foundation
import Security
import IoTCore
#if canImport(Matter)
@preconcurrency import Matter

/// Application-scoped fabric and factory owner. Use one service in one app process, retain
/// this object while its provider is connected, and explicitly close after disconnecting it.
/// There is no implicit reset, attestation bypass, or adoption of another owner's factory.
@MainActor
public final class MatterFabric {
    private static var owner: UUID?
    public let identity: UUID
    private let storage: MatterKeychainStorage
    private let repository: MatterFabricRepository
    private let factory: MTRDeviceControllerFactory
    private let signer: MatterRootSigner
    private var transferredController: MTRDeviceController?
    private var commissioning = false
    private var closed = false

    public static func create(service: String, vendorID: UInt16, fabricID: UInt64,
                              trustedPAAs: [Data]) throws -> MatterFabric {
        try validateTrust(trustedPAAs)
        guard vendorID != 0, vendorID != .max, fabricID != 0 else { throw MatterFabricError.invalidConfiguration }
        guard owner == nil, !MTRDeviceControllerFactory.sharedInstance().isRunning else { throw MatterFabricError.factoryInUse }
        let storage = try MatterKeychainStorage(service: service)
        let repository = MatterFabricRepository(storage: storage.secrets)
        // Save one complete identity before any stack/fabric mutation. Failed initialization is
        // recoverable with open(); creating again must never silently rotate the root/IPK.
        var ipk = Data(count: 16)
        let status = ipk.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw MatterFabricError.storageUnavailable }
        let record = MatterFabricRecord(identity: UUID(), fabricID: fabricID, vendorID: vendorID,
            ipk: ipk, rootPrivateKey: try MatterRootSigner.generateRepresentation())
        try repository.create(record)
        return try MatterFabric(storage: storage, repository: repository, record: record, trustedPAAs: trustedPAAs)
    }
    public static func open(service: String, trustedPAAs: [Data]) throws -> MatterFabric {
        try validateTrust(trustedPAAs)
        guard owner == nil, !MTRDeviceControllerFactory.sharedInstance().isRunning else { throw MatterFabricError.factoryInUse }
        let storage = try MatterKeychainStorage(service: service)
        let repository = MatterFabricRepository(storage: storage.secrets)
        return try MatterFabric(storage: storage, repository: repository, record: repository.load(), trustedPAAs: trustedPAAs)
    }
    private static func validateTrust(_ certificates: [Data]) throws {
        guard !certificates.isEmpty, certificates.count <= 512,
              certificates.allSatisfy({ !$0.isEmpty && $0.count <= 16_384 && SecCertificateCreateWithData(nil, $0 as CFData) != nil }) else {
            throw MatterFabricError.invalidConfiguration
        }
    }
    private init(storage: MatterKeychainStorage, repository: MatterFabricRepository,
                 record: MatterFabricRecord, trustedPAAs: [Data]) throws {
        identity = record.identity; self.storage = storage; self.repository = repository
        signer = try MatterRootSigner(privateRepresentation: record.rootPrivateKey)
        factory = MTRDeviceControllerFactory.sharedInstance()
        guard Self.owner == nil, !factory.isRunning else { throw MatterFabricError.factoryInUse }
        let params = MTRDeviceControllerFactoryParams(storage: storage)
        params.productAttestationAuthorityCertificates = trustedPAAs
        do {
            try factory.start(params)
            Self.owner = identity
            guard !storage.storageFailed, let known = factory.knownFabrics else { throw MatterFabricError.storageUnavailable }
            let publicKey = try signer.publicRepresentation()
            let matches = known.filter { $0.fabricID.uint64Value == record.fabricID && $0.rootPublicKey == publicKey }
            guard matches.count <= 1, known.count == matches.count else { throw MatterFabricError.corruptStorage }
            let controller: MTRDeviceController
            if matches.count == 1 { controller = try factory.createController(onExistingFabric: startup(record)) }
            else {
                guard !record.initialized else { throw MatterFabricError.corruptStorage }
                controller = try factory.createController(onNewFabric: startup(record))
            }
            controller.shutdown()
            guard !storage.storageFailed else { throw MatterFabricError.storageUnavailable }
            try repository.markInitialized()
        } catch {
            // Only shut down a factory we successfully started and claimed.
            if Self.owner == identity { factory.stop(); Self.owner = nil }
            throw error is MatterFabricError ? error : MatterFabricError.controllerUnavailable
        }
    }
    private func startup(_ record: MatterFabricRecord) -> MTRDeviceControllerStartupParams {
        let params = MTRDeviceControllerStartupParams(ipk: record.ipk, fabricID: NSNumber(value: record.fabricID), nocSigner: signer)
        params.vendorID = NSNumber(value: record.vendorID)
        params.nodeID = 1
        return params
    }
    private func controller() throws -> MTRDeviceController {
        guard !closed, Self.owner == identity, factory.isRunning,
              transferredController?.isRunning != true else { throw MatterFabricError.invalidState }
        guard !storage.storageFailed else { throw MatterFabricError.storageUnavailable }
        do {
            let result = try factory.createController(onExistingFabric: startup(repository.load()))
            if storage.storageFailed { result.shutdown(); throw MatterFabricError.storageUnavailable }
            return result
        } catch { throw error is MatterFabricError ? error : MatterFabricError.controllerUnavailable }
    }
    /// Returns a provider whose connection leases this fabric's only controller. Disconnect
    /// that provider before commissioning another node or closing the fabric.
    public func sensorProvider(sensors: [MatterSensorConfiguration], maxStateAge: TimeInterval = 60) throws -> MatterProvider {
        guard !closed else { throw MatterFabricError.invalidState }
        return try MatterProvider.usingExclusiveController(fabricIdentity: identity, sensors: sensors,
            maxStateAge: maxStateAge, makeController: { [self] in
                guard !commissioning else { throw MatterFabricError.invalidState }
                let result = try controller(); transferredController = result; return result
            })
    }
    /// Pending reservations can represent a process interrupted after device-side mutation.
    /// They must be reconciled by the host, never retried automatically with the same node ID.
    public func commissioningRecords() throws -> [MatterCommissioningRecord] {
        try repository.load().attempts.map { MatterCommissioningRecord(nodeID: $0.key, disposition: $0.value) }
            .sorted { $0.nodeID < $1.nodeID }
    }
    /// For an already networked device in an open commissioning window. The host obtains the
    /// payload from its scan/manual/system UI. It is never stored or logged by this module.
    /// Commissioning changes a device's fabric membership; invoke only on the selected device.
    public func commission(onboardingPayload: String) async throws -> UInt64 {
        try Task.checkCancellation()
        guard !commissioning, !closed, onboardingPayload.utf8.count <= 512 else { throw MatterFabricError.invalidState }
        let payload: MTRSetupPayload
        do {
            if #available(iOS 17.6, macOS 14.6, watchOS 10.6, tvOS 17.6, visionOS 1.0, *) {
                guard let decoded = MTRSetupPayload(payload: onboardingPayload) else { throw MatterFabricError.invalidConfiguration }
                payload = decoded
            } else { payload = try MTRSetupPayload(onboardingPayload: onboardingPayload) }
        }
        catch { throw MatterFabricError.invalidConfiguration }
        let native = try controller(); commissioning = true
        defer { native.shutdown(); commissioning = false }
        let node = try repository.reserveNode()
        let lifetime = MatterCommissioningLifetime()
        let delegate = MatterCommissioningDelegate(nodeID: node, lifetime: lifetime)
        native.setDeviceControllerDelegate(delegate, queue: .main)
        do {
            let _: UInt64 = try await withTaskCancellationHandler {
                try await matterReadWithDeadline(timeout: .seconds(180)) { completion in
                    delegate.completion = completion
                    do { try native.setupCommissioningSession(with: payload, newNodeID: NSNumber(value: node)) }
                    catch { delegate.fail() }
                }
            } onCancel: { lifetime.cancel() }
            try Task.checkCancellation()
            delegate.completion = nil
            native.shutdown()
            guard !storage.storageFailed else { throw MatterFabricError.storageUnavailable }
            try repository.finishNode(node, outcome: .commissioned)
            return node
        } catch {
            lifetime.cancel()
            delegate.completion = nil
            try? native.cancelCommissioning(forNodeID: NSNumber(value: node))
            // A failed/cancelled callback is not proof that nothing reached the accessory.
            // Retain the node reservation even if marking it uncertain itself fails.
            try? repository.finishNode(node, outcome: .uncertain)
            throw error is CancellationError || error is IoTError || error is MatterFabricError
                ? error : MatterFabricError.commissioningFailed
        }
    }
    /// Stops only this factory after all transferred controllers and commissioning have stopped.
    /// Credentials and pairings remain in Keychain. There is deliberately no factory reset API.
    public func close() throws {
        guard !commissioning, transferredController?.isRunning != true else { throw MatterFabricError.invalidState }
        guard !closed else { return }
        guard Self.owner == identity else { throw MatterFabricError.factoryInUse }
        factory.stop(); Self.owner = nil; closed = true; transferredController = nil
    }
}

@MainActor
private final class MatterCommissioningDelegate: NSObject, @preconcurrency MTRDeviceControllerDelegate {
    private var flow: MatterCommissioningFlow
    private let lifetime: MatterCommissioningLifetime
    var completion: (@Sendable (Result<UInt64, any Error>) -> Void)?
    init(nodeID: UInt64, lifetime: MatterCommissioningLifetime) {
        flow = MatterCommissioningFlow(nodeID: nodeID); self.lifetime = lifetime; super.init()
    }
    func fail() {
        _ = flow.complete(nodeID: nil, failed: true)
        finish(.failure(MatterFabricError.commissioningFailed))
    }
    private func finish(_ result: Result<UInt64, any Error>) {
        let callback = completion; completion = nil; callback?(result)
    }
    func controller(_ controller: MTRDeviceController, statusUpdate status: MTRCommissioningStatus) {
        if status == .failed {
            fail()
        }
    }
    func controller(_ controller: MTRDeviceController, commissioningSessionEstablishmentDone error: (any Error)?) {
        guard completion != nil, lifetime.isActive else { fail(); return }
        switch flow.established(failed: error != nil) {
        case .commission:
            do { try controller.commissionNode(withID: NSNumber(value: flow.nodeID), commissioningParams: MTRCommissioningParameters()) }
            catch { _ = flow.complete(nodeID: nil, failed: true); finish(.failure(MatterFabricError.commissioningFailed)) }
        case .failed: finish(.failure(MatterFabricError.commissioningFailed))
        default: break
        }
    }
    func controller(_ controller: MTRDeviceController, commissioningComplete error: (any Error)?, nodeID: NSNumber?) {
        guard lifetime.isActive else { fail(); return }
        switch flow.complete(nodeID: nodeID?.uint64Value, failed: error != nil) {
        case .succeeded: finish(.success(flow.nodeID))
        case .failed: finish(.failure(MatterFabricError.commissioningFailed))
        default: break
        }
    }
}
#endif
