import Foundation

public enum LogLevel: String, Sendable {
  case trace, debug, info, warn, error
}

/// Lightweight structured logger abstraction.
///
/// - Note: This engine avoids a hard dependency on os.log so the consumer can wire
///   to their preferred logging stack (os.Logger, CocoaLumberjack, custom, etc).
public protocol BLELogging: Sendable {
  func log(_ level: LogLevel, _ message: @autoclosure () -> String, metadata: [String: String])
}

public struct NoopLogger: BLELogging {
  public init() {}
  public func log(_ level: LogLevel, _ message: @autoclosure () -> String, metadata: [String: String]) {}
}

