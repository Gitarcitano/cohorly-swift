import Foundation

/// The SDK retry delay rule: base 2 s, doubling per consecutive failure,
/// capped at `maxDelay`, +/-20% jitter. A `Retry-After` above 0 wins (still
/// capped). Only the rule is shared: each queue (`/track`, `/replay`) keeps
/// its own failure count, so a 429 on one never delays the other.
@_spi(CohorlyReplay)
public struct CohorlyBackoff: Sendable {
    public static let base: TimeInterval = 2

    public let maxDelay: TimeInterval

    public init(maxDelay: TimeInterval) {
        self.maxDelay = max(0, maxDelay)
    }

    /// - Parameters:
    ///   - failures: consecutive failures including this one (>= 1).
    ///   - retryAfter: the response's `Retry-After`, in seconds, if any.
    ///   - random: a value in [0, 1) that drives the jitter.
    public func delay(
        failures: Int,
        retryAfter: TimeInterval? = nil,
        random: () -> Double = { Double.random(in: 0..<1) }
    ) -> TimeInterval {
        if let retryAfter, retryAfter > 0 {
            return min(retryAfter, maxDelay)
        }
        let exponent = Double(max(1, failures) - 1)
        let capped = min(Self.base * pow(2, exponent), maxDelay)
        let jitter = capped * 0.2 * (random() * 2 - 1)
        return max(0, capped + jitter)
    }
}
