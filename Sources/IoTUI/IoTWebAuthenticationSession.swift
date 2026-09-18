#if os(iOS) || os(macOS) || os(visionOS)
import AuthenticationServices
import Foundation
import IoTCore

/// The host supplies its own window, preserving correct presentation in a multiwindow app.
@MainActor public final class IoTWebAuthenticationSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var anchor: ASPresentationAnchor?
    private var continuation: CheckedContinuation<URL, any Error>?
    public override init() { super.init() }

    public func authenticate(url: URL, callbackScheme: String, anchor: ASPresentationAnchor,
                             ephemeral: Bool = false) async throws -> URL {
        guard session == nil else { throw IoTError.transport("Authorization is already in progress") }
        self.anchor = anchor
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { c in
                continuation = c
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] url, error in
                    Task { @MainActor in
                        if let url { self?.finish(.success(url)) }
                        else { self?.finish(.failure(error ?? CancellationError())) }
                    }
                }
                self.session = session
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = ephemeral
                if !session.start() { finish(.failure(IoTError.notConnected)) }
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }
    public func cancel() { session?.cancel(); finish(.failure(CancellationError())) }
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor! }
    private func finish(_ result: Result<URL, any Error>) {
        guard let continuation else { return }
        self.continuation = nil; session = nil; anchor = nil
        continuation.resume(with: result)
    }
}
#endif
