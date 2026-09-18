import Foundation
import Testing
import IoTCore
@testable import IoTMQTTCocoa

/// Broker credentials must never cross a public network in cleartext. A connection failure alone would
/// also throw, so the test demands the specific refusal rather than any error.
@Suite struct CleartextBrokerTests {
    @Test func credentialsAreNeverSentInCleartextToAPublicBroker() async {
        let transport = CocoaMQTTTransport(config: .init(host: "broker.example.com", clientID: "lorisiot-test",
                                                         username: "user", password: "secret", useTLS: false))
        do {
            try await transport.connect()
            Issue.record("connect should have been refused before any socket")
        } catch let error as IoTError {
            guard case .notSupported = error else { Issue.record("expected a refusal, got \(error)"); return }
        } catch {
            Issue.record("expected a refusal, got \(error)")
        }
    }

    /// A bracketed IPv6 broker must reach CocoaMQTT as the bare literal the policy checked, never as a name.
    @Test func bracketedIPv6BrokerIsHandedOnAsTheCheckedLiteral() {
        #expect(CocoaMQTTTransport.connectHost("[fd00::1]") == "fd00::1")
        #expect(CocoaMQTTTransport.connectHost("fd00::1") == "fd00::1")
        #expect(CocoaMQTTTransport.connectHost("192.168.1.10") == "192.168.1.10")
    }
}
