import Foundation
import CryptoKit
import IoTCore

#if canImport(Darwin)
enum MerossMethod: String, Codable, Hashable, Sendable {
    case get = "GET", set = "SET", push = "PUSH", getAck = "GETACK", setAck = "SETACK", error = "ERROR"
}

struct MerossHeader: Codable, Hashable, Sendable {
    let from: String
    let messageId: String
    let method: MerossMethod
    let namespace: String
    let payloadVersion: Int
    let sign: String
    let timestamp: Int
    let triggerSrc: String?
}

enum MerossReply: Hashable, Sendable {
    case ack(MerossJSON)
    case error(code: Int, detail: String)
}

/// Domain refusal by the device (distinct from transport failure).
enum MerossDeviceError: Error, Equatable, Sendable {
    case signature
    case code(Int, String)
    init(code: Int, detail: String) { self = code == 5001 ? .signature : .code(code, detail) }
}

struct MerossMessage: Codable, Hashable, Sendable {
    let header: MerossHeader
    let payload: MerossJSON

    /// sign = md5(messageId + key + timestamp), lowercase hex.
    static func sign(messageId: String, key: String, timestamp: Int) -> String {
        let digest = Insecure.MD5.hash(data: Data((messageId + key + String(timestamp)).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func request(method: MerossMethod, namespace: String, payload: MerossJSON, key: String,
                        now: Date = Date(), messageId: String? = nil) -> MerossMessage {
        let id = messageId ?? (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let timestamp = Int(now.timeIntervalSince1970)
        return MerossMessage(header: .init(from: "/app/lorisiot/subscribe", messageId: id, method: method,
                                           namespace: namespace, payloadVersion: 1,
                                           sign: sign(messageId: id, key: key, timestamp: timestamp),
                                           timestamp: timestamp, triggerSrc: "iOSLocal"),
                             payload: payload)
    }

    /// The device does not sign replies; correlation by messageId is the only integrity check.
    func reply(to request: MerossMessage) throws -> MerossReply {
        guard header.messageId == request.header.messageId else { throw IoTError.invalidResponse }
        switch header.method {
        case .getAck, .setAck: return .ack(payload)
        case .error:
            guard let code = payload["error"]?["code"]?.intValue else { throw IoTError.invalidResponse }
            return .error(code: code, detail: payload["error"]?["detail"]?.stringValue ?? "")
        case .get, .set, .push: throw IoTError.invalidResponse
        }
    }
}
#endif
