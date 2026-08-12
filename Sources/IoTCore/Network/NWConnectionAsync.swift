import Foundation
#if canImport(Network)
import Network

/// Async wrappers over `NWConnection` shared by `RawTCPWebSocketTransport` and the raw-TCP
/// endpoint prober. Internal plumbing — not API.
enum NWConnectionAsync {

    /// Resume-once continuation guard (NWConnection handlers can fire more than once).
    final class ResumeOnce<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func resume(_ cont: CheckedContinuation<T, any Error>, with result: Result<T, any Error>) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            guard first else { return }
            cont.resume(with: result)
        }
        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
    }

    /// Wait for `.ready` with a hard timeout. Ported fix (Lumen 2026-05-31): the timeout is
    /// DISARMED once the connection resolves — a live session must never be killed at T+timeout.
    /// `.waiting` fails fast instead of hanging on an unroutable LAN address.
    static func waitReady(_ connection: NWConnection, timeout: Double) async throws {
        let once = ResumeOnce<Void>()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(cont, with: .success(()))
                case .failed(let error): once.resume(cont, with: .failure(error))
                case .cancelled: once.resume(cont, with: .failure(IoTError.cancelled))
                case .waiting(let error):
                    connection.cancel()
                    once.resume(cont, with: .failure(error))
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                guard !once.isDone else { return }
                connection.cancel()    // forces .cancelled → resumes via the state handler
                once.resume(cont, with: .failure(IoTError.timeout))
            }
        }
    }

    static func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    static func receiveChunk(_ connection: NWConnection, max: Int = 65536) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { content, _, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let content, !content.isEmpty {
                    cont.resume(returning: content)
                } else if isComplete {
                    cont.resume(throwing: IoTError.transport("TCP stream ended"))
                } else {
                    cont.resume(throwing: IoTError.invalidResponse)
                }
            }
        }
    }
}
#endif
