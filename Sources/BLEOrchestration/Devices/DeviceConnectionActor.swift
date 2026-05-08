@preconcurrency import CoreBluetooth
import Foundation

/// Per-device connection actor implementing a deterministic state machine and per-device transport.
actor DeviceConnectionActor {
  struct Configuration: Sendable {
    var handshakeTimeout: TimeInterval
    var schedulerLimits: OutgoingScheduler.Limits

    init(
      handshakeTimeout: TimeInterval = 10,
      schedulerLimits: OutgoingScheduler.Limits = .init()
    ) {
      self.handshakeTimeout = max(1, handshakeTimeout)
      self.schedulerLimits = schedulerLimits
    }
  }

  enum LifecycleEvent: Sendable, Equatable {
    case stateChanged(DeviceState)
    case ready
    case disconnected
    case suspended(SuspendReason)
  }

  let id: UUID

  nonisolated let inboundPipe: EventPipe<DeviceEvent>
  nonisolated var inbound: EventPipe<DeviceEvent> { inboundPipe }

  private let logger: BLELogging
  private let central: BLECentralActor
  private let profile: any GATTProfile
  private let config: Configuration
  private let backoff: JitteredExponentialBackoff

  private var eligibility: DeviceEligibility
  private var attempt: Int = 1

  private var state: DeviceState = .idle
  private var peripheral: CBPeripheral?

  private var characteristicsByUUID: [CBUUID: CBCharacteristic] = [:]
  private var servicesByUUID: [CBUUID: CBService] = [:]

  private var readyToSendWithoutResponse: Bool = false
  private let scheduler: OutgoingScheduler

  private let lifecyclePipe = EventPipe<LifecycleEvent>(label: "ble.device.lifecycle.pipe")
  nonisolated var lifecycle: AsyncStream<LifecycleEvent> { lifecyclePipe.stream }

  private var reconnectTask: Task<Void, Never>?
  private var handshakeTimeoutTask: Task<Void, Never>?

  init(
    id: UUID,
    eligibility: DeviceEligibility,
    central: BLECentralActor,
    profile: any GATTProfile,
    configuration: Configuration = .init(),
    backoff: JitteredExponentialBackoff = .init(),
    logger: BLELogging
  ) {
    self.id = id
    self.eligibility = eligibility
    self.central = central
    self.profile = profile
    self.config = configuration
    self.backoff = backoff
    self.logger = logger
    self.inboundPipe = EventPipe<DeviceEvent>(label: "ble.device.\(id.uuidString).events")
    self.scheduler = OutgoingScheduler(limits: configuration.schedulerLimits)

    Task { await runEventLoop() }
  }

  // MARK: - Public API

  func start() {
    inboundPipe.send(.startRequested)
  }

  func stop() {
    inboundPipe.send(.stopRequested)
  }

  func updateEligibility(_ eligibility: DeviceEligibility) {
    inboundPipe.send(.policyUpdated(eligibility: eligibility))
  }

  /// Enqueues a logical packet for transmission; delivery is scheduled by QoS and backpressure.
  func send(_ packet: OutgoingPacket) {
    let maxChunk = maxWriteChunkSize(preferWithoutResponse: true)
    let chunks = PacketFragmenter.fragment(packet: packet, maxChunkSize: maxChunk)
    _ = scheduler.enqueue(chunks: chunks)
    flushOutboundIfPossible()
  }

  // MARK: - Event loop

  private func runEventLoop() async {
    await central.registerDevicePipe(inboundPipe, for: id)

    for await event in inboundPipe.stream {
      // Update eligibility if policy event.
      if case .policyUpdated(let e) = event { eligibility = e }

      let delayFn: (Int) -> TimeInterval = { [backoff] attempt in backoff.delay(attempt: attempt) }
      let (nextState, effects) = DeviceStateMachine.reduce(
        state: state,
        event: event,
        eligibility: eligibility,
        attempt: attempt,
        backoffDelay: delayFn
      )

      if nextState != state {
        state = nextState
        lifecyclePipe.send(.stateChanged(nextState))
      }

      await applyEffects(effects, causedBy: event)
      await handleEvent(event)
    }
  }

  private func applyEffects(_ effects: [DeviceEffect], causedBy event: DeviceEvent) async {
    for effect in effects {
      switch effect {
      case .startResolve:
        await startResolve()

      case .connect(let provided):
        await connect(using: provided)

      case .beginGATTDiscovery:
        await beginGATTDiscovery()

      case .subscribeNotifications:
        await subscribeNotifications()

      case .openTransport:
        lifecyclePipe.send(.ready)

      case .closeTransport:
        // Transport teardown is currently implicit (scheduler queues remain but can be cleared if desired).
        break

      case .scheduleReconnect(let delay):
        scheduleReconnect(after: delay)

      case .cancelReconnect:
        reconnectTask?.cancel()
        reconnectTask = nil

      case .suspend(let reason):
        lifecyclePipe.send(.suspended(reason))
      }
    }
  }

  // MARK: - Resolve / Connect / Discovery

  private func startResolve() async {
    guard eligibility != .ineligible else { return }

    // Attempt direct retrieval first; scanning is a fallback.
    let retrieved = await central.retrievePeripherals(identifiers: [id]).first?.peripheral
    if let p = retrieved {
      inboundPipe.send(.willRestore(peripheral: UncheckedPeripheral(peripheral: p)))
      return
    }

    // Ensure scanning is active to rediscover this device.
    await central.startScan(allowDuplicates: false)
  }

  private func connect(using provided: UncheckedPeripheral?) async {
    guard eligibility != .ineligible else { return }

    let p: CBPeripheral?
    if let provided { p = provided.peripheral }
    else { p = peripheral }

    guard let peripheral = p else {
      // We might still be waiting for scan discovery.
      return
    }

    self.peripheral = peripheral
    await central.connect(UncheckedPeripheral(peripheral: peripheral), options: nil)
  }

  private func beginGATTDiscovery() async {
    guard let peripheral else { return }

    // Reset caches before discovery.
    characteristicsByUUID.removeAll()
    servicesByUUID.removeAll()

    scheduleHandshakeTimeout()
    peripheral.discoverServices(profile.requiredServices.map(\.cb))
  }

  private func subscribeNotifications() async {
    guard let peripheral else { return }
    for uuid in profile.notifyCharacteristics {
      if let c = characteristicsByUUID[uuid.cb] {
        peripheral.setNotifyValue(true, for: c)
      }
    }
  }

  private func scheduleHandshakeTimeout() {
    handshakeTimeoutTask?.cancel()
    handshakeTimeoutTask = Task { [timeout = config.handshakeTimeout, pipe = inboundPipe] in
      try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
      pipe.send(.handshakeTimeout)
    }
  }

  // MARK: - Reconnect

  private func scheduleReconnect(after delay: TimeInterval) {
    reconnectTask?.cancel()
    reconnectTask = Task { [pipe = inboundPipe] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      pipe.send(.reconnectTimerFired)
    }
  }

  // MARK: - Writes

  private func flushOutboundIfPossible() {
    guard let peripheral else { return }

    let canUseWithoutResponse = readyToSendWithoutResponse
    while let (chunk, useWithoutResponse) = scheduler.dequeueNext(canUseWithoutResponse: canUseWithoutResponse) {
      let targetUUID = chunk.characteristic.cb
      let target = characteristicsByUUID[targetUUID] ?? characteristicsByUUID[profile.txCharacteristic.cb]
      guard let target else { return }
      let writeType: CBCharacteristicWriteType = useWithoutResponse ? .withoutResponse : .withResponse
      let maxLen = peripheral.maximumWriteValueLength(for: writeType)
      if chunk.payload.count > maxLen {
        // If MTU changed, re-fragment and re-enqueue at the front by splitting.
        let packet = OutgoingPacket(characteristic: chunk.characteristic, payload: chunk.payload, qos: chunk.qos, preference: chunk.preference)
        let refrag = PacketFragmenter.fragment(packet: packet, maxChunkSize: maxLen)
        _ = scheduler.enqueue(chunks: refrag)
        break
      }

      if useWithoutResponse {
        readyToSendWithoutResponse = false
      }

      peripheral.writeValue(chunk.payload, for: target, type: writeType)
      if writeType == .withResponse {
        // Wait for didWriteValue callback to continue; prevents flooding.
        break
      }
    }
  }

  private func maxWriteChunkSize(preferWithoutResponse: Bool) -> Int {
    guard let peripheral else { return 20 } // Safe default before connect.
    let type: CBCharacteristicWriteType = preferWithoutResponse ? .withoutResponse : .withResponse
    return peripheral.maximumWriteValueLength(for: type)
  }

  // MARK: - Delegate-event handling (GATT plumbing)

  private func handleEvent(_ event: DeviceEvent) async {
    switch event {
    case .didDiscoverServices(let error):
      guard error == nil else { return }
      guard let peripheral else { return }
      guard let services = peripheral.services else { return }
      for s in services {
        servicesByUUID[s.uuid] = s
        let required = profile.requiredCharacteristics(for: BLEUUID(s.uuid.uuidString)).map(\.cb)
        if !required.isEmpty {
          peripheral.discoverCharacteristics(required, for: s)
        }
      }

    case .didDiscoverCharacteristics(let service, let error):
      guard error == nil else { return }
      guard peripheral != nil else { return }
      let svc = service.service
      guard let chars = svc.characteristics else { return }
      for c in chars {
        characteristicsByUUID[c.uuid] = c
      }

      // If we've discovered all required characteristics, subscribe and consider ready.
      if isProfileSatisfied() {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        await subscribeNotifications()
        lifecyclePipe.send(.ready)
        flushOutboundIfPossible()
      }

    case .didUpdateValue(let characteristicBox, let error):
      guard error == nil else { return }
      // Application can attach protocol decoding by observing raw notifications via a higher-level stream.
      // This engine leaves decoding to layers above; still, this callback is a hotspot and should do minimal work.
      _ = characteristicBox.characteristic.value

    default:
      break
    }

    // Keep non-GATT side effects handled in the previous switch.
    await handleNonGATTEventSideEffects(event)
  }

  /// Non-GATT side effects (connection lifecycle, credits, retry counters).
  private func handleNonGATTEventSideEffects(_ event: DeviceEvent) async {
    switch event {
    case .didConnect(let p):
      peripheral = p.peripheral
      readyToSendWithoutResponse = true
      attempt = max(1, attempt)
      logger.log(.info, "connected", metadata: ["device": id.uuidString])

    case .didDisconnect:
      peripheral = nil
      characteristicsByUUID.removeAll()
      servicesByUUID.removeAll()
      readyToSendWithoutResponse = false
      attempt += 1
      lifecyclePipe.send(.disconnected)

    case .didFailToConnect:
      peripheral = nil
      attempt += 1

    case .isReadyToSendWriteWithoutResponse:
      readyToSendWithoutResponse = true
      scheduler.replenishWithoutResponseCredits(8)
      flushOutboundIfPossible()

    case .didWriteValue:
      flushOutboundIfPossible()

    default:
      break
    }
  }

  private func isProfileSatisfied() -> Bool {
    for svc in profile.requiredServices {
      let serviceCB = svc.cb
      guard servicesByUUID[serviceCB] != nil else { return false }
      for c in profile.requiredCharacteristics(for: svc) {
        guard characteristicsByUUID[c.cb] != nil else { return false }
      }
    }
    return characteristicsByUUID[profile.txCharacteristic.cb] != nil
  }
}
