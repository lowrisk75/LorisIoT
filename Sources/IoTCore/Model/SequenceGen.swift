import Foundation

/// Monotonic local sequence for `StateRevision.localSequence` — deterministic process ordering of
/// state snapshots across a provider's capabilities.
public actor SequenceGen {
    private var n: UInt64 = 0
    public init() {}
    public func next() -> UInt64 { n += 1; return n }
}
