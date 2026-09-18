import Foundation
import Testing
import IoTCore
@testable import IoTHomeAssistant

/// A fresh transport is built for every reconnect, so a session it owns must be released on close or
/// an unstable network leaks one session per attempt.
@Suite struct HAWebSocketTransportLifecycleTests {
    @Test func closingReleasesAnOwnedSession() async throws {
        let transport = HAWebSocketTransport(url: URL(string: "wss://ha.invalid/api/websocket")!)
        await transport.close()
        var released = false
        for _ in 0..<40 {
            released = await transport.ownedSessionInvalidated
            if released { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(released)
    }

    @Test func aClosedTransportCannotBeReopened() async {
        let transport = HAWebSocketTransport(url: URL(string: "wss://ha.invalid/api/websocket")!)
        await transport.close()
        await #expect(throws: (any Error).self) { try await transport.open() }
    }

    /// An injected session belongs to the caller, so a caller reusing one transport can still reconnect.
    @Test func aTransportOnAnInjectedSessionCanReopenAfterClose() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let transport = HAWebSocketTransport(url: URL(string: "wss://ha.invalid/api/websocket")!, session: session)
        await transport.close()
        try await transport.open()
        await transport.close()
    }
}
