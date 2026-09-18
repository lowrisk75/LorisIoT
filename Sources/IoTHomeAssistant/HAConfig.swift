import Foundation
import IoTCore

/// User-supplied Home Assistant connection. `baseURL` may be a LAN URL (`http://homeassistant.local:8123`)
/// or a remote one (Nabu Casa `https://….ui.nabu.casa`, or a Tailscale host). The long-lived token
/// (or OAuth access token) is fetched from the Keychain via `KeychainStore` — never stored here.
public struct HAConfig: Sendable, Equatable {
    public let baseURL: URL
    /// Keychain account under which the bearer token is stored.
    public let tokenAccount: String

    public init(baseURL: URL, tokenAccount: String = "homeAssistantToken") {
        self.baseURL = baseURL
        self.tokenAccount = tokenAccount
    }

    /// Normalize a user-typed host/URL: default to https, strip trailing slash. Honours explicit http://.
    public static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasSuffix("/") { s.removeLast() }
        if !s.contains("://") { s = "https://" + s }
        guard var c = URLComponents(string: s),
              let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        // Explicit http:// is honoured only where the token cannot cross a public network in cleartext.
        guard scheme == "https" || HTTPOrigin.isPrivateHost(host) else { return nil }
        c.scheme = scheme
        return c.url
    }

    /// The `ws(s)://…/api/websocket` URL derived from `baseURL`.
    public var websocketURL: URL? {
        guard Self.normalize(baseURL.absoluteString) != nil else { return nil }
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        comps?.scheme = (baseURL.scheme?.lowercased() == "http") ? "ws" : "wss"
        let prefix = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        comps?.path = prefix.isEmpty ? "/api/websocket" : "/\(prefix)/api/websocket"
        return comps?.url
    }
}
