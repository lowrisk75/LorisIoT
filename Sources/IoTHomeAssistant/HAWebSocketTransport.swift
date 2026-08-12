import Foundation
import IoTCore

/// `RealtimeTransport` over `URLSessionWebSocketTask` for Home Assistant's `/api/websocket`. HA speaks
/// JSON **text** frames. Held in an actor so the task is isolated (URLSessionWebSocketTask isn't
/// Sendable). `close()` cancels the task, which makes an in-flight `receive()` throw — the exact hook
/// the `RealtimeSocketClient` watchdog needs to unstick a silently-dead socket.
public actor HAWebSocketTransport: RealtimeTransport {
    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    public func open() async throws {
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
    }

    public func send(_ data: Data) async throws {
        guard let task else { throw IoTError.notConnected }
        let text = String(data: data, encoding: .utf8) ?? ""
        try await task.send(.string(text))
    }

    public func receive() async throws -> Data {
        guard let task else { throw IoTError.notConnected }
        switch try await task.receive() {
        case .string(let s): return Data(s.utf8)
        case .data(let d): return d
        @unknown default: throw IoTError.invalidResponse
        }
    }

    public func close() async {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}
