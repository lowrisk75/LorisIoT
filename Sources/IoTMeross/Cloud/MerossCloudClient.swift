import Foundation
import IoTCore

#if canImport(Darwin)
public protocol MerossCloudClient: Sendable {
    func signIn(email: String, password: String, region: MerossRegion) async throws -> MerossAccount
    func devices(account: MerossAccount) async throws -> [MerossCloudDevice]
    func logout(account: MerossAccount) async throws
}

/// Talks to the user's own Meross account. The password is md5-hashed for transit, sent once, never kept.
public actor MerossCloudSession: MerossCloudClient {
    private let client: BoundedHTTPClient
    public init(session: URLSession? = nil) { client = BoundedHTTPClient(session: session) }

    public func signIn(email: String, password: String, region: MerossRegion) async throws -> MerossAccount {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, email.utf8.count <= 254, !password.isEmpty, password.utf8.count <= 256 else { throw IoTError.notConfigured }
        let params: [String: MerossJSON] = ["email": .string(email), "password": .string(MerossCloudRequest.md5Hex(password)),
                                            "encryption": .number(1), "agree": .number(1), "accountCountryCode": .string("--"),
                                            "mobileInfo": .object(["deviceModel": .string("iPhone"), "mobileOs": .string("iOS"),
                                                                   "mobileOsVersion": .string("17"), "uuid": .string(UUID().uuidString), "carrier": .string("")])]
        var baseURL = URL(string: region.rawValue)!
        for attempt in 0..<2 {
            let envelope = try await call(baseURL: baseURL, path: "/v1/Auth/signIn", params: params, token: nil)
            switch envelope.apiStatus {
            case MerossCloudEnvelope.ok:
                guard let response = MerossSignInResponse(data: envelope.data) else { throw IoTError.invalidResponse }
                return MerossAccount(userId: response.userid, key: response.key, token: response.token,
                                     domain: response.domain, mqttDomain: response.mqttDomain, email: response.email.isEmpty ? email : response.email)
            case MerossCloudEnvelope.redirectRegion:
                guard attempt == 0, let domain = envelope.data?["domain"]?.stringValue, let url = URL(string: domain),
                      url.scheme == "https", url.host?.hasSuffix(".meross.com") == true else { throw IoTError.invalidResponse }
                baseURL = url
            default:
                throw IoTError.authenticationFailed(reason: "meross:\(envelope.apiStatus)")
            }
        }
        throw IoTError.invalidResponse
    }

    public func devices(account: MerossAccount) async throws -> [MerossCloudDevice] {
        let envelope = try await call(baseURL: try domain(account), path: "/v1/Device/devList", params: [:], token: account.token)
        guard envelope.apiStatus == MerossCloudEnvelope.ok else { throw IoTError.authenticationFailed(reason: "meross:\(envelope.apiStatus)") }
        return MerossCloudDevice.list(from: envelope.data)
    }

    public func logout(account: MerossAccount) async throws {
        let envelope = try await call(baseURL: try domain(account), path: "/v1/Profile/logout", params: [:], token: account.token)
        guard envelope.apiStatus == MerossCloudEnvelope.ok else { throw IoTError.authenticationFailed(reason: "meross:\(envelope.apiStatus)") }
    }

    private func domain(_ account: MerossAccount) throws -> URL {
        // The same bound as a region redirect: the bearer token only goes to Meross over HTTPS.
        guard let url = URL(string: account.domain), url.scheme == "https", url.user == nil, url.password == nil,
              url.host?.lowercased().hasSuffix(".meross.com") == true else { throw IoTError.notConfigured }
        return url
    }

    private func call(baseURL: URL, path: String, params: [String: MerossJSON], token: String?) async throws -> MerossCloudEnvelope {
        let request = try MerossCloudRequest.build(baseURL: baseURL, path: path, params: params, token: token)
        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await client.data(for: request, maxBytes: 1024 * 1024) }
        catch is CancellationError { throw IoTError.cancelled }
        catch { throw IoTError.transport("Meross cloud unreachable") }
        guard (200..<300).contains(response.statusCode),
              let envelope = try? JSONDecoder().decode(MerossCloudEnvelope.self, from: data) else { throw IoTError.invalidResponse }
        return envelope
    }
}
#endif
