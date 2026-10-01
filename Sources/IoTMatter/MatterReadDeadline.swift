import Foundation
import IoTCore

/// Apple reads cannot be cancelled. This lock owns one completion; late callbacks cannot resume
/// a cancelled/timed-out caller. Native work is stopped by the exclusive controller on disconnect.
final class MatterReadGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?
    var isPending: Bool { lock.withLock { result == nil } }
    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        let completed = lock.withLock { () -> Result<Value, any Error>? in
            if let result { return result }
            self.continuation = continuation; return nil
        }
        if let completed { continuation.resume(with: completed) }
    }
    func finish(_ result: Result<Value, any Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<Value, any Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            let pending = continuation; continuation = nil; return pending
        }
        pending?.resume(with: result)
    }
}
@MainActor
func matterReadWithDeadline<Value: Sendable>(timeout: Duration = .seconds(20),
    begin: (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void) async throws -> Value {
    try Task.checkCancellation()
    let gate = MatterReadGate<Value>()
    let deadline = Task {
        do { try await Task.sleep(for: timeout); gate.finish(.failure(IoTError.timeout)) } catch {}
    }
    defer { deadline.cancel() }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            if gate.isPending { begin { gate.finish($0) } }
        }
    } onCancel: { gate.finish(.failure(CancellationError())) }
}
