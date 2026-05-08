import Foundation

/// Persistence for pinned UUIDs and minimal orchestration metadata.
public protocol StatePersisting: Sendable {
  func loadPinned() throws -> Set<UUID>
  func savePinned(_ pinned: Set<UUID>) throws
}

/// Default implementation backed by `UserDefaults`.
public final class UserDefaultsStateStore: StatePersisting, @unchecked Sendable {
  private let defaults: UserDefaults
  private let pinnedKey: String

  public init(defaults: UserDefaults = .standard, pinnedKey: String = "ble.pinned.peripheralUUIDs") {
    self.defaults = defaults
    self.pinnedKey = pinnedKey
  }

  public func loadPinned() throws -> Set<UUID> {
    let strings = defaults.array(forKey: pinnedKey) as? [String] ?? []
    return Set(strings.compactMap(UUID.init(uuidString:)))
  }

  public func savePinned(_ pinned: Set<UUID>) throws {
    defaults.set(pinned.map(\.uuidString).sorted(), forKey: pinnedKey)
  }
}
