import Foundation
import IoTCore

/// Production `ShellyRPC` over `URLSession`: `POST http://<host>/rpc`, digest-auth retry on 401,
/// bounded timeout. LAN cleartext → needs `NSAllowsLocalNetworking`.
public struct ShellyURLSessionRPC: ShellyRPC {
    public init() {}

    public func call(host: String, password: String?, method: String,
                     params: [String: any Sendable]) async throws -> [String: any Sendable] {
        guard let url = URL(string: "http://\(host)/rpc") else { throw IoTError.notConfigured }
        let body: [String: Any] = ["id": 1, "method": method, "params": params]
        let payload = try JSONSerialization.data(withJSONObject: body)

        func makeRequest(auth: String?) -> URLRequest {
            var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 8
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let auth { r.setValue(auth, forHTTPHeaderField: "Authorization") }
            r.httpBody = payload
            return r
        }

        var (data, response) = try await URLSession.shared.data(for: makeRequest(auth: nil))
        var http = response as? HTTPURLResponse
        if http?.statusCode == 401, let password,
           let challenge = http?.value(forHTTPHeaderField: "WWW-Authenticate"),
           let header = ShellyDigest.header(challenge: challenge, password: password) {
            (data, response) = try await URLSession.shared.data(for: makeRequest(auth: header))
            http = response as? HTTPURLResponse
        }
        guard let status = http?.statusCode else { throw IoTError.invalidResponse }
        guard (200...299).contains(status) else {
            throw status == 401 ? IoTError.authenticationFailed(reason: "digest") : IoTError.transport("HTTP \(status)")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let err = json["error"] as? [String: Any] {
            throw IoTError.transport((err["message"] as? String) ?? "RPC error")
        }
        return (json["result"] as? [String: any Sendable]) ?? [:]
    }
}

/// Shelly **Cloud** Control API v2 — remote on/off only (no scheduling). Used as a fallback when the
/// device isn't reachable on the LAN. Ported from Velya `ShellyCloudClient`.
public enum ShellyCloudClient {
    public static func setSwitch(server: String, authKey: String, deviceID: String, channel: Int, on: Bool) async -> Bool {
        var hostStr = server.trimmingCharacters(in: .whitespaces)
        if let r = hostStr.range(of: "://") { hostStr = String(hostStr[r.upperBound...]) }
        hostStr = hostStr.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !hostStr.isEmpty, !authKey.isEmpty, !deviceID.isEmpty,
              let url = URL(string: "https://\(hostStr)/v2/devices/api/set/switch?auth_key=\(authKey)") else { return false }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 10
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["id": deviceID, "channel": channel, "on": on])
        guard let (_, resp) = try? await URLSession.shared.data(for: r), let http = resp as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }
}
