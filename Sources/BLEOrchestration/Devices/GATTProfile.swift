import Foundation

/// Describes the GATT layout for a class of devices.
///
/// This engine stays protocol-agnostic. The application provides a `GATTProfile`
/// for each device kind to define:
/// - Which services and characteristics must be present
/// - Which characteristic receives outbound writes
/// - Which characteristics emit inbound notifications/indications
public protocol GATTProfile {
  /// Services required for a device session to be considered `ready`.
  var requiredServices: [BLEUUID] { get }

  /// Characteristic UUIDs required per service.
  func requiredCharacteristics(for service: BLEUUID) -> [BLEUUID]

  /// Characteristic used for outbound writes.
  var txCharacteristic: BLEUUID { get }

  /// Characteristics expected to produce inbound notifications.
  var notifyCharacteristics: [BLEUUID] { get }
}
