import Foundation
import Testing
import IoTCore
@testable import IoTMeross

#if canImport(Darwin)
/// Mock URLProtocol for testing HTTP transport without network access.
/// Tests must use unique hosts because test suites run in parallel and share this global stub.
/// Register a handler for your test's host via `MerossStubProtocol.register(host:handler:)`.
final class MerossStubProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(host: String, handler: @escaping Handler) {
        lock.lock()
        handlers[host] = handler
        lock.unlock()
    }

    private static func handler(for request: URLRequest) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return request.url?.host.flatMap { handlers[$0] }
    }

    override class func canInit(with request: URLRequest) -> Bool { handler(for: request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler(for: request)?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct MerossLANTransportTests {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MerossStubProtocol.self]
        return URLSession(configuration: config)
    }
    @Test func validatesHosts() {
        #expect(MerossLANTransport.url(host: "192.168.1.20")?.absoluteString == "http://192.168.1.20/config")
        #expect(MerossLANTransport.url(host: "meross-plug.local")?.absoluteString == "http://meross-plug.local/config")
        #expect(MerossLANTransport.url(host: "") == nil)
        #expect(MerossLANTransport.url(host: "http://x") == nil)
        #expect(MerossLANTransport.url(host: "a/b") == nil)
        #expect(MerossLANTransport.url(host: "user@host") == nil)
        #expect(MerossLANTransport.url(host: "host:8080") == nil)
    }
    @Test func postsEnvelopeAndDecodesReply() async throws {
        let request = MerossMessage.request(method: .get, namespace: "Appliance.System.All", payload: .object([:]), key: "fixture-key")
        MerossStubProtocol.register(host: "task3-envelope.test") { urlRequest in
            #expect(urlRequest.httpMethod == "POST")
            #expect(urlRequest.url?.path == "/config")
            let body = urlRequest.httpBody ?? urlRequest.httpBodyStream.map { stream -> Data in
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n > 0 { data.append(buffer, count: n) } else { break } }
                return data
            } ?? Data()
            let sent = try? JSONDecoder().decode(MerossMessage.self, from: body)
            let reply = MerossMessage(header: .init(from: "/appliance/u/publish", messageId: sent?.header.messageId ?? "", method: .getAck,
                                                    namespace: "Appliance.System.All", payloadVersion: 1, sign: "", timestamp: 1, triggerSrc: nil),
                                      payload: .object(["all": .object([:])]))
            return (200, (try? JSONEncoder().encode(reply)) ?? Data())
        }
        let transport = MerossLANTransport(session: session())
        let reply = try await transport.exchange(request, host: "task3-envelope.test")
        #expect(try reply.reply(to: request) == .ack(.object(["all": .object([:])])))
    }
    @Test func nonSuccessStatusAndGarbageFail() async throws {
        let request = MerossMessage.request(method: .get, namespace: "Appliance.System.All", payload: .object([:]), key: "fixture-key")
        MerossStubProtocol.register(host: "task3-http503.test") { _ in (503, Data()) }
        await #expect(throws: MerossLANTransport.Failure.http(503)) { try await MerossLANTransport(session: session()).exchange(request, host: "task3-http503.test") }
        MerossStubProtocol.register(host: "task3-garbage.test") { _ in (200, Data("not json".utf8)) }
        await #expect(throws: MerossLANTransport.Failure.malformed) { try await MerossLANTransport(session: session()).exchange(request, host: "task3-garbage.test") }
        MerossStubProtocol.register(host: "task3-oversize.test") { _ in (200, Data(repeating: 0x20, count: 300 * 1024)) }
        await #expect(throws: MerossLANTransport.Failure.oversize) { try await MerossLANTransport(session: session()).exchange(request, host: "task3-oversize.test") }
    }
}
#endif
