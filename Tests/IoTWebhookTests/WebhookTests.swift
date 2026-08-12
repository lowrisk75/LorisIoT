import Testing
import Foundation
@testable import IoTWebhook
import IoTCore

actor RecordingHTTP: WebhookHTTP {
    private(set) var lastURL: URL?
    private(set) var lastHeaders: [String: String] = [:]
    private(set) var lastBody: Data?
    var status = 200
    func post(url: URL, body: Data, headers: [String: String]) async throws -> Int {
        lastURL = url; lastHeaders = headers; lastBody = body; return status
    }
}

@Suite struct WebhookTests {
    @Test func hmacSignatureIsStableAndCorrect() {
        // HMAC-SHA256("hello", key="key") known vector.
        let sig = WebhookClient.signature(body: Data("hello".utf8), secret: "key")
        #expect(sig == "9307b3b915efb5171ff14d8cb55fbcc798c6c0ef1456d66ded1a6aa723a58b7b")
    }

    @Test func rejectsInsecureURLs() {
        #expect(WebhookClient.safeURL("http://ha.local/hook") == nil)          // not https
        #expect(WebhookClient.safeURL("https://ha.local/hook?token=x") == nil) // query
        #expect(WebhookClient.safeURL("https://user:pw@ha.local/hook") == nil) // credentials
        #expect(WebhookClient.safeURL("https://ha.local/hook") != nil)
    }

    @Test func sendSignsAndPostsToSecureURL() async throws {
        let http = RecordingHTTP()
        let client = WebhookClient(secret: "s3cr3t", http: http)
        let payload = WebhookPayload(eventId: "evt-1", ts: 1_723_400_000, action: "wake", device: "coffee")
        try await client.send(payload, to: "https://ha.local/api/webhook/velya")
        #expect(await http.lastURL?.absoluteString == "https://ha.local/api/webhook/velya")
        let headers = await http.lastHeaders
        #expect(headers["X-LorisIoT-Signature"]?.hasPrefix("sha256=") == true)
        // signature matches the exact body sent
        let body = try #require(await http.lastBody)
        #expect(headers["X-LorisIoT-Signature"] == "sha256=\(WebhookClient.signature(body: body, secret: "s3cr3t"))")
    }

    @Test func throwsOnInsecureTarget() async {
        let client = WebhookClient(secret: "x", http: RecordingHTTP())
        let payload = WebhookPayload(eventId: "e", ts: 0, action: "a")
        await #expect(throws: WebhookError.insecureURL) {
            try await client.send(payload, to: "http://ha.local/hook")
        }
    }
}
