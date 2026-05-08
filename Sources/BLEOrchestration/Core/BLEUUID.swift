import CoreBluetooth
import Foundation

/// Sendable wrapper for Bluetooth UUIDs.
///
/// CoreBluetooth's `CBUUID` is a reference type and not `Sendable`. This value-type wrapper keeps
/// the public API concurrency-safe, while still allowing lossless conversion to/from `CBUUID`.
public struct BLEUUID: Hashable, Sendable, ExpressibleByStringLiteral {
  public let string: String

  public init(_ string: String) {
    self.string = string
  }

  public init(stringLiteral value: StringLiteralType) {
    self.string = value
  }

  public var cb: CBUUID { CBUUID(string: string) }
}

