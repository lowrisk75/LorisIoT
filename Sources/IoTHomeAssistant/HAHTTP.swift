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
    private let token: @Sendable () async throws -> String
    private let maxBytes: Int
    private let client: BoundedHTTPClient

    public convenience init(baseURL: URL, token: String, maxBytes: Int = 4 * 1024 * 1024, session: URLSession? = nil) {
        self.init(baseURL: baseURL, tokenProvider: { token }, maxBytes: maxBytes, session: session)
    }

    public init(baseURL: URL, tokenProvider: @escaping @Sendable () async throws -> String,
                maxBytes: Int = 4 * 1024 * 1024, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.token = tokenProvider
        self.maxBytes = maxBytes
        self.client = BoundedHTTPClient(session: session)
    }

    public func send(method: String, path: String, body: Data?) async throws -> (Data, Int) {
        guard let origin = HTTPOrigin(baseURL),
              !path.hasPrefix("/"), !path.contains("://"), !path.split(separator: "/").contains(".."),
              let directory = URL(string: baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"),
              let url = URL(string: path, relativeTo: directory)?.absoluteURL,
              HTTPOrigin(url) == origin else { throw IoTError.notConfigured }
        // Decided before the token is even read: a bearer never crosses a public network in cleartext.
        guard origin.permitsCredentials else {
            throw IoTError.notSupported("Home Assistant over plain HTTP is only allowed on a private network")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        let bearer = try await token()
        guard !bearer.isEmpty, !bearer.contains("\r"), !bearer.contains("\n") else { throw IoTError.notConfigured }
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, response) = try await client.data(for: req, maxBytes: maxBytes, allowsSameOriginRedirects: true)
        return (data, response.statusCode)
    }

    /// Pin redirects to the same host + block HTTPS→HTTP downgrade (guards the bearer token).
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.flatMap(HTTPOrigin.init) == HTTPOrigin(baseURL) ? request : nil)
    }
}
