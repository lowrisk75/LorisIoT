import Foundation
import IoTCore

/// Home Assistant provider — the pivot integration. Control + read via REST (with confirm-by-reread),
/// live updates via the WebSocket (auth handshake + `state_changed` subscription, resilient through
/// `RealtimeSocketClient`), and `.schedule` via an `input_datetime` helper the user's HA automation
/// reacts to (the server-side pre-provisioning law).
///
/// Reaches thousands of third-party devices for free: anything HA integrates (Zigbee/Z-Wave/Thread via
/// hubs, ESPHome, Tuya-via-HA) appears here as an entity.
public actor HomeAssistantProvider: DeviceProvider, SchedulingProvider {
    public nonisolated let id = "homeassistant"
    public nonisolated let displayName = "Home Assistant"
    public var capabilities: Set<DeviceCapability> { [.control, .readState, .subscribe, .schedule] }

    private let config: HAConfig
    private let token: String
    private let rest: HARestClient
    /// Optional `input_datetime.<name>` used to pre-provision a scheduled wake (nil → `.schedule` no-ops).
    private let wakeHelperEntity: String?

    private var socket: RealtimeSocketClient<HAMessage>?
    private var cache: [String: HAEntityState] = [:]

    /// - Parameters:
    ///   - http: injected for tests; defaults to a real `URLSession` client with the bearer token.
    public init(config: HAConfig, token: String, http: HAHTTP? = nil, wakeHelperEntity: String? = nil) {
        self.config = config
        self.token = token
        self.rest = HARestClient(http: http ?? HAURLSessionHTTP(baseURL: config.baseURL, token: token))
        self.wakeHelperEntity = wakeHelperEntity
    }

    // MARK: - DeviceProvider

    public func connect() async throws { _ = try await rest.verify() }
    public func disconnect() async { await socket?.stop(); socket = nil }

    public func readState(_ target: DeviceTarget) async throws -> DeviceState {
        if let cached = cache[target.id] { return cached.deviceState }
        let s = try await rest.state(entityID: target.id)
        cache[target.id] = s
        return s.deviceState
    }

    /// Apply the command, then re-read and confirm — throws `.unconfirmed` if HA's state doesn't match.
    @discardableResult
    public func setState(_ target: DeviceTarget, _ command: DeviceCommand) async throws -> DeviceState {
        let domain = haDomain(of: target.id)
        switch command {
        case .setPower(let on):
            try await rest.callService(domain: domain, service: on ? "turn_on" : "turn_off", entityID: target.id)
            return try await confirm(target.id) { $0.power == on }
        case .toggle:
            try await rest.callService(domain: domain, service: "toggle", entityID: target.id)
            return try await confirm(target.id) { $0.power != nil }
        case .setLevel(let pct):
            let p = max(0, min(100, pct))
            try await rest.callService(domain: domain, service: "turn_on", entityID: target.id,
                                       data: ["brightness_pct": p])
            return try await confirm(target.id) { $0.power == true }
        }
    }

    /// Re-read the entity and validate the physical state against `predicate` (confirm-by-reread).
    private func confirm(_ entityID: String, _ predicate: (DeviceState) -> Bool) async throws -> DeviceState {
        let s = try await rest.state(entityID: entityID)
        cache[entityID] = s
        let ds = s.deviceState
        guard predicate(ds) else { throw ProviderError.unconfirmed }
        return ds
    }

    // MARK: - SchedulingProvider (input_datetime server-side pre-provisioning)

    public func provision(_ schedule: DeviceSchedule) async throws -> ScheduleHandle {
        guard let helper = wakeHelperEntity else {
            throw ProviderError.notSupported("No input_datetime helper configured for scheduling")
        }
        let iso = Self.nextISO(hour: schedule.hour, minute: schedule.minute)
        try await rest.setInputDatetime(entityID: helper, isoDate: iso)
        return ScheduleHandle(helper)
    }

    public func clear(_ handle: ScheduleHandle) async {
        // Set the helper far in the past so the user's automation treats it as inactive.
        try? await rest.setInputDatetime(entityID: handle.rawValue, isoDate: "1970-01-01 00:00:00")
    }

    /// Next future "yyyy-MM-dd HH:mm:ss" (HA's input_datetime format) for hour:minute, local time.
    static func nextISO(hour: Int, minute: Int, now: Date = Date(), calendar: Calendar = .current) -> String {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour; comps.minute = minute; comps.second = 0
        var date = calendar.date(from: comps) ?? now
        if date <= now { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    // MARK: - Live updates (WebSocket)

    /// Start (or reuse) the resilient WebSocket and return a stream of entity-state updates. Feeds the
    /// local cache so `readState` is instant. The auth handshake + subscribe run on every (re)connect.
    public func liveStates() async throws -> AsyncStream<HAEntityState> {
        guard let wsURL = config.websocketURL else { throw ProviderError.notConfigured }
        let token = self.token
        let client = RealtimeSocketClient<HAMessage>(
            makeTransport: { HAWebSocketTransport(url: wsURL) },
            decode: { HAMessage.decode($0) },
            onConnected: { transport in
                // HA handshake: server → auth_required, client → auth, server → auth_ok, then subscribe.
                _ = try await transport.receive()                       // auth_required
                try await transport.send(HAOutbound.auth(token: token))
                let okFrame = try await transport.receive()
                guard case .authOK = HAMessage.decode(okFrame) else {
                    throw ProviderError.authenticationFailed(reason: "auth_invalid")
                }
                try await transport.send(HAOutbound.subscribeStateChanged(id: 1))
            },
            ping: { transport in try? await transport.send(HAOutbound.ping(id: 999)) }
        )
        self.socket = client
        let raw = await client.messages()
        return AsyncStream { continuation in
            let task = Task {
                for await msg in raw {
                    if case .stateChanged(let entity) = msg {
                        self.updateCache(entity)
                        continuation.yield(entity)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func updateCache(_ entity: HAEntityState) { cache[entity.entityID] = entity }
}
