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

/// One device as reported by the Shelly Cloud account (for the "import from cloud" picker). `id` is
/// the cloud device id (lowercased, no separators — same value used as the control `deviceID`).
public struct ShellyCloudDevice: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let type: String     // model code, e.g. "SHPLG-S", "SNSW-001X16EU"
    public let online: Bool
    public init(id: String, name: String, type: String, online: Bool) {
        self.id = id; self.name = name; self.type = type; self.online = online
    }
    /// Never-empty label for UI.
    public var displayName: String { name.isEmpty ? id : name }
}

/// Shelly **Cloud** Control API v2 — remote on/off only (no scheduling). Used as a fallback when the
/// device isn't reachable on the LAN. Ported from Velya `ShellyCloudClient`.
public enum ShellyCloudClient {

    /// Normalise a user-entered cloud server (strip scheme + trailing slashes). Empty → nil.
    static func normalizedHost(_ server: String) -> String? {
        var s = server.trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return s.isEmpty ? nil : s
    }

    /// Enumerate the account's devices via `POST /interface/device/list` (form `auth_key`). Returns
    /// `[]` on any auth/transport/parse failure — the picker treats empty as "nothing to import,
    /// check your key". Parsing is tolerant: Shelly nests devices under `data.devices` keyed by id.
    public static func listDevices(server: String, authKey: String) async -> [ShellyCloudDevice] {
        guard let host = normalizedHost(server), !authKey.isEmpty,
              let url = URL(string: "https://\(host)/interface/device/list") else { return [] }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 12
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let escaped = authKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? authKey
        r.httpBody = Data("auth_key=\(escaped)".utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["isok"] as? Bool) != false,
              let container = root["data"] as? [String: Any],
              let devices = container["devices"] as? [String: Any] else { return [] }

        return devices.compactMap { id, raw -> ShellyCloudDevice? in
            let d = raw as? [String: Any] ?? [:]
            let name = (d["name"] as? String) ?? ""
            let type = (d["type"] as? String) ?? (d["code"] as? String) ?? ""
            // `online` is 1/0 or bool depending on firmware; absent → assume reachable.
            let online: Bool = {
                if let b = d["online"] as? Bool { return b }
                if let n = d["online"] as? Int { return n != 0 }
                return true
            }()
            return ShellyCloudDevice(id: id.lowercased(), name: name, type: type, online: online)
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

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
