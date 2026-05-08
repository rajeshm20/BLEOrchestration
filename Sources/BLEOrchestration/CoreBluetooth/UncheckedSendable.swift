import CoreBluetooth

/// CoreBluetooth reference types are not annotated as Sendable, but are safe to pass across
/// concurrency domains *when a single owner* serializes all interactions.
///
/// This engine enforces ownership:
/// - `BLECentralActor` serializes `CBCentralManager` calls.
/// - `DeviceConnectionActor` serializes `CBPeripheral` calls for its device.
///
/// We wrap CoreBluetooth types in `@unchecked Sendable` boxes to make that ownership explicit.
struct UncheckedPeripheral: @unchecked Sendable {
  let peripheral: CBPeripheral
}

struct UncheckedService: @unchecked Sendable {
  let service: CBService
}

struct UncheckedCharacteristic: @unchecked Sendable {
  let characteristic: CBCharacteristic
}

