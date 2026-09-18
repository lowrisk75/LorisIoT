import Foundation

public enum HTTPBoundaryError: Error, Sendable, Equatable {
    case invalidURL, invalidResponse, responseTooLarge(limit: Int)
}

/// A credential origin includes scheme and effective port, not just a matching hostname.
public struct HTTPOrigin: Hashable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int

    public init?(_ url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = c.host?.lowercased(), !host.isEmpty,
              c.user == nil, c.password == nil,
              c.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        self.scheme = scheme; self.host = host; self.port = c.port ?? (scheme == "https" ? 443 : 80)
    }

    /// Whether credentials may travel to this origin: always over HTTPS, over cleartext only to a
    /// private host where the path never crosses the public internet unencrypted.
    public var permitsCredentials: Bool { scheme == "https" || Self.isPrivateHost(host) }

    /// Strict: loopback, RFC 1918 and link-local IPv4 in canonical dotted-quad form; IPv6 loopback,
    /// link-local and ULA; `localhost` and mDNS `.local` names. Anything resolved by the current
    /// network's DNS (single-label, .lan, .internal, .home.arpa, .ts.net) and CGNAT space are refused,
    /// because a hostile network can route them publicly; numeric shorthands resolve anywhere.
    public static func isPrivateHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            // Brackets are only meaningful around an IPv6 literal; elsewhere connectors resolve them as a name.
            host = String(host.dropFirst().dropLast())
            guard host.contains(":") else { return false }
        }
        guard !host.isEmpty else { return false }
        if host.contains(":") { return isPrivateIPv6(host) }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) {
            // Only canonical dotted quads: no leading zeros, no shorthand, no hex.
            guard labels.count == 4, labels.allSatisfy({ $0 == "0" || !$0.hasPrefix("0") }) else { return false }
            let octets = labels.compactMap { UInt8($0) }
            guard octets.count == 4 else { return false }
            switch (octets[0], octets[1]) {
            case (10, _), (127, _), (172, 16...31), (192, 168), (169, 254): return true
            default: return false
            }
        }
        if host == "localhost" { return true }
        guard host.hasSuffix(".local"), labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        return labels.allSatisfy { $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }
    }

    /// Headers that cannot authenticate anyone. Every other header is treated as a possible credential.
    /// `Sec-WebSocket-Protocol` is deliberately absent: servers use it to carry bearer tokens.
    static let nonCredentialHeaders: Set<String> = ["accept", "user-agent"]
    public static func carriesCredentials(_ headers: [String: String]) -> Bool {
        headers.keys.contains { !nonCredentialHeaders.contains($0.lowercased()) }
    }

    private static func isPrivateIPv6(_ literal: String) -> Bool {
        let parts = literal.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        let address = String(parts[0])
        // A zone must be a plain interface name (or its `%25`-encoded form); anything else makes the
        // connector treat the whole literal as a name to resolve.
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        guard inet_pton(AF_INET6, address, &bytes) == 1 else { return false }
        if bytes == [UInt8](repeating: 0, count: 15) + [1] { return true }
        return (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) || bytes[0] & 0xfe == 0xfc
    }
}

/// Bounds bytes while receiving, cancels oversized bodies, and scopes redirects to one origin.
/// Uses an ephemeral session by default; callers may inject a session for protocol-fixture tests.
public struct BoundedHTTPClient: Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    public func data(for request: URLRequest, maxBytes: Int = 4 * 1024 * 1024,
                     allowsSameOriginRedirects: Bool = false) async throws -> (Data, HTTPURLResponse) {
        guard maxBytes > 0, let url = request.url, let origin = HTTPOrigin(url) else {
            throw HTTPBoundaryError.invalidURL
        }
        try Task.checkCancellation()
        let redirect = OriginRedirectDelegate(origin: origin, allowsRedirects: allowsSameOriginRedirects)
        let (bytes, response) = try await session.bytes(for: request, delegate: redirect)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw HTTPBoundaryError.invalidResponse }
        guard response.expectedContentLength <= Int64(maxBytes) else {
            throw HTTPBoundaryError.responseTooLarge(limit: maxBytes)
        }
        var result = Data()
        result.reserveCapacity(min(maxBytes, 16_384))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard result.count < maxBytes else { throw HTTPBoundaryError.responseTooLarge(limit: maxBytes) }
            result.append(byte)
        }
        return (result, http)
    }
}

private final class OriginRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let origin: HTTPOrigin
    let allowsRedirects: Bool
    init(origin: HTTPOrigin, allowsRedirects: Bool) { self.origin = origin; self.allowsRedirects = allowsRedirects }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(allowsRedirects && request.url.flatMap(HTTPOrigin.init) == origin ? request : nil)
    }
}
