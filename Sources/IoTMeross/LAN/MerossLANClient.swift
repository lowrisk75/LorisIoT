import Foundation
import IoTCore

#if canImport(Darwin)
protocol MerossLANClient: Sendable {
    func exchange(_ request: MerossMessage, host: String) async throws -> MerossMessage
}

/// One HTTP POST per exchange to `http://<host>/config`. Cleartext by protocol design; the app must
/// declare a local-networking ATS exception. Bodies are bounded to 256 KiB.
public struct MerossLANTransport: MerossLANClient {
    public enum Failure: Error, Equatable, Sendable { case invalidHost, http(Int), oversize, malformed }
    private let client: BoundedHTTPClient
    private let timeout: TimeInterval

    public init(session: URLSession? = nil, timeout: TimeInterval = 4) {
        if let session { client = BoundedHTTPClient(session: session) }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCache = nil
            config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout + 2
            config.waitsForConnectivity = false
            client = BoundedHTTPClient(session: URLSession(configuration: config))
        }
        self.timeout = timeout
    }

    static func url(host: String) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 253,
              !trimmed.contains("/"), !trimmed.contains("@"), !trimmed.contains(":"), !trimmed.contains(" ") else { return nil }
        return URL(string: "http://" + trimmed + "/config")
    }

    func exchange(_ request: MerossMessage, host: String) async throws -> MerossMessage {
        guard let url = Self.url(host: host) else { throw Failure.invalidHost }
        var http = URLRequest(url: url)
        http.httpMethod = "POST"
        http.timeoutInterval = timeout
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.httpBody = try JSONEncoder().encode(request)
        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await client.data(for: http, maxBytes: 256 * 1024) }
        catch HTTPBoundaryError.responseTooLarge { throw Failure.oversize }
        guard (200..<300).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
        guard let message = try? JSONDecoder().decode(MerossMessage.self, from: data) else { throw Failure.malformed }
        return message
    }
}
#endif
