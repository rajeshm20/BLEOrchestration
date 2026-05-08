@preconcurrency import CoreBluetooth
import Foundation

/// Unified event stream produced by CoreBluetooth delegates.
enum BLEEvent: Sendable {
  // Central lifecycle
  case centralStateChanged(CBManagerState)
  case willRestoreState(peripherals: [UncheckedPeripheral])

  // Discovery
  case didDiscover(peripheral: UncheckedPeripheral, advertisement: AdvertisementPayload, rssi: NSNumber)

  // Connection
  case didConnect(peripheral: UncheckedPeripheral)
  case didFailToConnect(peripheral: UncheckedPeripheral, error: Error?)
  case didDisconnect(peripheral: UncheckedPeripheral, error: Error?)

  // GATT discovery + IO
  case didDiscoverServices(peripheral: UncheckedPeripheral, error: Error?)
  case didDiscoverCharacteristics(peripheral: UncheckedPeripheral, service: UncheckedService, error: Error?)
  case didUpdateValue(peripheral: UncheckedPeripheral, characteristic: UncheckedCharacteristic, error: Error?)
  case didWriteValue(peripheral: UncheckedPeripheral, characteristic: UncheckedCharacteristic, error: Error?)
  case isReadyToSendWriteWithoutResponse(peripheral: UncheckedPeripheral)
}

/// Sendable representation of advertisement data (CoreBluetooth gives `[String: Any]`).
///
/// - Note: The full dictionary is not Sendable; the engine extracts only the fields used by policy.
struct AdvertisementPayload: Sendable {
  var localName: String?

  init(localName: String?) {
    self.localName = localName
  }
}
