import Foundation
import CryptoKit
import IoTCore

// MARK: - Injectable RPC transport (so ShellyClient is unit-testable with fixtures)

/// One JSON-RPC round trip to `http://<host>/rpc`. The URLSession impl handles digest auth + timeouts;
/// tests provide canned responses.
public protocol ShellyRPC: Sendable {
    func call(host: String, password: String?, method: String, params: [String: any Sendable]) async throws -> [String: any Sendable]
}

public struct ShellyInfo: Sendable, Equatable {
    public let name: String
    public let model: String
    public let generation: Int
    public let mac: String        // lowercased = cloud id
    public let switchCount: Int
}

/// Local Shelly Gen2/3 client over LAN JSON-RPC. Gen1 (URL HTTP) is handled by a separate path when
/// probed as gen 1. Ported from Velya `ShellyClient`.
public actor ShellyClient {
    private let host: String
    private let password: String?
    private let rpc: ShellyRPC

    public init(host: String, password: String? = nil, rpc: ShellyRPC) {
        self.host = host
        self.password = (password?.isEmpty == false) ? password : nil
        self.rpc = rpc
    }

    public func probe() async throws -> ShellyInfo {
        let info = try await rpc.call(host: host, password: password, method: "Shelly.GetDeviceInfo", params: [:])
        let name = (info["name"] as? String) ?? (info["id"] as? String) ?? "Shelly"
        let model = (info["model"] as? String) ?? (info["app"] as? String) ?? ""
        let gen = (info["gen"] as? Int) ?? 2
        let mac = ((info["mac"] as? String) ?? "").lowercased()
        let switches = try await switchCount()
        return ShellyInfo(name: name, model: model, generation: gen, mac: mac, switchCount: max(1, switches))
    }

    /// Discover available RPC methods for THIS device (Shelly.ListMethods) — feeds capability discovery.
    public func listMethods() async -> Set<String> {
        guard let r = try? await rpc.call(host: host, password: password, method: "Shelly.ListMethods", params: [:]),
              let methods = r["methods"] as? [String] else { return [] }
        return Set(methods)
    }

    private func switchCount() async throws -> Int {
        guard let r = try? await rpc.call(host: host, password: password, method: "Shelly.GetComponents",
                                          params: ["dynamic_only": false]),
              let comps = r["components"] as? [[String: any Sendable]] else { return 1 }
        let n = comps.compactMap { $0["key"] as? String }.filter { $0.hasPrefix("switch:") }.count
        return n == 0 ? 1 : n
    }

    /// Current relay state, nil if unknown.
    public func switchState(id: Int) async -> Bool? {
        guard let r = try? await rpc.call(host: host, password: password, method: "Switch.GetStatus", params: ["id": id]) else { return nil }
        return r["output"] as? Bool
    }

    @discardableResult
    public func setSwitch(id: Int, on: Bool) async -> Bool {
        ((try? await rpc.call(host: host, password: password, method: "Switch.Set", params: ["id": id, "on": on])) != nil)
    }

    /// Install a daily on/off schedule (Shelly cron has no one-shot date). Returns the job id to track.
    public func createDailySchedule(switchID: Int, on: Bool, hour: Int, minute: Int) async -> Int? {
        let inner: [String: any Sendable] = ["id": switchID, "on": on]
        let call: [String: any Sendable] = ["method": "Switch.Set", "params": inner]
        let calls: [[String: any Sendable]] = [call]
        let params: [String: any Sendable] = ["enable": true, "timespec": Self.timespec(hour: hour, minute: minute), "calls": calls]
        guard let r = try? await rpc.call(host: host, password: password, method: "Schedule.Create", params: params) else { return nil }
        return r["id"] as? Int
    }

    public func deleteSchedule(jobID: Int) async {
        _ = try? await rpc.call(host: host, password: password, method: "Schedule.Delete", params: ["id": jobID])
    }

    /// Shelly cron timespec: "sec min hour dom mon dow". Daily at HH:MM:00.
    public static func timespec(hour: Int, minute: Int) -> String { "0 \(minute) \(hour) * * *" }
}

// MARK: - Digest (SHA-256) auth — pure, unit-testable

public enum ShellyDigest {
    /// Gen2 digest: username fixed `admin`, HA2 = SHA256("dummy_method:dummy_uri").
    public static func header(challenge: String, password: String, cnonce: String = randomHex(16)) -> String? {
        let f = parseChallenge(challenge)
        guard let realm = f["realm"], let nonce = f["nonce"] else { return nil }
        let ha1 = sha256Hex("admin:\(realm):\(password)")
        let ha2 = sha256Hex("dummy_method:dummy_uri")
        let nc = "00000001"
        let response = sha256Hex("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
        return "Digest username=\"admin\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"/rpc\", "
            + "algorithm=SHA-256, qop=auth, nc=\(nc), cnonce=\"\(cnonce)\", response=\"\(response)\""
    }

    public static func parseChallenge(_ challenge: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in challenge.replacingOccurrences(of: "Digest ", with: "").components(separatedBy: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    public static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func randomHex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
