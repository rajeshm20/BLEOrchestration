import CoreBluetooth
import Foundation

/// Device-local events consumed by `DeviceConnectionActor`.
///
/// - Note: All CoreBluetooth types are wrapped in `@unchecked Sendable` boxes. The device actor
///   is the only writer of the underlying `CBPeripheral` API surface for its device.
enum DeviceEvent: Sendable {
  // Central lifecycle
  case centralStateChanged(CBManagerState)
  case willRestore(peripheral: UncheckedPeripheral)

  // Discovery
  case didDiscover(peripheral: UncheckedPeripheral, advertisement: AdvertisementPayload, rssi: Int)

  // Connection
  case didConnect(peripheral: UncheckedPeripheral)
  case didFailToConnect(error: Error?)
  case didDisconnect(error: Error?)

  // GATT discovery + IO
  case didDiscoverServices(error: Error?)
  case didDiscoverCharacteristics(service: UncheckedService, error: Error?)
  case didUpdateValue(characteristic: UncheckedCharacteristic, error: Error?)
  case didWriteValue(characteristic: UncheckedCharacteristic, error: Error?)
  case isReadyToSendWriteWithoutResponse

  // Internal
  case startRequested
  case stopRequested
  case reconnectTimerFired
  case handshakeTimeout
  case policyUpdated(eligibility: DeviceEligibility)
}

/// Side-effect intents emitted by the reducer.
enum DeviceEffect: Sendable {
  case startResolve
  case connect(peripheral: UncheckedPeripheral?)
  case beginGATTDiscovery
  case subscribeNotifications
  case openTransport
  case closeTransport
  case scheduleReconnect(after: TimeInterval)
  case cancelReconnect
  case suspend(reason: SuspendReason)
}

public enum SuspendReason: Sendable, Equatable {
  case bluetoothUnavailable
  case stoppedByApp
  case ineligible
}

public enum DeviceState: Sendable, Equatable {
  case idle
  case resolving
  case connecting(attempt: Int)
  case discovering(attempt: Int)
  case ready
  case degraded
  case backingOff(attempt: Int, nextDelay: TimeInterval)
  case suspended(SuspendReason)
}

/// Pure reducer for device state transitions.
///
/// - Important: Keep this reducer free of CoreBluetooth API calls. It must remain deterministic and testable.
struct DeviceStateMachine {
  static func reduce(
    state: DeviceState,
    event: DeviceEvent,
    eligibility: DeviceEligibility,
    attempt: Int,
    backoffDelay: (Int) -> TimeInterval
  ) -> (DeviceState, [DeviceEffect]) {
    // Eligibility gate: if the device is explicitly ineligible, enforce suspension early.
    if case .ineligible = eligibility {
      if case .stopRequested = event {
        // Allow explicit stop to proceed.
      } else {
        return (.suspended(.ineligible), [.suspend(reason: .ineligible), .closeTransport])
      }
    }

    switch (state, event) {
    case (_, .stopRequested):
      return (.suspended(.stoppedByApp), [.cancelReconnect, .closeTransport, .suspend(reason: .stoppedByApp)])

    case (.suspended, .startRequested):
      return (.idle, [.startResolve])

    case (.idle, .startRequested):
      return (.resolving, [.startResolve])

    case (.resolving, .didDiscover):
      // Once we have a matching peripheral, attempt connect.
      return (.connecting(attempt: attempt), [.connect(peripheral: nil)])

    case (.resolving, .willRestore(let peripheral)):
      // Restoration provides a peripheral instance without scanning.
      return (.connecting(attempt: attempt), [.connect(peripheral: peripheral)])

    case (_, .centralStateChanged(let s)) where s != .poweredOn:
      return (.suspended(.bluetoothUnavailable), [.cancelReconnect, .closeTransport, .suspend(reason: .bluetoothUnavailable)])

    case (.connecting, .didConnect):
      return (.discovering(attempt: attempt), [.beginGATTDiscovery])

    case (.connecting, .didFailToConnect):
      let delay = backoffDelay(attempt)
      return (.backingOff(attempt: attempt, nextDelay: delay), [.scheduleReconnect(after: delay), .closeTransport])

    case (.connecting, .didDisconnect):
      let delay = backoffDelay(attempt)
      return (.backingOff(attempt: attempt, nextDelay: delay), [.scheduleReconnect(after: delay), .closeTransport])

    case (.discovering, .didDiscoverServices):
      return (state, []) // discovery continues; device actor will call discover characteristics per profile

    case (.discovering, .didDiscoverCharacteristics):
      return (state, []) // subscription decisions handled by device actor via profile

    case (.discovering, .handshakeTimeout):
      let delay = backoffDelay(attempt)
      return (.backingOff(attempt: attempt, nextDelay: delay), [.scheduleReconnect(after: delay), .closeTransport])

    case (.discovering, .policyUpdated):
      return (state, [])

    case (.discovering, .didUpdateValue):
      return (state, [])

    case (.discovering, .didWriteValue):
      return (state, [])

    case (.discovering, .isReadyToSendWriteWithoutResponse):
      return (state, [])

    case (.discovering, .didDisconnect):
      let delay = backoffDelay(attempt)
      return (.backingOff(attempt: attempt, nextDelay: delay), [.scheduleReconnect(after: delay), .closeTransport])

    case (.backingOff, .reconnectTimerFired):
      return (.resolving, [.startResolve])

    case (.ready, .didDisconnect):
      let delay = backoffDelay(attempt)
      return (.backingOff(attempt: attempt, nextDelay: delay), [.scheduleReconnect(after: delay), .closeTransport])

    case (.ready, .handshakeTimeout):
      // Treat protocol stalls as degraded and reconnect on the device actor side.
      let delay = backoffDelay(attempt)
      return (.backingOff(attempt: attempt, nextDelay: delay), [.scheduleReconnect(after: delay), .closeTransport])

    default:
      return (state, [])
    }
  }
}
