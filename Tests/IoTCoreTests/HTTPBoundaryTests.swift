import Foundation
import Testing
@testable import IoTCore

@Suite struct HTTPBoundaryTests {
    @Test func originIncludesSchemeAndEffectivePort() throws {
        let a = try #require(HTTPOrigin(URL(string: "https://ha.invalid")!))
        #expect(a == HTTPOrigin(URL(string: "https://ha.invalid:443/api")!))
        #expect(a != HTTPOrigin(URL(string: "https://ha.invalid:8443")!))
        #expect(a != HTTPOrigin(URL(string: "http://ha.invalid")!))
        #expect(HTTPOrigin(URL(string: "https://user:secret@ha.invalid")!) == nil)
    }

    /// Cleartext may carry credentials only where the path is private or already encrypted (tailnet).
    /// Strict policy: without TLS, credentials go only to private IP literals and mDNS `.local` names.
    /// A name resolved by the current network's DNS is not proof of a private route.
    @Test func cleartextCredentialsArePermittedOnlyToPrivateHosts() {
        for host in ["192.168.3.230", "10.0.0.5", "172.16.1.1", "172.31.255.254", "127.0.0.1", "169.254.1.1",
                     "::1", "[::1]", "fe80::1", "fd7a:115c:a1e0::1", "FE80::1%en0", "fe80::1%25en0",
                     "localhost", "homeassistant.local", "HomeAssistant.Local"] {
            #expect(HTTPOrigin.isPrivateHost(host), "\(host) should be private")
        }
        for host in ["example.com", "8.8.8.8", "172.32.0.1", "100.128.0.1", "192.169.0.1", "2001:db8::1",
                     "local.example.com", "ts.net.example.com", "homeassistant.local.evil.com",
                     // numeric single-label and non-canonical IPv4 forms resolve to arbitrary addresses
                     "134744072", "2130706433", "0x08080808", "0x7f000001", "010.0.0.1", "0127.0.0.1", "10.1",
                     // names are resolved by whatever DNS the current network provides
                     "homeassistant", "ha.lan", "box.internal", "ha.home.arpa", "homeassistant.fox-inconnu.ts.net",
                     // shared carrier space when the tailnet is not up
                     "100.64.0.1", "100.127.255.254",
                     // reserved ::/96 and mapped forms are not link-local or ULA
                     "::fe80:1", "::fc00:1", "::ffff:10.0.0.1", "::ffff:8.8.8.8",
                     // a zone that is not a plain interface name makes resolvers treat the literal as a name
                     "fe80::1%foo%bar", "fd00::1%25x%25y", "fc00::1%%", "fe80::1%", "fe80::1%a.example",
                     // brackets belong to IPv6 literals only; anywhere else a connector resolves them as a name
                     "[10.0.0.1]", "[mqtt.local]", "[localhost]", "[]",
                     "evil.com.", "10.0.0.1.", "", "."] {
            #expect(!HTTPOrigin.isPrivateHost(host), "\(host) should be public")
        }
    }

    @Test func unknownLengthResponseIsRejectedAtByteLimit() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OversizedResponseProtocol.self]
        let client = BoundedHTTPClient(session: URLSession(configuration: config))
        await #expect(throws: HTTPBoundaryError.responseTooLarge(limit: 16)) {
            _ = try await client.data(for: URLRequest(url: URL(string: "https://fixture.invalid")!), maxBytes: 16)
        }
    }
}

private final class OversizedResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 128))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
