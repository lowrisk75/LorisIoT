import Foundation
import IoTCore

/// Injectable HTTP seam so `HARestClient` is unit-testable with fixtures (no network). Returns the
/// body + HTTP status. Path is relative to the HA base URL (e.g. "api/states/light.kitchen").
public protocol HAHTTP: Sendable {
    func send(method: String, path: String, body: Data?) async throws -> (Data, Int)
}

/// Production `HAHTTP` over `URLSession`: bearer auth, bounded timeouts, ephemeral session, and a
/// byte-capped read so a huge `/api/states` payload can't blow memory. Redirects are pinned to the
/// same host to prevent a malicious `Location:` exfiltrating the token.
public final class HAURLSessionHTTP: NSObject, HAHTTP, URLSessionTaskDelegate, @unchecked Sendable {
    private let baseURL: URL
    private let token: String
    private let maxBytes: Int
    private let session: URLSession

    public init(baseURL: URL, token: String, maxBytes: Int = 4 * 1024 * 1024) {
        self.baseURL = baseURL
        self.token = token
        self.maxBytes = maxBytes
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12      // don't inherit the 60s default (cellular/Tailscale stalls)
        cfg.timeoutIntervalForResource = 20
        cfg.httpCookieStorage = nil
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg)
    }

    public func send(method: String, path: String, body: Data?) async throws -> (Data, Int) {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw IoTError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, response) = try await session.data(for: req, delegate: self)
        guard let http = response as? HTTPURLResponse else { throw IoTError.invalidResponse }
        let capped = data.count > maxBytes ? data.prefix(maxBytes) : data
        return (Data(capped), http.statusCode)
    }

    /// Pin redirects to the same host + block HTTPS→HTTP downgrade (guards the bearer token).
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        let sameHost = request.url?.host == baseURL.host
        let noDowngrade = !(baseURL.scheme == "https" && request.url?.scheme == "http")
        completionHandler(sameHost && noDowngrade ? request : nil)
    }
}
