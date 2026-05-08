import Foundation

/// Fleet-level policy controlling which devices are eligible to connect.
public struct DevicePolicy: Sendable {
  /// Upper bound for simultaneously connected peripherals.
  public var maxConcurrentConnections: Int

  /// Pinned peripherals should be maintained whenever possible.
  public var pinned: Set<UUID>

  /// If true, the orchestrator may connect non-pinned devices (up to max concurrent connections).
  public var allowDynamicPool: Bool

  public init(
    maxConcurrentConnections: Int = 12,
    pinned: Set<UUID> = [],
    allowDynamicPool: Bool = true
  ) {
    self.maxConcurrentConnections = max(1, maxConcurrentConnections)
    self.pinned = pinned
    self.allowDynamicPool = allowDynamicPool
  }
}

/// A scoring function used to rank dynamic-pool devices (e.g., recent seen, RSSI, user preference).
public protocol DeviceScoring: Sendable {
  func score(candidate: DeviceCandidate) -> Int
}

/// Known candidate discovered via scanning or application metadata.
public struct DeviceCandidate: Sendable, Hashable {
  public let id: UUID
  public let rssi: Int?
  public let lastSeen: Date?
  public let kind: String?

  public init(id: UUID, rssi: Int?, lastSeen: Date?, kind: String?) {
    self.id = id
    self.rssi = rssi
    self.lastSeen = lastSeen
    self.kind = kind
  }
}

/// Default device scoring: prioritize recent + stronger RSSI.
public struct DefaultDeviceScoring: DeviceScoring {
  public init() {}

  public func score(candidate: DeviceCandidate) -> Int {
    var score = 0
    if let rssi = candidate.rssi { score += max(-100, min(0, rssi)) }
    if let lastSeen = candidate.lastSeen {
      let age = Date().timeIntervalSince(lastSeen)
      score += Int(max(-60, -age / 10))
    }
    return score
  }
}

