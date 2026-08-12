import Foundation

/// The spine of LorisIoT. Every integration (Home Assistant, Shelly, MQTT, HomeKit…) is an `actor`
/// conforming to this — actor-constrained so tokens/connection state are protected by construction.
///
/// **Confirm-by-reread contract:** `setState` must re-read the device after writing and throw
/// `ProviderError.unconfirmed` if the physical state doesn't match the request. Never acknowledge a
/// command optimistically.
public protocol DeviceProvider: Actor {
    /// Stable provider-scoped id (e.g. "shelly-<uuid>", "homeassistant").
    nonisolated var id: String { get }
    /// User-facing name.
    nonisolated var displayName: String { get }
    /// What this provider can do right now (see the capability law).
    var capabilities: Set<DeviceCapability> { get }

    func connect() async throws
    func disconnect() async

    func readState(_ target: DeviceTarget) async throws -> DeviceState
    /// Apply `command`, then re-read and confirm; throws `.unconfirmed` if not confirmed.
    @discardableResult
    func setState(_ target: DeviceTarget, _ command: DeviceCommand) async throws -> DeviceState
}

/// Providers that can pre-provision a timed action on an always-on system. Only conform when
/// `.schedule ∈ capabilities` — this is the type-level half of the pre-provisioning law, so an app
/// physically cannot ask a control-only provider to back a timed wake.
public protocol SchedulingProvider: DeviceProvider {
    /// Install (replacing our previously-installed job) a schedule; returns a handle to track it.
    func provision(_ schedule: DeviceSchedule) async throws -> ScheduleHandle
    /// Remove a previously-provisioned schedule. Best-effort.
    func clear(_ handle: ScheduleHandle) async
}
