import Foundation
import CryptoKit
import IoTCore

/// Versioned, signed automation payload for Node-RED / generic webhooks. `v` lets flows evolve
/// without breaking; `eventId` gives idempotency; `ts` gives replay protection.
public struct WebhookPayload: Codable, Sendable, Hashable {
    public let v: Int
    public let eventId: String
    public let ts: Int              // unix seconds
    public let action: String
    public let device: String?
    public let params: [String: String]
    public init(v: Int = 1, eventId: String, ts: Int, action: String, device: String? = nil, params: [String: String] = [:]) {
        self.v = v; self.eventId = eventId; self.ts = ts; self.action = action; self.device = device; self.params = params
    }
}

public enum WebhookError: Error, Sendable, Equatable { case insecureURL, http(Int), transport }

/// Injectable HTTP seam (testable without network).
public protocol WebhookHTTP: Sendable {
    func post(url: URL, body: Data, headers: [String: String]) async throws -> Int
}

/// Signs and delivers a `WebhookPayload`. Fail-closed: HTTPS-only, no userinfo/query/fragment (the
/// secret never rides in the URL). Body is HMAC-SHA256 signed; the flow verifies signature + a fresh
/// timestamp. Idempotency via `eventId` so a retry can't double-fire.
public struct WebhookClient: Sendable {
    private let secret: SymmetricKey
    private let http: WebhookHTTP

    public init(secret: String, http: WebhookHTTP) {
        self.secret = SymmetricKey(data: Data(secret.utf8))
        self.http = http
    }

    /// HMAC-SHA256 of `body`, lowercase hex — the value for `X-LorisIoT-Signature: sha256=…`.
    public static func signature(body: Data, secret: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Fail-closed policy: only https, no credentials/query/fragment (matches Velya OutboundURLPolicy).
    public static func safeURL(_ raw: String) -> URL? {
        guard var c = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "https", c.host?.isEmpty == false,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { return nil }
        c.scheme = "https"
        return c.url
    }

    /// Deliver the payload (retryable — `eventId` makes it idempotent). Throws on insecure URL or non-2xx.
    public func send(_ payload: WebhookPayload, to rawURL: String) async throws {
        guard let url = Self.safeURL(rawURL) else { throw WebhookError.insecureURL }
        let body = try JSONEncoder().encode(payload)
        let sig = HMAC<SHA256>.authenticationCode(for: body, using: secret).map { String(format: "%02x", $0) }.joined()
        let headers = [
            "Content-Type": "application/json",
            "X-LorisIoT-Signature": "sha256=\(sig)",
            "X-LorisIoT-Timestamp": String(payload.ts),
        ]
        let status = try await http.post(url: url, body: body, headers: headers)
        guard (200...299).contains(status) else { throw WebhookError.http(status) }
    }
}

/// Production `WebhookHTTP` over URLSession (bounded, no cookies).
public struct WebhookURLSessionHTTP: WebhookHTTP {
    public init() {}
    public func post(url: URL, body: Data, headers: [String: String]) async throws -> Int {
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 12; r.httpBody = body
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let cfg = URLSessionConfiguration.ephemeral; cfg.httpCookieStorage = nil
        guard let (_, resp) = try? await URLSession(configuration: cfg).data(for: r),
              let http = resp as? HTTPURLResponse else { throw WebhookError.transport }
        return http.statusCode
    }
}
