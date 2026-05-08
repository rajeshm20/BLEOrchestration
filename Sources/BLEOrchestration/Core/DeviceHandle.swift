import Foundation

/// Stable identifier for a physical BLE device known to the app.
///
/// - Important: CoreBluetooth peripheral identifiers are UUIDs that are stable for a given device
///   and app install, but may change across reinstalls. Persist accordingly.
public struct DeviceHandle: Hashable, Sendable {
  public let id: UUID
  public let kind: String?

  public init(id: UUID, kind: String? = nil) {
    self.id = id
    self.kind = kind
  }
}

/// Connection eligibility as decided by orchestration policy.
public enum DeviceEligibility: Sendable, Equatable {
  case pinned
  case dynamic(priority: Int)
  case ineligible
}

