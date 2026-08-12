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
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") { s = "https://" + s }
        return URL(string: s)
    }

    /// The `ws(s)://…/api/websocket` URL derived from `baseURL`.
    public var websocketURL: URL? {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        comps?.scheme = (baseURL.scheme == "http") ? "ws" : "wss"
        comps?.path = "/api/websocket"
        return comps?.url
    }
}
