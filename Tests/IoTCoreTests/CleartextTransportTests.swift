import Foundation
import Testing
@testable import IoTCore

/// Credential headers (Basic, Cookie, CF-Access…) follow the same strict cleartext policy as tokens.
@Suite struct CleartextTransportTests {
    #if canImport(Network)
    @Test func rawWebSocketRefusesCredentialHeadersToAPublicHost() async {
        let transport = RawTCPWebSocketTransport(url: URL(string: "http://192.0.2.1:9/ws")!,
                                                 extraHeaders: ["Authorization": "Basic Zml4dHVyZQ=="], connectTimeout: 1)
        do {
            try await transport.open()
            Issue.record("opened a cleartext credentialed socket to a public host")
        } catch let error as IoTError {
            guard case .notSupported = error else { Issue.record("refused for the wrong reason: \(error)"); return }
        } catch { Issue.record("refused for the wrong reason: \(error)") }
    }

    /// A query string or a subprotocol can carry a token just as well as an Authorization header.
    @Test func rawWebSocketTreatsQueryAndSubprotocolAsCredentials() async {
        let cases: [(String, [String: String])] = [
            ("http://192.0.2.1:9/ws?token=fixture", [:]),
            ("http://192.0.2.1:9/ws", ["Sec-WebSocket-Protocol": "bearer.fixture"]),
        ]
        for (url, headers) in cases {
            let transport = RawTCPWebSocketTransport(url: URL(string: url)!, extraHeaders: headers, connectTimeout: 1)
            do {
                try await transport.open()
                Issue.record("opened \(url)")
            } catch let error as IoTError {
                guard case .notSupported = error else { Issue.record("\(url) refused for the wrong reason: \(error)"); continue }
            } catch { Issue.record("\(url) refused for the wrong reason: \(error)") }
        }
    }

    @Test func probeHeadRequestKeepsThePortAndTheEncodedPath() throws {
        let head = try #require(AdaptiveLatencyProber.headRequest(for: URL(string: "http://192.168.1.2:8123/api%20v1/health")!, headers: [:]))
        #expect(head.hasPrefix("HEAD /api%20v1/health HTTP/1.1\r\n"))
        #expect(head.contains("Host: 192.168.1.2:8123\r\n"))
    }

    @Test func probeHeaderNamesMustBeHTTPTokens() {
        for name in ["Host ", ": x", "", "X Y", "X-Ünicode"] {
            #expect(AdaptiveLatencyProber.headRequest(for: URL(string: "http://192.168.1.2/health")!, headers: [name: "v"]) == nil,
                     "\(name) accepted")
        }
        #expect(AdaptiveLatencyProber.headRequest(for: URL(string: "http://192.168.1.2/health")!, headers: ["X-Probe_1": "v"]) != nil)
    }

    @Test func probeHeadRequestBracketsAnIPv6Host() throws {
        let head = try #require(AdaptiveLatencyProber.headRequest(for: URL(string: "http://[fd00::1]:8123/health")!, headers: [:]))
        #expect(head.contains("Host: [fd00::1]:8123\r\n"))
        guard case .ipv6 = AdaptiveLatencyProber.connectHost(for: URL(string: "http://[fe80::1%25en0]:8123/health")!) else {
            Issue.record("a scoped IPv6 probe target became a name"); return
        }
    }

    @Test func anOutOfRangePortIsUnreachableNotACrash() async {
        let prober = AdaptiveLatencyProber(healthPath: "health")
        #expect(await prober.probe(IoTEndpoint(id: "a", url: URL(string: "http://192.168.1.2:70000")!)) == nil)
    }

    /// URLComponents keeps IPv6 brackets; handed on as-is they become a name to resolve, not the checked address.
    @Test func rawWebSocketConnectsToTheCheckedAddressNotABracketedName() {
        for host in ["[::1]", "[fe80::1%en0]", "[fd00::1]"] {
            guard case .ipv6 = RawTCPWebSocketTransport.endpointHost(host) else { Issue.record("\(host) became a name"); continue }
        }
        guard case .ipv4 = RawTCPWebSocketTransport.endpointHost("192.168.1.2") else { Issue.record("IPv4 became a name"); return }
        guard case .name = RawTCPWebSocketTransport.endpointHost("printer.local") else { Issue.record("name misparsed"); return }
    }

    @Test func probeHeadRequestIsOnlyBuiltWhereCredentialsMayTravel() {
        let creds = ["CF-Access-Client-Secret": "fixture"]
        #expect(AdaptiveLatencyProber.headRequest(for: URL(string: "http://192.0.2.1/health")!, headers: creds) == nil)
        #expect(AdaptiveLatencyProber.headRequest(for: URL(string: "http://ha.lan/health")!, headers: creds) == nil)
        #expect(AdaptiveLatencyProber.headRequest(for: URL(string: "http://192.168.1.2/health")!, headers: creds) != nil)
        #expect(AdaptiveLatencyProber.headRequest(for: URL(string: "http://192.0.2.1/health")!, headers: [:]) != nil)
        #expect(AdaptiveLatencyProber.headRequest(for: URL(string: "http://192.168.1.2/health")!,
                                                  headers: ["X-Fixture": "a\r\nInjected: yes"]) == nil)
        // An encoded CR/LF in the path stays encoded on the wire, so it can never start a new header line.
        let encoded = AdaptiveLatencyProber.headRequest(for: URL(string: "http://192.168.1.2/a%0D%0AInjected:%20yes")!, headers: [:])
        #expect(encoded.map { !$0.contains("\r\nInjected") && $0.components(separatedBy: "\r\n").count == 5 } ?? true)
    }
    #endif

    /// Scheme case must not route a cleartext probe around the credential policy.
    @Test func uppercaseCleartextSchemeCannotBypassTheProbePolicy() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingProbeProtocol.self]
        let prober = AdaptiveLatencyProber(healthPath: "health", headers: ["Authorization": "Bearer fixture"],
                                           sessionConfiguration: configuration)
        for scheme in ["HTTP", "Http", "WS"] {
            _ = await prober.probe(IoTEndpoint(id: "a", url: URL(string: "\(scheme)://192.0.2.1:9")!))
        }
        #expect(RecordingProbeProtocol.credentialedRequests == 0)
    }

    @Test func httpsProbeNeverForwardsHeadersAcrossARedirect() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingProbeProtocol.self]
        let prober = AdaptiveLatencyProber(healthPath: "health", headers: ["CF-Access-Client-Secret": "fixture"],
                                           sessionConfiguration: configuration)
        let latency = await prober.probe(IoTEndpoint(id: "a", url: URL(string: "https://probe-origin.invalid")!))
        #expect(latency != nil, "a redirect still proves the origin is reachable")
        #expect(RedirectingProbeProtocol.foreignRequests == 0)
    }
}

private final class RedirectingProbeProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var foreignRequests = 0
    override class func canInit(with request: URLRequest) -> Bool {
        ["probe-origin.invalid", "probe-foreign.invalid"].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.host == "probe-foreign.invalid" {
            Self.foreignRequests += 1
            let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: ok, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let target = URL(string: "https://probe-foreign.invalid/steal")!
        let redirect = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": target.absoluteString])!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: redirect)
        client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RecordingProbeProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var credentialedRequests = 0
    override class func canInit(with request: URLRequest) -> Bool {
        if request.value(forHTTPHeaderField: "Authorization") != nil { credentialedRequests += 1 }
        return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
    override func stopLoading() {}
}
