import Foundation
import IoTCore

/// One operation owns one result and timeout. A cancelled/expired operation cannot finish a later one.
final class MQTTAcknowledgement: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, any Error>?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var timer: Task<Void, Never>?

    func finish(_ value: Result<Void, any Error>) {
        let pending: (CheckedContinuation<Void, any Error>?, Task<Void, Never>?)? = lock.withLock {
            guard result == nil else { return nil }
            result = value
            let pending = (continuation, timer); continuation = nil; timer = nil
            return pending
        }
        pending?.1?.cancel(); pending?.0?.resume(with: value)
    }

    func wait(timeout: Double, start: @escaping @Sendable () -> Void) async throws {
        guard timeout.isFinite, timeout > 0, timeout <= 300 else { throw IoTError.notConfigured }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                let prior = lock.withLock { () -> Result<Void, any Error>? in
                    if let result { return result }
                    continuation = c; return nil
                }
                if let prior { c.resume(with: prior); return }
                if Task.isCancelled { finish(.failure(CancellationError())); return }
                let timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) }
                    catch { return }
                    self?.finish(.failure(IoTError.timeout))
                }
                let shouldStart = lock.withLock {
                    guard result == nil else { timeoutTask.cancel(); return false }
                    timer = timeoutTask; return true
                }
                if shouldStart { start() }
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }
}
