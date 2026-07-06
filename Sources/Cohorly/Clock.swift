import Foundation

/// Time source abstraction so session-length math can be driven by a
/// deterministic clock in tests instead of wall-clock `Date()`.
public protocol CohorlyClock: Sendable {
    func now() -> Date
}

/// Default clock backed by the system wall clock.
public struct SystemClock: CohorlyClock {
    public init() {}
    public func now() -> Date { Date() }
}
