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
                useTLS: Bool = false, keepAlive: UInt16 = 60) {
        self.host = host; self.port = port; self.clientID = clientID
        self.username = username; self.password = password
        self.useTLS = useTLS; self.keepAlive = keepAlive
    }
}

/// `MQTTTransport` backed by `CocoaMQTT5`. The delegate bridge below converts CocoaMQTT's
/// @objc callbacks into awaitable acks + an `AsyncStream` of frames. Auto-reconnect is delegated
/// to the library (it owns the socket); on each reconnect CONNACK the bridge re-subscribes every
/// previously subscribed topic — CocoaMQTT does NOT do that by itself.
public actor CocoaMQTTTransport: MQTTTransport {
    private let config: MQTTBrokerConfig
    private let bridge = MQTT5DelegateBridge()
    private var client: CocoaMQTT5?

    public init(config: MQTTBrokerConfig) {
        self.config = config
    }

    public func connect() async throws {
        if client != nil { return }
        let c = CocoaMQTT5(clientID: config.clientID, host: config.host, port: config.port)
        c.username = config.username
        c.password = config.password
        c.keepAlive = config.keepAlive
        c.enableSSL = config.useTLS
        c.cleanSession = true
        c.autoReconnect = true
        c.delegate = bridge
        client = c
        try await bridge.awaitConnack(timeout: 15) {
            if !c.connect(timeout: 10) { self.bridge.failConnect(IoTError.transport("socket connect refused")) }
        }
    }

    public func disconnect() async {
        bridge.shutDown()
        client?.disconnect()
        client = nil
    }

    public func subscribe(topic: String) async throws {
        guard let client else { throw IoTError.notConnected }
        try await bridge.awaitSubAck(topic: topic, timeout: 10) {
            client.subscribe(topic, qos: .qos1)
        }
    }

    public func publish(topic: String, payload: Data, qos: MQTTQoS, retain: Bool) async throws {
        guard let client else { throw IoTError.notConnected }
        let message = CocoaMQTT5Message(topic: topic, payload: [UInt8](payload),
                                        qos: Self.map(qos), retained: retain)
        _ = client.publish(message, properties: MqttPublishProperties())
    }

    public func messages() async -> AsyncStream<(topic: String, payload: Data)> {
        bridge.frames()
    }

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
    private var connectCont: CheckedContinuation<Void, any Error>?
    private var subConts: [String: CheckedContinuation<Void, any Error>] = [:]
    private var subscribedTopics: Set<String> = []
    private var streamCont: AsyncStream<(topic: String, payload: Data)>.Continuation?
    private var everConnected = false

    // MARK: Await helpers (called from the transport actor)

    func awaitConnack(timeout: Double, start: @escaping @Sendable () -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            lock.lock(); connectCont = cont; lock.unlock()
            start()
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                self.resumeConnect(.failure(IoTError.timeout))
            }
        }
    }

    func awaitSubAck(topic: String, timeout: Double, start: @escaping @Sendable () -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            lock.lock(); subConts[topic] = cont; lock.unlock()
            start()
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                self.resumeSub(topic: topic, with: .failure(IoTError.timeout))
            }
        }
    }

    func frames() -> AsyncStream<(topic: String, payload: Data)> {
        AsyncStream { continuation in
            lock.lock(); streamCont = continuation; lock.unlock()
        }
    }

    func failConnect(_ error: any Error) { resumeConnect(.failure(error)) }

    func shutDown() {
        lock.lock()
        let connect = connectCont; connectCont = nil
        let subs = subConts; subConts = [:]
        let stream = streamCont; streamCont = nil
        subscribedTopics = []
        lock.unlock()
        connect?.resume(throwing: IoTError.cancelled)
        for (_, cont) in subs { cont.resume(throwing: IoTError.cancelled) }
        stream?.finish()
    }

    // MARK: Resume-once plumbing

    private func resumeConnect(_ result: Result<Void, any Error>) {
        lock.lock()
        let cont = connectCont
        connectCont = nil
        lock.unlock()
        cont?.resume(with: result)
    }

    private func resumeSub(topic: String, with result: Result<Void, any Error>) {
        lock.lock()
        let cont = subConts.removeValue(forKey: topic)
        if case .success = result { subscribedTopics.insert(topic) }
        lock.unlock()
        cont?.resume(with: result)
    }
}

extension MQTT5DelegateBridge: CocoaMQTT5Delegate {

    func mqtt5(_ mqtt5: CocoaMQTT5, didConnectAck ack: CocoaMQTTCONNACKReasonCode, connAckData: MqttDecodeConnAck?) {
        switch ack {
        case .success:
            lock.lock()
            let isReconnect = everConnected
            everConnected = true
            let topics = subscribedTopics
            lock.unlock()
            // CocoaMQTT's autoReconnect re-opens the socket but does NOT resubscribe — replay
            // the subscription set so a broker restart doesn't silently mute the stream.
            if isReconnect { for topic in topics { mqtt5.subscribe(topic, qos: .qos1) } }
            resumeConnect(.success(()))
        case .badUsernameOrPassword, .notAuthorized:
            resumeConnect(.failure(IoTError.authenticationFailed(reason: "CONNACK 0x\(String(ack.rawValue, radix: 16))")))
        default:
            resumeConnect(.failure(IoTError.transport("CONNACK 0x\(String(ack.rawValue, radix: 16))")))
        }
    }

    func mqtt5(_ mqtt5: CocoaMQTT5, didReceiveMessage message: CocoaMQTT5Message, id: UInt16, publishData: MqttDecodePublish?) {
        lock.lock(); let stream = streamCont; lock.unlock()
        stream?.yield((topic: message.topic, payload: Data(message.payload)))
    }

    func mqtt5(_ mqtt5: CocoaMQTT5, didSubscribeTopics success: NSDictionary, failed: [String], subAckData: MqttDecodeSubAck?) {
        for case let topic as String in success.allKeys {
            resumeSub(topic: topic, with: .success(()))
        }
        for topic in failed {
            resumeSub(topic: topic, with: .failure(IoTError.transport("SUBACK failed for \(topic)")))
        }
    }

    func mqtt5DidDisconnect(_ mqtt5: CocoaMQTT5, withError err: (any Error)?) {
        // Library-level autoReconnect keeps trying; only a pre-CONNACK failure must surface —
        // otherwise the pending connect() would hang until its timeout.
        if let err { resumeConnect(.failure(IoTError.transport(err.localizedDescription))) }
    }

    // MARK: Unused delegate requirements

    func mqtt5(_ mqtt5: CocoaMQTT5, didPublishMessage message: CocoaMQTT5Message, id: UInt16) {}
    func mqtt5(_ mqtt5: CocoaMQTT5, didPublishAck id: UInt16, pubAckData: MqttDecodePubAck?) {}
    func mqtt5(_ mqtt5: CocoaMQTT5, didPublishRec id: UInt16, pubRecData: MqttDecodePubRec?) {}
    func mqtt5(_ mqtt5: CocoaMQTT5, didUnsubscribeTopics topics: [String], unsubAckData: MqttDecodeUnsubAck?) {}
    func mqtt5(_ mqtt5: CocoaMQTT5, didReceiveDisconnectReasonCode reasonCode: CocoaMQTTDISCONNECTReasonCode) {}
    func mqtt5(_ mqtt5: CocoaMQTT5, didReceiveAuthReasonCode reasonCode: CocoaMQTTAUTHReasonCode) {}
    func mqtt5DidPing(_ mqtt5: CocoaMQTT5) {}
    func mqtt5DidReceivePong(_ mqtt5: CocoaMQTT5) {}
    func mqtt5(_ mqtt5: CocoaMQTT5, didStateChangeTo state: CocoaMQTTConnState) {}
}
