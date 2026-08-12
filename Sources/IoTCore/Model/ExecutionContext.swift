import Foundation

/// Where a control call runs. A **system extension** (Widget, Control Center, Siri App Intent) usually
/// **cannot reach the LAN** (Local Network privilege is unreliable outside the app process), so a
/// provider with both a local and a remote transport must go **remote-first** there — never hang on a
/// LAN call that will time out. In the app, local-first is correct (fast + private).
///
/// Detect it in the host app with `Bundle.main.bundlePath.hasSuffix(".appex")` and pass it in.
public enum ExecutionContext: Sendable, Equatable {
    case app
    case systemExtension

    /// True when the LAN should be skipped in favour of the remote path first.
    public var prefersRemoteTransport: Bool { self == .systemExtension }
}
