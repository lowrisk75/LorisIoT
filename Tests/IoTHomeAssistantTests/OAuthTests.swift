import Foundation
import Testing
@testable import IoTHomeAssistant
import IoTCore

@Suite struct HAOAuthTests {
    private func client(store: any CredentialStore = MemoryCredentialStore()) throws -> HAOAuthClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OAuthFixture.self]
        return try HAOAuthClient(baseURL: URL(string: "https://ha.test")!,
            clientID: URL(string: "https://app.test")!, redirectURI: URL(string: "testapp://ha/callback")!,
            store: store, session: URLSession(configuration: config))
    }
    private func callback(_ url: URL, stateOverride: String? = nil) -> URL {
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        var c = URLComponents(string: "testapp://ha/callback")!
        c.queryItems = [URLQueryItem(name: "state", value: stateOverride ?? state),
                        URLQueryItem(name: "code", value: "a+b&=code")]
        return c.url!
    }
    @Test func stateAndCallbackAreSingleUse() async throws {
        let client = try client()
        let url = try await client.beginAuthorization()
        await #expect(throws: HAOAuthError.invalidCallback) {
            try await client.finishAuthorization(callbackURL: callback(url, stateOverride: "attacker"))
        }
        await #expect(throws: HAOAuthError.invalidCallback) {
            try await client.finishAuthorization(callbackURL: callback(url))
        }
    }
    @Test func authorizationRefreshAndSignOut() async throws {
        let client = try client()
        try await client.finishAuthorization(callbackURL: callback(try await client.beginAuthorization()))
        // Initial token expires in one second. All callers must converge on the renewed token.
        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 { group.addTask { try await client.accessToken() } }
            var values: [String] = []; for try await value in group { values.append(value) }; return values
        }
        #expect(values == Array(repeating: "renewed-fixture", count: 12))
        try await client.signOut()
        await #expect(throws: HAOAuthError.signedOut) { try await client.accessToken() }
    }
    @Test func rejectsCredentialBearingServerAndInsecureClientID() {
        #expect(throws: HAOAuthError.invalidConfiguration) {
            try HAOAuthClient(baseURL: URL(string: "https://user:pass@ha.test")!,
                clientID: URL(string: "https://app.test")!, redirectURI: URL(string: "testapp://ha/callback")!,
                store: MemoryCredentialStore())
        }
    }

    @Test func logoutCannotBeUndoneByAnAuthorizationWriteAlreadyInProgress() async throws {
        let store = SuspendedCredentialStore()
        let client = try client(store: store)
        let callback = callback(try await client.beginAuthorization())
        let authorization = Task { try await client.finishAuthorization(callbackURL: callback) }
        await store.waitForWrite()
        let logout = Task { try await client.signOut(revoke: false) }
        // Give the independent logout task a chance to enqueue while the write is explicitly held.
        try await Task.sleep(for: .milliseconds(30))
        await store.releaseWrite()
        _ = await authorization.result
        try await logout.value
        #expect(await store.isEmpty)
        await #expect(throws: HAOAuthError.signedOut) { try await client.accessToken() }
    }
}

private actor SuspendedCredentialStore: CredentialStore {
    private var data: Data?
    private var blocked = false
    private var write: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    var isEmpty: Bool { data == nil }
    func read(account: String) -> Data? { data }
    func write(_ value: Data, account: String) async {
        if !blocked {
            blocked = true
            await withCheckedContinuation { continuation in
                write = continuation; observer?.resume(); observer = nil
            }
        }
        data = value
    }
    func remove(account: String) { data = nil }
    func waitForWrite() async {
        if blocked { return }
        await withCheckedContinuation { observer = $0 }
    }
    func releaseWrite() { write?.resume(); write = nil }
}

private final class OAuthFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }
                body.append(contentsOf: bytes.prefix(n))
            }
        }
        let form = String(data: body, encoding: .utf8) ?? ""
        let json: String
        if request.url?.path == "/auth/revoke" { json = "" }
        else if form.contains("grant_type=refresh_token") {
            json = #"{"access_token":"renewed-fixture","expires_in":1800,"token_type":"Bearer"}"#
        } else if form.contains("code=a%2Bb%26%3Dcode") {
            json = #"{"access_token":"initial-fixture","refresh_token":"refresh-fixture","expires_in":1,"token_type":"Bearer"}"#
        } else { json = "{}" }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
