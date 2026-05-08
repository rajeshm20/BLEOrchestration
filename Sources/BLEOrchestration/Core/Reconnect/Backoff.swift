import Foundation

/// Jittered exponential backoff with caps.
///
/// - Rationale: For multi-device fleets, deterministic backoff can synchronize reconnect storms.
///   Jitter spreads attempts to improve overall stability.
public struct JitteredExponentialBackoff: Sendable {
  public var initial: TimeInterval
  public var maxDelay: TimeInterval
  public var multiplier: Double
  public var jitter: Double

  public init(
    initial: TimeInterval = 0.5,
    maxDelay: TimeInterval = 30,
    multiplier: Double = 1.8,
    jitter: Double = 0.2
  ) {
    self.initial = max(0.1, initial)
    self.maxDelay = max(self.initial, maxDelay)
    self.multiplier = max(1.1, multiplier)
    self.jitter = max(0, min(1.0, jitter))
  }

  /// Returns a delay for the given attempt number (1-based recommended).
  public func delay(attempt: Int) -> TimeInterval {
    let attempt = max(1, attempt)
    let exp = initial * pow(multiplier, Double(attempt - 1))
    let capped = min(maxDelay, exp)

    // Apply symmetric jitter around capped.
    let delta = capped * jitter
    let minDelay = Swift.max(0.05, capped - delta)
    let maxDelay = capped + delta
    return Double.random(in: minDelay...maxDelay)
  }
}
