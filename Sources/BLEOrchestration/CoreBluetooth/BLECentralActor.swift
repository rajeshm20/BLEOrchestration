@preconcurrency import CoreBluetooth
import Foundation

/// Sole owner of `CBCentralManager` interactions.
///
/// This actor is responsible for:
/// - Creating and retaining the `CBCentralManager` with restoration options.
/// - Starting/stopping scans.
/// - Connecting/canceling connections.
/// - Routing delegate events into device-level event pipes (owned by `DeviceConnectionActor`).
actor BLECentralActor {
  struct Configuration: Sendable {
    var restorationIdentifier: String
    var showPowerAlert: Bool
    var scanServices: [CBUUID]?

    init(
      restorationIdentifier: String,
      showPowerAlert: Bool = true,
      scanServices: [CBUUID]? = nil
    ) {
      self.restorationIdentifier = restorationIdentifier
      self.showPowerAlert = showPowerAlert
      self.scanServices = scanServices
    }
  }

  private let logger: BLELogging
  private let config: Configuration

  private let cbQueue: DispatchQueue
  private let eventPipe: EventPipe<BLEEvent>
  private let delegateProxy: CoreBluetoothDelegateProxy

  // Accessed only on this actor.
  private let central: CBCentralManager
  private var state: CBManagerState = .unknown
  private var isScanning = false

  private var devicePipes: [UUID: EventPipe<DeviceEvent>] = [:]
  private var candidateCache: [UUID: DeviceCandidate] = [:]
  private let discoveryPipe = EventPipe<DeviceCandidate>(label: "ble.discovery.pipe")

  nonisolated var discoveries: AsyncStream<DeviceCandidate> { discoveryPipe.stream }

  init(configuration: Configuration, logger: BLELogging) {
    self.config = configuration
    self.logger = logger
    self.cbQueue = DispatchQueue(label: "ble.corebluetooth.queue", qos: .userInitiated)
    self.eventPipe = EventPipe<BLEEvent>(label: "ble.corebluetooth.events")
    self.delegateProxy = CoreBluetoothDelegateProxy(events: eventPipe, logger: logger)
    self.central = CBCentralManager(delegate: delegateProxy, queue: cbQueue, options: [
      CBCentralManagerOptionRestoreIdentifierKey: configuration.restorationIdentifier,
      CBCentralManagerOptionShowPowerAlertKey: configuration.showPowerAlert,
    ])

    Task { await self.runEventLoop() }
  }

  /// Registers a device event pipe owned by a `DeviceConnectionActor`.
  func registerDevicePipe(_ pipe: EventPipe<DeviceEvent>, for id: UUID) {
    devicePipes[id] = pipe
  }

  /// Unregisters a device event pipe (e.g., when a device actor is torn down).
  func unregisterDevicePipe(for id: UUID) {
    devicePipes[id] = nil
  }

  func currentState() -> CBManagerState { state }

  func retrievePeripherals(identifiers: [UUID]) -> [UncheckedPeripheral] {
    let peripherals = central.retrievePeripherals(withIdentifiers: identifiers)
    return peripherals.map { UncheckedPeripheral(peripheral: $0) }
  }

  func startScan(allowDuplicates: Bool) {
    guard !isScanning else { return }
    guard state == .poweredOn else {
      logger.log(.warn, "startScan ignored; central not poweredOn", metadata: ["state": "\(state.rawValue)"])
      return
    }

    isScanning = true
    let options: [String: Any] = [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
    central.scanForPeripherals(withServices: config.scanServices, options: options)
    logger.log(.info, "scan started", metadata: ["allowDuplicates": "\(allowDuplicates)"])
  }

  func stopScan() {
    guard isScanning else { return }
    isScanning = false
    central.stopScan()
    logger.log(.info, "scan stopped", metadata: [:])
  }

  func connect(_ peripheral: UncheckedPeripheral, options: [String: Any]? = nil) {
    // Ensure our proxy receives CBPeripheralDelegate callbacks.
    peripheral.peripheral.delegate = delegateProxy
    central.connect(peripheral.peripheral, options: options)
  }

  func cancelConnection(_ peripheral: UncheckedPeripheral) {
    central.cancelPeripheralConnection(peripheral.peripheral)
  }

  func cachedCandidate(for id: UUID) -> DeviceCandidate? {
    candidateCache[id]
  }

  // MARK: - Internal event loop

  private func runEventLoop() async {
    for await event in eventPipe.stream {
      switch event {
      case .centralStateChanged(let newState):
        state = newState
        logger.log(.info, "central state changed", metadata: ["state": "\(newState.rawValue)"])
        if newState != .poweredOn {
          // Stop scanning when Bluetooth becomes unavailable.
          if isScanning {
            isScanning = false
            central.stopScan()
          }
        }

        // Fan out central state changes to all device actors.
        for (_, pipe) in devicePipes {
          pipe.send(.centralStateChanged(newState))
        }

      case .willRestoreState(let peripherals):
        // Restoration is routed to relevant device actors (if known),
        // but also informs unknown devices for scanning / reconcile policy.
        for box in peripherals {
          let peripheral = box.peripheral
          let id = peripheral.identifier
          if let pipe = devicePipes[id] {
            pipe.send(.willRestore(peripheral: box))
          }
        }

      case .didDiscover(let peripheral, let adv, let rssi):
        let rawPeripheral = peripheral.peripheral
        let id = rawPeripheral.identifier
        let candidate = DeviceCandidate(
          id: id,
          rssi: rssi.intValue,
          lastSeen: Date(),
          kind: adv.localName
        )
        candidateCache[id] = candidate
        discoveryPipe.send(candidate)
        // Discovery is also useful to a device actor waiting in `resolving`.
        devicePipes[id]?.send(.didDiscover(peripheral: peripheral, advertisement: adv, rssi: rssi.intValue))

      case .didConnect(let peripheral):
        devicePipes[peripheral.peripheral.identifier]?.send(.didConnect(peripheral: peripheral))

      case .didFailToConnect(let peripheral, let error):
        devicePipes[peripheral.peripheral.identifier]?.send(.didFailToConnect(error: error))

      case .didDisconnect(let peripheral, let error):
        devicePipes[peripheral.peripheral.identifier]?.send(.didDisconnect(error: error))

      case .didDiscoverServices(let peripheral, let error):
        devicePipes[peripheral.peripheral.identifier]?.send(.didDiscoverServices(error: error))

      case .didDiscoverCharacteristics(let peripheral, let service, let error):
        devicePipes[peripheral.peripheral.identifier]?.send(.didDiscoverCharacteristics(service: service, error: error))

      case .didUpdateValue(let peripheral, let characteristic, let error):
        devicePipes[peripheral.peripheral.identifier]?.send(.didUpdateValue(characteristic: characteristic, error: error))

      case .didWriteValue(let peripheral, let characteristic, let error):
        devicePipes[peripheral.peripheral.identifier]?.send(.didWriteValue(characteristic: characteristic, error: error))

      case .isReadyToSendWriteWithoutResponse(let peripheral):
        devicePipes[peripheral.peripheral.identifier]?.send(.isReadyToSendWriteWithoutResponse)
      }
    }
  }
}
