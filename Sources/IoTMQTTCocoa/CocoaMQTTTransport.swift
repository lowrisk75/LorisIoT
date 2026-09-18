import Foundation
import IoTMQTT
import IoTCore
// @preconcurrency: CocoaMQTT predates Sendable annotations; CocoaMQTT5 serializes its own state
// on an internal dispatch queue, and our actor + lock-guarded bridge own every access from here.
@preconcurrency import CocoaMQTT

// Production `MQTTTransport` over CocoaMQTT 5.0 — the library locked by research #18 (most
// battle-tested MQTT 5 Swift client, Swift 6-clean). Guardrail from that report: CocoaMQTT types
// NEVER cross this module's public boundary, so the lib remains swappable (swift-mqtt for QUIC,
// MQTTNIO…) without touching IoTMQTT or any app.

/// Broker connection settings. TLS uses the system trust store; client-cert (mTLS) and TOFU pinning
/// can be layered later via `sslSettings` without changing this surface.
public struct MQTTBrokerConfig: Sendable, Hashable {
    public var host: String
    public var port: UInt16
    public var clientID: String
    public var username: String?
    public var password: String?
    public var useTLS: Bool
    public var keepAlive: UInt16

    public init(host: String, port: UInt16 = 1883, clientID: String,
                username: String? = nil, password: String? = nil,
                useTLS: Bool = false, keepAlive: UInt16 = 15) {
        self.host = host; self.port = port; self.clientID = clientID
        self.username = username; self.password = password
        self.useTLS = useTLS; self.keepAlive = keepAlive
    }
}

/// `MQTTTransport` backed by `CocoaMQTT5`. The delegate bridge below converts CocoaMQTT's
/// @objc callbacks into awaitable acks + an `AsyncStream` of frames. Auto-reconnect is delegated
/// to the library (it owns the socket); on each reconnect CONNACK the bridge re-subscribes every
/// previously subscribed topic — CocoaMQTT does NOT do that by itself.
public actor CocoaMQTTTransport: MQTTTransport, MQTTConnectionMonitoring {
    private let config: MQTTBrokerConfig
    private let bridge = MQTT5DelegateBridge()
    private var client: CocoaMQTT5?
    private var connecting: Task<Void, any Error>?
    private var generation: UInt64 = 0

    public init(config: MQTTBrokerConfig) {
        self.config = config
    }

    deinit {
        connecting?.cancel()
        bridge.shutDown()
        client?.autoReconnect = false
        client?.delegate = nil
        client?.disconnect()
    }

    /// The literal the policy checked: CocoaMQTT's resolver would treat a bracketed IPv6 host as a name.
    static func connectHost(_ host: String) -> String {
        host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    }

    public func connect() async throws {
        if let connecting { return try await connecting.value }
        if client != nil, bridge.isReady { return }
        guard !config.host.isEmpty, !config.host.contains("://"), !config.clientID.isEmpty,
              config.port > 0, config.keepAlive > 0 else { throw IoTError.notConfigured }
        // Credentials cross a public network only inside TLS. Private LAN and tailnet brokers may stay plain.
        let carriesCredentials = !(config.username ?? "").isEmpty || !(config.password ?? "").isEmpty
        guard !carriesCredentials || config.useTLS || HTTPOrigin.isPrivateHost(config.host) else {
            throw IoTError.notSupported("MQTT credentials over a non-TLS connection are only allowed on a private network")
        }
        if let previous = client { previous.autoReconnect = false; previous.disconnect() }
        generation &+= 1; let token = generation
        let c = CocoaMQTT5(clientID: config.clientID, host: Self.connectHost(config.host), port: config.port)
        c.username = config.username
        c.password = config.password
        c.keepAlive = config.keepAlive
        c.enableSSL = config.useTLS
        c.cleanSession = true
        c.autoReconnect = true
        c.delegate = bridge
        let properties = MqttConnectProperties()
        properties.maximumPacketSize = 1_048_576
        c.connectProperties = properties
        bridge.activate(c)
        client = c
        let task = Task { [bridge] in
            try await bridge.awaitConnack(timeout: 15) {
                if !c.connect(timeout: 10) { bridge.failConnect(IoTError.transport("socket connect refused")) }
            }
        }
        connecting = task
        do {
            try await task.value
            guard generation == token else { throw CancellationError() }
            connecting = nil
        } catch {
            if generation == token {
                connecting = nil; client = nil
                bridge.shutDown(); c.autoReconnect = false; c.disconnect()
            }
            throw error
        }
    }

    public func disconnect() async {
        generation &+= 1; connecting?.cancel(); connecting = nil
        bridge.shutDown()
        client?.autoReconnect = false
        client?.disconnect()
        client = nil
    }

    public func subscribe(topic: String) async throws {
        guard let client, bridge.isReady, !topic.isEmpty else { throw IoTError.notConnected }
        let token = generation
        do {
            try await bridge.awaitSubAck(topic: topic, timeout: 10) {
                client.subscribe(topic, qos: .qos1)
            }
        } catch {
            // A late SUBACK has no public packet ID in this API. Retire this client before retrying.
            if token == generation { await disconnect() }
            throw error
        }
    }

    public func publish(topic: String, payload: Data, qos: MQTTQoS, retain: Bool) async throws {
        guard let client, bridge.isReady else { throw IoTError.notConnected }
        guard !topic.isEmpty, !topic.contains("#"), !topic.contains("+"), !topic.contains("\0"),
              topic.utf8.count <= 65535, payload.count <= 65_536 else { throw IoTError.notConfigured }
        try Task.checkCancellation()
        let message = CocoaMQTT5Message(topic: topic, payload: [UInt8](payload),
                                        qos: Self.map(qos), retained: retain)
        if qos == .atMostOnce {
            guard client.publish(message, properties: MqttPublishProperties()) >= 0 else {
                throw IoTError.transport("Publish was not queued")
            }
        } else {
            let token = generation
            do {
                try await bridge.awaitPublishAck(qos: qos, timeout: 10) {
                    client.publish(message, properties: MqttPublishProperties())
                }
                guard generation == token else { throw CancellationError() }
            } catch {
                if generation == token { await disconnect() }
                throw error
            }
        }
    }

    public func messages() async -> AsyncStream<(topic: String, payload: Data)> {
        bridge.frames()
    }

    public func connectionStates() async -> AsyncStream<ProviderConnectionState> { bridge.states() }
    public func observations() async -> AsyncStream<MQTTObservation> { bridge.observations() }

    static func map(_ qos: MQTTQoS) -> CocoaMQTTQoS {
        switch qos {
        case .atMostOnce: return .qos0
        case .atLeastOnce: return .qos1
        case .exactlyOnce: return .qos2
        }
    }
}

// MARK: - Delegate bridge

/// Lock-guarded bridge from CocoaMQTT's @objc delegate (called on its own dispatch queue) to
/// structured concurrency. `@unchecked Sendable`: every mutable field is accessed under `lock`.
/// Internal (not public) — but visible to the test target, which drives it by calling the delegate
/// methods directly, exactly as the library would (no broker needed).
final class MQTT5DelegateBridge: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var connectAck: MQTTAcknowledgement?
    private var subAcks: [String: MQTTAcknowledgement] = [:]
    private var publishAcks: [UInt16: (MQTTQoS, MQTTAcknowledgement)] = [:]
    private var subscribedTopics: Set<String> = []
    private var streamConts: [UUID: AsyncStream<(topic: String, payload: Data)>.Continuation] = [:]
    private var observationConts: [UUID: AsyncStream<MQTTObservation>.Continuation] = [:]
    private var stateConts: [UUID: AsyncStream<ProviderConnectionState>.Continuation] = [:]
    private var state: ProviderConnectionState = .disconnected
    private var activeClient: ObjectIdentifier?
    private var closed = false
    private var replayPending: Set<String> = []
    private var everConnected = false

    var isReady: Bool { lock.withLock { state == .connected && !closed } }

    func activate(_ client: CocoaMQTT5) {
        lock.withLock {
            activeClient = ObjectIdentifier(client); closed = false
            everConnected = false; replayPending = []; subscribedTopics = []
        }
        publishState(.connecting)
    }

    private func accepts(_ client: CocoaMQTT5) -> Bool {
        lock.withLock { !closed && (activeClient == nil || activeClient == ObjectIdentifier(client)) }
    }

    private func publishState(_ value: ProviderConnectionState) {
        lock.withLock {
            state = value
            for c in stateConts.values { c.yield(value) }
        }
    }

    func states() -> AsyncStream<ProviderConnectionState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c in
            let id = UUID()
            lock.withLock { stateConts[id] = c; c.yield(state) }
            c.onTermination = { [weak self] _ in self?.removeState(id) }
        }
    }
    private func removeState(_ id: UUID) { _ = lock.withLock { stateConts.removeValue(forKey: id) } }

    // MARK: Await helpers (called from the transport actor)

    func awaitConnack(timeout: Double, start: @escaping @Sendable () -> Void) async throws {
        let ack = MQTTAcknowledgement()
        guard lock.withLock({ if connectAck != nil { return false }; connectAck = ack; return true }) else {
            throw IoTError.transport("Connect already pending")
        }
        defer { lock.withLock { if connectAck === ack { connectAck = nil } } }
        try await ack.wait(timeout: timeout, start: start)
    }

    func awaitSubAck(topic: String, timeout: Double, start: @escaping @Sendable () -> Void) async throws {
        let ack = MQTTAcknowledgement()
        guard lock.withLock({ if subAcks[topic] != nil { return false }; subAcks[topic] = ack; return true }) else {
            throw IoTError.transport("Subscription already pending")
        }
        defer { lock.withLock { if subAcks[topic] === ack { subAcks[topic] = nil } } }
        try await ack.wait(timeout: timeout, start: start)
    }

    func frames() -> AsyncStream<(topic: String, payload: Data)> {
        AsyncStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            let id = UUID()
            lock.withLock { streamConts[id] = continuation }
            continuation.onTermination = { [weak self] _ in self?.removeFrames(id) }
        }
    }

    /// CocoaMQTT invokes delegates asynchronously. Hold the registration lock through publish's
    /// packet-ID return so an early callback cannot arrive before its waiter exists.
    func awaitPublishAck(qos: MQTTQoS, timeout: Double, start: @escaping @Sendable () -> Int) async throws {
        guard qos != .atMostOnce else { throw IoTError.notConfigured }
        let ack = MQTTAcknowledgement()
        defer { lock.withLock { publishAcks = publishAcks.filter { $0.value.1 !== ack } } }
        try await ack.wait(timeout: timeout) {
            let queued = self.lock.withLock { () -> Bool in
                guard !self.closed, self.publishAcks.count < 32,
                      let id = UInt16(exactly: start()), id > 0, self.publishAcks[id] == nil else { return false }
                self.publishAcks[id] = (qos, ack)
                return true
            }
            if !queued { ack.finish(.failure(IoTError.transport("Publish was not queued"))) }
        }
    }

    private func finishPublish(_ id: UInt16, qos: MQTTQoS, reason: UInt8) {
        let ack = lock.withLock { () -> MQTTAcknowledgement? in
            guard let item = publishAcks[id], item.0 == qos else { return nil }
            publishAcks[id] = nil
            return item.1
        }
        ack?.finish(reason < 128 ? .success(()) : .failure(IoTError.transport("Broker rejected publish")))
    }

    private func removeFrames(_ id: UUID) { _ = lock.withLock { streamConts.removeValue(forKey: id) } }

    func observations() -> AsyncStream<MQTTObservation> {
        AsyncStream(bufferingPolicy: .bufferingOldest(64)) { c in
            let id = UUID()
            lock.withLock { observationConts[id] = c }
            c.onTermination = { [weak self] _ in self?.removeObservation(id) }
        }
    }
    private func removeObservation(_ id: UUID) { _ = lock.withLock { observationConts.removeValue(forKey: id) } }

    func failConnect(_ error: any Error) { resumeConnect(.failure(error)) }

    func shutDown() {
        lock.lock()
        let connect = connectAck; connectAck = nil
        let subs = subAcks; subAcks = [:]
        let publishes = publishAcks; publishAcks = [:]
        let streams = streamConts; streamConts = [:]
        let observations = observationConts; observationConts = [:]
        subscribedTopics = []; replayPending = []; everConnected = false; closed = true
        lock.unlock()
        connect?.finish(.failure(IoTError.cancelled))
        for ack in subs.values { ack.finish(.failure(IoTError.cancelled)) }
        for item in publishes.values { item.1.finish(.failure(IoTError.cancelled)) }
        for stream in streams.values { stream.finish() }
        for c in observations.values { c.finish() }
        publishState(.disconnected)
    }

    // MARK: Resume-once plumbing

    private func resumeConnect(_ result: Result<Void, any Error>) {
        lock.lock()
        let ack = connectAck
        connectAck = nil
        lock.unlock()
        ack?.finish(result)
    }

    private func resumeSub(topic: String, with result: Result<Void, any Error>) {
        lock.lock()
        let ack = subAcks.removeValue(forKey: topic)
        if case .success = result {
            subscribedTopics.insert(topic); replayPending.remove(topic)
        }
        lock.unlock()
        ack?.finish(result)
    }
}

extension MQTT5DelegateBridge: CocoaMQTT5Delegate {

    func mqtt5(_ mqtt5: CocoaMQTT5, didConnectAck ack: CocoaMQTTCONNACKReasonCode, connAckData: MqttDecodeConnAck?) {
        guard accepts(mqtt5) else { return }
        switch ack {
        case .success:
            lock.lock()
            let isReconnect = everConnected
            everConnected = true
            let topics = subscribedTopics
            replayPending = isReconnect ? topics : []
            lock.unlock()
            // CocoaMQTT's autoReconnect re-opens the socket but does NOT resubscribe — replay
            // the subscription set so a broker restart doesn't silently mute the stream.
            if isReconnect { for topic in topics { mqtt5.subscribe(topic, qos: .qos1) } }
            publishState(isReconnect && !topics.isEmpty ? .connecting : .connected)
            resumeConnect(.success(()))
        case .badUsernameOrPassword, .notAuthorized:
            publishState(.degraded)
            resumeConnect(.failure(IoTError.authenticationFailed(reason: "CONNACK 0x\(String(ack.rawValue, radix: 16))")))
        default:
            publishState(.degraded)
            resumeConnect(.failure(IoTError.transport("CONNACK 0x\(String(ack.rawValue, radix: 16))")))
        }
    }

    func mqtt5(_ mqtt5: CocoaMQTT5, didReceiveMessage message: CocoaMQTT5Message, id: UInt16, publishData: MqttDecodePublish?) {
        guard accepts(mqtt5) else { return }
        let streams = lock.withLock { Array(streamConts.values) }
        let observations = lock.withLock { Array(observationConts.values) }
        guard message.payload.count <= 1_048_576 else {
            streams.forEach { $0.finish() }; observations.forEach { $0.finish() }; publishState(.degraded); return
        }
        let value = MQTTObservation(topic: message.topic, payload: Data(message.payload), retained: message.retained)
        for c in observations {
            if case .dropped = c.yield(value) { c.finish(); publishState(.degraded) }
        }
        for stream in streams {
            if case .dropped = stream.yield((topic: message.topic, payload: Data(message.payload))) {
                stream.finish(); publishState(.degraded)
            }
        }
    }

    func mqtt5(_ mqtt5: CocoaMQTT5, didSubscribeTopics success: NSDictionary, failed: [String], subAckData: MqttDecodeSubAck?) {
        guard accepts(mqtt5) else { return }
        for case let topic as String in success.allKeys {
            resumeSub(topic: topic, with: .success(()))
        }
        for topic in failed {
            resumeSub(topic: topic, with: .failure(IoTError.transport("SUBACK failed for \(topic)")))
        }
        if !failed.isEmpty { publishState(.degraded) }
        else if lock.withLock({ replayPending.isEmpty && everConnected }) { publishState(.connected) }
    }

    func mqtt5DidDisconnect(_ mqtt5: CocoaMQTT5, withError err: (any Error)?) {
        guard accepts(mqtt5) else { return }
        let error = IoTError.transport(err == nil ? "Socket disconnected" : "Socket failed")
        resumeConnect(.failure(error))
        let acks = lock.withLock { let acks = subAcks; subAcks = [:]; return acks }
        for ack in acks.values { ack.finish(.failure(error)) }
        let publishes = lock.withLock { let values = publishAcks; publishAcks = [:]; return values }
        for item in publishes.values { item.1.finish(.failure(error)) }
        publishState(.degraded)
    }

    // MARK: Unused delegate requirements

    func mqtt5(_ mqtt5: CocoaMQTT5, didPublishMessage message: CocoaMQTT5Message, id: UInt16) {}
    func mqtt5(_ mqtt5: CocoaMQTT5, didPublishAck id: UInt16, pubAckData: MqttDecodePubAck?) {
        guard accepts(mqtt5) else { return }
        finishPublish(id, qos: .atLeastOnce, reason: pubAckData?.reasonCode?.rawValue ?? 0)
    }
    func mqtt5(_ mqtt5: CocoaMQTT5, didPublishRec id: UInt16, pubRecData: MqttDecodePubRec?) {
        guard accepts(mqtt5), let reason = pubRecData?.reasonCode?.rawValue, reason >= 128 else { return }
        finishPublish(id, qos: .exactlyOnce, reason: reason)
    }
    func mqtt5(_ mqtt5: CocoaMQTT5, didPublishComplete id: UInt16, pubCompData: MqttDecodePubComp?) {
        guard accepts(mqtt5) else { return }
        finishPublish(id, qos: .exactlyOnce, reason: pubCompData?.reasonCode?.rawValue ?? 0)
    }
    func mqtt5(_ mqtt5: CocoaMQTT5, didUnsubscribeTopics topics: [String], unsubAckData: MqttDecodeUnsubAck?) {}
    func mqtt5(_ mqtt5: CocoaMQTT5, didReceiveDisconnectReasonCode reasonCode: CocoaMQTTDISCONNECTReasonCode) {}
    func mqtt5(_ mqtt5: CocoaMQTT5, didReceiveAuthReasonCode reasonCode: CocoaMQTTAUTHReasonCode) {}
    func mqtt5DidPing(_ mqtt5: CocoaMQTT5) {}
    func mqtt5DidReceivePong(_ mqtt5: CocoaMQTT5) {}
    func mqtt5(_ mqtt5: CocoaMQTT5, didStateChangeTo state: CocoaMQTTConnState) {}
}
