import Foundation
import Observation
import IoTCore

public enum IoTCommandPhase: String, Sendable {
    case idle, sending, accepted, applied, rejected, uncertain
}

public enum IoTConnectionIssue: String, Sendable {
    case connection, authentication, invalidData, unsupported, configuration
    static func classify(_ error: any Error) -> Self {
        switch error as? IoTError {
        case .authenticationFailed: .authentication
        case .invalidResponse: .invalidData
        case .notSupported: .unsupported
        case .notConfigured: .configuration
        default: .connection
        }
    }
}

/// UI state contains observations and receipts, never an optimistic replacement of the device value.
@MainActor @Observable public final class IoTDeviceModel {
    public let device: Device
    public private(set) var state: DeviceState?
    public private(set) var phase: IoTCommandPhase = .idle
    public private(set) var issue: IoTConnectionIssue?
    public private(set) var canControl = false
    public private(set) var loading = true
    private let provider: any DeviceProvider
    private var capabilities: DeviceCapabilitySet?
    private var observing = false
    private var desired: Bool?
    private var sentAt: Date?

    public init(device: Device, provider: any DeviceProvider) {
        self.device = device; self.provider = provider
    }

    /// The view's task owns this operation. Leaving the view cancels its stream/polling.
    public func observe() async {
        guard !observing else { return }
        observing = true; defer { observing = false; loading = false }
        while !Task.isCancelled {
            do {
                try await provider.connect()
                let capabilities = try await provider.capabilities(for: device.id)
                self.capabilities = capabilities; canControl = capabilities.control != nil
                await refresh()
                if let subscribe = capabilities.subscribe {
                    for try await change in await subscribe.stateChanges() {
                        try Task.checkCancellation()
                        switch change {
                        case .snapshot(let state), .updated(_, let state): accept(state)
                        case .unavailable(let id, _) where id == device.id:
                            state = state?.withAvailability(.offline); issue = .connection
                        default: break
                        }
                    }
                    throw IoTError.notConnected
                } else {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(15))
                        await refresh()
                    }
                }
            } catch is CancellationError { return }
            catch { issue = .classify(error); state = state?.withAvailability(.degraded); loading = false }
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
        }
    }

    public func refresh() async {
        do {
            if capabilities == nil {
                let capabilities = try await provider.capabilities(for: device.id)
                self.capabilities = capabilities; canControl = capabilities.control != nil
            }
            guard let read = capabilities?.readState else { loading = false; return }
            accept(try await read.state()); loading = false
        } catch is CancellationError {}
        catch { issue = .classify(error); state = state?.withAvailability(.degraded); loading = false }
    }

    public func setPower(_ on: Bool) async {
        guard phase != .sending, let control = capabilities?.control else { return }
        let command = SetPowerCommand(deviceID: device.id, isOn: on)
        desired = on; sentAt = Date(); phase = .sending; issue = nil
        do {
            let receipt = try await control.execute(command)
            guard receipt.commandID == command.id, receipt.deviceID == device.id else {
                phase = .uncertain; issue = .invalidData; return
            }
            if let state = receipt.state { accept(state) }
            switch receipt.outcome {
            case .applied:
                // accept() can reject an out-of-order receipt. Such a receipt must
                // not confirm a command against the newer state retained by the UI.
                phase = receipt.state == state
                    && receipt.state?.deviceID == device.id && receipt.state?.primaryValue == .bool(on)
                    && receipt.state?.freshness() == .current
                    && receipt.state.map { $0.receivedAt >= (sentAt ?? .distantFuture) } == true ? .applied : .uncertain
            case .accepted: phase = .accepted
            case .rejected: phase = .rejected
            case .uncertain: phase = .uncertain
            }
            if phase == .accepted { await refresh() }
        } catch {
            phase = .uncertain
            if !(error is CancellationError) { issue = .classify(error) }
        }
    }

    private func accept(_ value: DeviceState) {
        guard value.deviceID == device.id else { issue = .invalidData; return }
        guard state.map({ value.revision >= $0.revision }) ?? true else { return }
        state = value; loading = false; issue = nil
        if phase == .accepted, let desired, let sentAt,
           value.receivedAt >= sentAt, value.freshness() == .current, value.primaryValue == .bool(desired) {
            phase = .applied
        }
    }

    public var diagnosticSummary: String {
        // No addresses, identifiers, tokens or raw transport errors.
        ["Provider: \(provider.displayName)", "Availability: \(state?.availability.rawValue ?? "unknown")",
         "Freshness: \(state?.freshness().rawValue ?? "unknown")", "Command: \(phase.rawValue)",
         "Issue: \(issue?.rawValue ?? "none")"].joined(separator: "\n")
    }
}
