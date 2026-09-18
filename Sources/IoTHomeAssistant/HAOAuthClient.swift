import Foundation
import CryptoKit
import IoTCore

public enum HAOAuthError: Error, Sendable, Equatable {
    case invalidConfiguration, invalidCallback, authorizationExpired, signedOut, authorizationRejected, invalidResponse
}

/// Home Assistant's authorization-code flow. The app owns ASWebAuthenticationSession presentation.
/// Native redirect schemes must also be declared on the app's client-ID website per HA's contract.
public actor HAOAuthClient {
    private struct Tokens: Codable, Sendable {
        let access: String
        let refresh: String
        let expiresAt: Date
    }
    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
        let token_type: String
    }
    private let baseURL: URL
    private let clientID: URL
    private let redirectURI: URL
    private let store: any CredentialStore
    private let account: String
    private let http: BoundedHTTPClient
    private let now: @Sendable () -> Date
    private var pending: (state: String, expiresAt: Date)?
    private var refreshing: Task<Tokens, any Error>?
    private var generation: UInt64 = 0
    private var locallySignedOut = false
    private var storageTail: Task<Void, Never>?

    public init(baseURL: URL, clientID: URL, redirectURI: URL, store: any CredentialStore,
                session: URLSession? = nil, now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard let base = HAConfig.normalize(baseURL.absoluteString),
              HTTPOrigin(clientID)?.scheme == "https",
              clientID.query == nil, clientID.fragment == nil,
              let redirect = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false),
              redirect.scheme != nil, redirect.user == nil, redirect.password == nil,
              redirect.query == nil, redirect.fragment == nil else { throw HAOAuthError.invalidConfiguration }
        self.baseURL = base; self.clientID = clientID; self.redirectURI = redirectURI
        self.store = store; self.http = BoundedHTTPClient(session: session); self.now = now
        self.account = "ha.oauth." + SHA256.hash(data: Data((base.absoluteString + "\n" + clientID.absoluteString).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public func beginAuthorization() throws -> URL {
        generation &+= 1; refreshing?.cancel(); refreshing = nil
        let state = UUID().uuidString + UUID().uuidString
        pending = (state, now().addingTimeInterval(300))
        var url = URLComponents(url: baseURL.appendingPathComponent("auth/authorize"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "client_id", value: clientID.absoluteString),
                          URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
                          URLQueryItem(name: "state", value: state)]
        guard let result = url.url else { throw HAOAuthError.invalidConfiguration }
        return result
    }

    public func cancelAuthorization() {
        pending = nil; generation &+= 1; refreshing?.cancel(); refreshing = nil
    }

    public func finishAuthorization(callbackURL: URL) async throws {
        guard let request = pending else { throw HAOAuthError.invalidCallback }
        pending = nil // Single-use, including failed callbacks.
        guard now() < request.expiresAt else { throw HAOAuthError.authorizationExpired }
        guard var callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else { throw HAOAuthError.invalidCallback }
        let query = callback.queryItems ?? []; callback.query = nil
        guard callback.url == redirectURI, query.filter({ $0.name == "state" }).count == 1,
              query.first(where: { $0.name == "state" })?.value == request.state,
              query.filter({ $0.name == "code" }).count == 1,
              let code = query.first(where: { $0.name == "code" })?.value, !code.isEmpty,
              !query.contains(where: { $0.name == "error" }) else { throw HAOAuthError.invalidCallback }
        let token = generation
        let tokens = try await exchange(["grant_type": "authorization_code", "code": code], previousRefresh: nil)
        try await persist(tokens, generation: token)
        guard generation == token else { throw CancellationError() }
        locallySignedOut = false
    }

    public func accessToken() async throws -> String {
        guard !locallySignedOut else { throw HAOAuthError.signedOut }
        let token = generation
        if let refreshing { return try await refreshedAccess(refreshing, generation: token) }
        let store = store; let account = account
        guard let data = try await serializedStorage({ try await store.read(account: account) }).value else { throw HAOAuthError.signedOut }
        guard token == generation else { throw CancellationError() }
        if let refreshing { return try await refreshedAccess(refreshing, generation: token) }
        let tokens = try JSONDecoder().decode(Tokens.self, from: data)
        if tokens.expiresAt.timeIntervalSince(now()) > 60 { return tokens.access }
        let task = Task {
            let renewed = try await self.exchange(["grant_type": "refresh_token", "refresh_token": tokens.refresh],
                                                   previousRefresh: tokens.refresh)
            try await self.persist(renewed, generation: token)
            return renewed
        }
        refreshing = task
        do {
            let renewed = try await task.value
            guard token == generation else { throw CancellationError() }
            refreshing = nil; return renewed.access
        } catch {
            if token == generation {
                refreshing = nil
                if error as? HAOAuthError == .authorizationRejected {
                    try await serializedStorage {
                        guard await self.isCurrent(token) else { throw CancellationError() }
                        try await store.remove(account: account)
                    }.value
                }
            }
            throw error
        }
    }

    /// Clear local access immediately. A failed remote revocation is surfaced for the app to report.
    public func signOut(revoke: Bool = true) async throws {
        generation &+= 1; refreshing?.cancel(); refreshing = nil; pending = nil
        locallySignedOut = true
        let store = store; let account = account
        let data = try await serializedStorage {
            let data = try await store.read(account: account)
            try await store.remove(account: account)
            return data
        }.value
        guard revoke, let data, let tokens = try? JSONDecoder().decode(Tokens.self, from: data) else { return }
        let (_, response) = try await http.data(for: form(path: "auth/revoke", fields: ["token": tokens.refresh]), maxBytes: 65536)
        guard response.statusCode == 200 else { throw HAOAuthError.authorizationRejected }
    }

    private func exchange(_ fields: [String: String], previousRefresh: String?) async throws -> Tokens {
        var fields = fields; fields["client_id"] = clientID.absoluteString
        let (data, response) = try await http.data(for: form(path: "auth/token", fields: fields), maxBytes: 65536)
        guard (200...299).contains(response.statusCode) else {
            if [400, 401, 403].contains(response.statusCode) { throw HAOAuthError.authorizationRejected }
            throw IoTError.transport("Authorization service unavailable")
        }
        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data),
              Self.validToken(response.access_token), response.token_type.lowercased() == "bearer",
              response.expires_in.isFinite, response.expires_in > 0, response.expires_in <= 31_536_000,
              let refresh = response.refresh_token ?? previousRefresh, Self.validToken(refresh) else { throw HAOAuthError.invalidResponse }
        return Tokens(access: response.access_token, refresh: refresh, expiresAt: now().addingTimeInterval(response.expires_in))
    }

    private static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private func isCurrent(_ token: UInt64) -> Bool { token == generation }

    private func refreshedAccess(_ task: Task<Tokens, any Error>, generation token: UInt64) async throws -> String {
        let result = try await task.value
        try Task.checkCancellation()
        guard token == generation, !locallySignedOut else { throw HAOAuthError.signedOut }
        return result.access
    }

    /// Serialize storage across actor suspension points. A late login/refresh cannot write after logout.
    private func serializedStorage<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) -> Task<Value, any Error> {
        let previous = storageTail
        let task = Task { await previous?.value; return try await operation() }
        storageTail = Task { _ = try? await task.value }
        return task
    }

    private func persist(_ tokens: Tokens, generation token: UInt64) async throws {
        let data = try JSONEncoder().encode(tokens)
        let store = store; let account = account
        try await serializedStorage {
            guard await self.isCurrent(token) else { throw CancellationError() }
            let previous = try await store.read(account: account)
            guard await self.isCurrent(token) else { throw CancellationError() }
            try await store.write(data, account: account)
            guard await self.isCurrent(token) else {
                // Preserve the pre-login account on cancellation; a queued logout removes it next.
                if let previous { try await store.write(previous, account: account) }
                else { try await store.remove(account: account) }
                throw CancellationError()
            }
        }.value
    }

    private func form(path: String, fields: [String: String]) -> URLRequest {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = fields.keys.sorted().map {
            "\($0.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(fields[$0]!.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"; request.timeoutInterval = 15
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return request
    }
}
