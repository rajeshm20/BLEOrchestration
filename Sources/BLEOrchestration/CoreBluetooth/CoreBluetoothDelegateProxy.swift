import CoreBluetooth
import Foundation

/// Delegate isolation boundary for CoreBluetooth.
///
/// - Important: Do not put business logic in delegate callbacks. This proxy forwards
///   typed `BLEEvent`s to a central event pipe, where actors handle sequencing and policy.
final class CoreBluetoothDelegateProxy: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  private let events: EventPipe<BLEEvent>
  private let logger: BLELogging

  init(events: EventPipe<BLEEvent>, logger: BLELogging) {
    self.events = events
    self.logger = logger
    super.init()
  }

  // MARK: - CBCentralManagerDelegate

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    events.send(.centralStateChanged(central.state))
  }

  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    let peripherals = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
    logger.log(.info, "CoreBluetooth willRestoreState", metadata: ["peripheralCount": "\(peripherals.count)"])
    events.send(.willRestoreState(peripherals: peripherals.map { UncheckedPeripheral(peripheral: $0) }))
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    let payload = AdvertisementPayload(localName: advertisementData[CBAdvertisementDataLocalNameKey] as? String)
    events.send(.didDiscover(peripheral: UncheckedPeripheral(peripheral: peripheral), advertisement: payload, rssi: RSSI))
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    events.send(.didConnect(peripheral: UncheckedPeripheral(peripheral: peripheral)))
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    events.send(.didFailToConnect(peripheral: UncheckedPeripheral(peripheral: peripheral), error: error))
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    events.send(.didDisconnect(peripheral: UncheckedPeripheral(peripheral: peripheral), error: error))
  }

  // MARK: - CBPeripheralDelegate

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    events.send(.didDiscoverServices(peripheral: UncheckedPeripheral(peripheral: peripheral), error: error))
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    events.send(.didDiscoverCharacteristics(peripheral: UncheckedPeripheral(peripheral: peripheral), service: UncheckedService(service: service), error: error))
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    events.send(.didUpdateValue(peripheral: UncheckedPeripheral(peripheral: peripheral), characteristic: UncheckedCharacteristic(characteristic: characteristic), error: error))
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    events.send(.didWriteValue(peripheral: UncheckedPeripheral(peripheral: peripheral), characteristic: UncheckedCharacteristic(characteristic: characteristic), error: error))
  }

  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    events.send(.isReadyToSendWriteWithoutResponse(peripheral: UncheckedPeripheral(peripheral: peripheral)))
  }
}
