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
/// the lowercased response-map key, reused unchanged as the control `deviceID`.
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

/// Injectable HTTP seam for Shelly Cloud. Keeping the secret-bearing request behind this boundary
/// makes URL construction and response parsing fixture-testable without contacting an account.
protocol ShellyCloudHTTP: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Ephemeral, cookie-free Cloud transport. Redirects are rejected because both Cloud endpoints
/// carry the authorization key and must never replay it to a different authority.
final class ShellyCloudURLSessionHTTP: NSObject, ShellyCloudHTTP, URLSessionTaskDelegate, @unchecked Sendable {
    private let maxResponseBytes: Int
    private let session: URLSession

    init(maxResponseBytes: Int = 1024 * 1024) {
        self.maxResponseBytes = maxResponseBytes
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        self.session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request, delegate: self)
        guard let http = response as? HTTPURLResponse, data.count <= maxResponseBytes else {
            throw IoTError.invalidResponse
        }
        return (data, http)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Shelly **Cloud** Control API v2 — remote on/off only (no scheduling). Used as a fallback when the
/// device isn't reachable on the LAN. Ported from Velya `ShellyCloudClient`.
public enum ShellyCloudClient {

    /// Accept only a bare Shelly tenant host or its HTTPS URI. Reject credentials, custom ports,
    /// paths, queries and fragments so an authorization key cannot be redirected by crafted input.
    static func normalizedHost(_ server: String) -> String? {
        let value = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let candidate = value.contains("://") ? value : "https://\(value)"
        guard let components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              let rawHost = components.host, !rawHost.isEmpty,
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        let host = rawHost.lowercased()
        guard host == "shelly.cloud" || host.hasSuffix(".shelly.cloud") else { return nil }
        return host
    }

    private static func endpoint(host: String, path: String,
                                 queryItems: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        if queryItems.isEmpty {
            components.percentEncodedQuery = nil
        } else {
            guard let query = formQuery(queryItems) else { return nil }
            components.percentEncodedQuery = query
        }
        return components.url
    }

    private static func formQuery(_ items: [URLQueryItem]) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        var pairs: [String] = []
        for item in items {
            guard let name = item.name.addingPercentEncoding(withAllowedCharacters: allowed),
                  let value = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) else {
                return nil
            }
            pairs.append("\(name)=\(value)")
        }
        return pairs.joined(separator: "&")
    }

    private static func formBody(_ items: [URLQueryItem]) -> Data? {
        formQuery(items).map { Data($0.utf8) }
    }

    /// Compatibility API for callers that intentionally collapse Cloud failures to an empty list.
    public static func listDevices(server: String, authKey: String) async -> [ShellyCloudDevice] {
        (try? await fetchDevices(server: server, authKey: authKey)) ?? []
    }

    static func listDevices(server: String, authKey: String,
                            http: any ShellyCloudHTTP) async -> [ShellyCloudDevice] {
        (try? await fetchDevices(server: server, authKey: authKey, http: http)) ?? []
    }

    /// Enumerate the account's devices via `POST /interface/device/list` (form `auth_key`). Unlike
    /// `listDevices`, this API preserves configuration, authentication, transport and parse errors
    /// so a consumer can distinguish a genuinely empty account from a failed request.
    public static func fetchDevices(server: String, authKey: String) async throws -> [ShellyCloudDevice] {
        try await fetchDevices(server: server, authKey: authKey, http: ShellyCloudURLSessionHTTP())
    }

    static func fetchDevices(server: String, authKey: String,
                             http: any ShellyCloudHTTP) async throws -> [ShellyCloudDevice] {
        guard let host = normalizedHost(server), !authKey.isEmpty,
              let url = endpoint(host: host, path: "/interface/device/list"),
              let body = formBody([URLQueryItem(name: "auth_key", value: authKey)]) else {
            throw IoTError.notConfigured
        }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 12
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.data(for: r)
        } catch {
            throw IoTError.transport("Shelly Cloud request failed")
        }
        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw IoTError.authenticationFailed(reason: "Shelly Cloud")
            }
            throw IoTError.transport("Shelly Cloud HTTP \(response.statusCode)")
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["isok"] as? Bool == true,
              let container = root["data"] as? [String: Any],
              let devices = container["devices"] as? [String: Any] else {
            throw IoTError.invalidResponse
        }

        return devices.compactMap { id, raw -> ShellyCloudDevice? in
            guard !id.isEmpty, let d = raw as? [String: Any] else { return nil }
            let name = (d["name"] as? String) ?? ""
            let type = (d["type"] as? String) ?? (d["code"] as? String) ?? ""
            // `online` is 1/0 or bool depending on firmware; absent or malformed → fail closed.
            let online: Bool = {
                if let b = d["online"] as? Bool { return b }
                if let n = d["online"] as? Int { return n != 0 }
                return false
            }()
            return ShellyCloudDevice(id: id.lowercased(), name: name, type: type, online: online)
        }.sorted {
            let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    public static func setSwitch(server: String, authKey: String, deviceID: String, channel: Int, on: Bool) async -> Bool {
        await setSwitch(server: server, authKey: authKey, deviceID: deviceID,
                        channel: channel, on: on, http: ShellyCloudURLSessionHTTP())
    }

    static func setSwitch(server: String, authKey: String, deviceID: String, channel: Int, on: Bool,
                          http: any ShellyCloudHTTP) async -> Bool {
        guard let host = normalizedHost(server), !authKey.isEmpty, !deviceID.isEmpty,
              let url = endpoint(host: host, path: "/v2/devices/api/set/switch",
                                 queryItems: [URLQueryItem(name: "auth_key", value: authKey)]) else { return false }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 10
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["id": deviceID, "channel": channel, "on": on])
        guard let (_, response) = try? await http.data(for: r) else { return false }
        return (200...299).contains(response.statusCode)
    }
}
