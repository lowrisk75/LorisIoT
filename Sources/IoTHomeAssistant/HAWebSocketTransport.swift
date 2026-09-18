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
    private var closed = false

    private let redirectDelegate = HAWebSocketRedirectDelegate()
    /// Present only when this transport created, and therefore owns, its session.
    private let lifecycle: HAWebSocketSessionLifecycle?

    public init(url: URL, session: URLSession? = nil) {
        self.url = url
        if let session {
            self.session = session; lifecycle = nil
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            let lifecycle = HAWebSocketSessionLifecycle()
            self.session = URLSession(configuration: configuration, delegate: lifecycle, delegateQueue: nil)
            self.lifecycle = lifecycle
        }
    }

    /// Observation seam: whether an owned session has been released.
    var ownedSessionInvalidated: Bool { lifecycle?.invalidated ?? false }

    public func open() async throws {
        // An owned session is released on close; a task on an invalidated session would raise.
        guard !closed else { throw IoTError.notConnected }
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = 4 * 1024 * 1024
        t.delegate = redirectDelegate
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
        // A fresh transport is built per reconnect, so an owned session must go with it or one leaks
        // per attempt. An injected session belongs to its caller and is left alone, and stays reusable.
        if lifecycle != nil { closed = true; session.invalidateAndCancel() }
    }
}

final class HAWebSocketSessionLifecycle: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    var invalidated: Bool { lock.lock(); defer { lock.unlock() }; return released }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        lock.lock(); released = true; lock.unlock()
    }
}

private final class HAWebSocketRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // A later auth frame must never be sent to a redirected origin.
    }
}
