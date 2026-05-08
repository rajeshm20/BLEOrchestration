@preconcurrency import CoreBluetooth
import Foundation

/// Public façade orchestrating a fleet of BLE device connections.
///
/// Responsibilities:
/// - Owns policy (pinned + dynamic pool)
/// - Creates and manages per-device actors
/// - Surfaces lifecycle events and observability
/// - Coordinates CoreBluetooth background restoration
public actor BLEOrchestrator {
  public struct Configuration {
    /// CoreBluetooth restoration identifier. Must be stable across launches.
    public var restorationIdentifier: String
    /// If true, the orchestrator will scan to discover dynamic candidates.
    public var enableScanning: Bool
    /// CoreBluetooth scan services filter (optional). Provide to reduce radio/CPU overhead.
    public var scanServices: [BLEUUID]?
    /// Upper bound on concurrent connections.
    public var maxConcurrentConnections: Int

    public init(
      restorationIdentifier: String,
      enableScanning: Bool = true,
      scanServices: [BLEUUID]? = nil,
      maxConcurrentConnections: Int = 12
    ) {
      self.restorationIdentifier = restorationIdentifier
      self.enableScanning = enableScanning
      self.scanServices = scanServices
      self.maxConcurrentConnections = max(1, maxConcurrentConnections)
    }
  }

  public enum Event: Sendable, Equatable {
    case deviceStateChanged(device: UUID, state: DeviceState)
    case deviceReady(device: UUID)
    case deviceDisconnected(device: UUID)
    case deviceSuspended(device: UUID, reason: SuspendReason)
    case discovered(candidate: DeviceCandidate)
  }

  public typealias ProfileProvider = @Sendable (DeviceHandle) -> any GATTProfile

  private let logger: BLELogging
  private let stateStore: StatePersisting
  private let scoring: any DeviceScoring
  private let profileProvider: ProfileProvider

  private let central: BLECentralActor

  private var policy: DevicePolicy
  private var candidates: [UUID: DeviceCandidate] = [:]
  private var deviceActors: [UUID: DeviceConnectionActor] = [:]

  private let eventPipe = EventPipe<Event>(label: "ble.orchestrator.events")
  public nonisolated var events: AsyncStream<Event> { eventPipe.stream }


  public init(
    configuration: Configuration,
    initialPolicy: DevicePolicy = .init(),
    profileProvider: @escaping ProfileProvider,
    stateStore: StatePersisting = UserDefaultsStateStore(),
    scoring: any DeviceScoring = DefaultDeviceScoring(),
    logger: BLELogging = NoopLogger()
  ) {
    self.logger = logger
    self.stateStore = stateStore
    self.scoring = scoring
    self.profileProvider = profileProvider
    self.policy = DevicePolicy(
      maxConcurrentConnections: configuration.maxConcurrentConnections,
      pinned: initialPolicy.pinned,
      allowDynamicPool: initialPolicy.allowDynamicPool
    )

    self.central = BLECentralActor(
      configuration: .init(
        restorationIdentifier: configuration.restorationIdentifier,
        showPowerAlert: true,
        scanServices: configuration.scanServices?.map(\.cb)
      ),
      logger: logger
    )

    if configuration.enableScanning {
      Task { [weak self, central] in
        guard let self else { return }
        for await candidate in central.discoveries {
          await self.handleDiscovery(candidate)
        }
      }
    }

    Task { [weak self] in
      guard let self else { return }
      await self.bootstrapPinnedFromStore()
      await self.reconcileConnections()
    }
  }

  // MARK: - Lifecycle

  /// Starts connecting devices based on current policy.
  public func start() async {
    // Ensure pinned devices exist and are started.
    await reconcileConnections()
    await central.startScan(allowDuplicates: false)
  }

  /// Stops the fleet and suspends reconnect attempts.
  public func stop() async {
    await central.stopScan()
    for (_, actor) in deviceActors {
      await actor.stop()
    }
  }

  // MARK: - Policy

  public func setMaxConcurrentConnections(_ maxConnections: Int) async {
    policy.maxConcurrentConnections = Swift.max(1, maxConnections)
    await reconcileConnections()
  }

  public func pin(_ id: UUID) async {
    policy.pinned.insert(id)
    try? stateStore.savePinned(policy.pinned)
    await ensureDeviceActorExists(for: id, eligibility: .pinned)
    await reconcileConnections()
  }

  public func unpin(_ id: UUID) async {
    policy.pinned.remove(id)
    try? stateStore.savePinned(policy.pinned)
    await reconcileConnections()
  }

  /// Allows callers to provide their own set of dynamic candidates (e.g., from a device directory).
  public func upsertCandidate(_ candidate: DeviceCandidate) async {
    candidates[candidate.id] = candidate
    await reconcileConnections()
  }

  // MARK: - Internal orchestration

  private func bootstrapPinnedFromStore() async {
    if let pinned = try? stateStore.loadPinned(), !pinned.isEmpty {
      policy.pinned.formUnion(pinned)
    }
  }

  private func handleDiscovery(_ candidate: DeviceCandidate) async {
    candidates[candidate.id] = candidate
    eventPipe.send(.discovered(candidate: candidate))
    await reconcileConnections()
  }

  /// Computes the desired connected set (pinned + top-N dynamic) and adjusts the fleet accordingly.
  private func reconcileConnections() async {
    let desired = computeDesiredDeviceIDs()

    // Create actors for desired set and start them.
    for id in desired {
      let eligibility: DeviceEligibility = policy.pinned.contains(id) ? .pinned : .dynamic(priority: 0)
      let actor = await ensureDeviceActorExists(for: id, eligibility: eligibility)
      await actor.start()
    }

    // For non-desired devices, suspend if they exist (but keep actor alive for quick reactivation).
    for (id, actor) in deviceActors where !desired.contains(id) {
      await actor.updateEligibility(.ineligible)
    }
  }

  private func computeDesiredDeviceIDs() -> Set<UUID> {
    var desired = policy.pinned
    guard policy.allowDynamicPool else { return desired }

    let remainingSlots = max(0, policy.maxConcurrentConnections - desired.count)
    guard remainingSlots > 0 else { return desired }

    let dynamicCandidates = candidates.values
      .filter { !policy.pinned.contains($0.id) }
      .map { ($0.id, scoring.score(candidate: $0)) }
      .sorted { $0.1 > $1.1 }
      .prefix(remainingSlots)
      .map(\.0)

    desired.formUnion(dynamicCandidates)
    return desired
  }

  @discardableResult
  private func ensureDeviceActorExists(for id: UUID, eligibility: DeviceEligibility) async -> DeviceConnectionActor {
    if let existing = deviceActors[id] {
      await existing.updateEligibility(eligibility)
      return existing
    }

    let handle = DeviceHandle(id: id, kind: candidates[id]?.kind)
    let profile = profileProvider(handle)

    let actor = DeviceConnectionActor(
      id: id,
      eligibility: eligibility,
      central: central,
      profile: profile,
      logger: logger
    )

    deviceActors[id] = actor

    Task { [weak self] in
      guard let self else { return }
      for await e in actor.lifecycle {
        await self.forwardLifecycleEvent(device: id, event: e)
      }
    }

    return actor
  }

  private func forwardLifecycleEvent(device: UUID, event: DeviceConnectionActor.LifecycleEvent) async {
    switch event {
    case .stateChanged(let state):
      eventPipe.send(.deviceStateChanged(device: device, state: state))
    case .ready:
      eventPipe.send(.deviceReady(device: device))
    case .disconnected:
      eventPipe.send(.deviceDisconnected(device: device))
    case .suspended(let reason):
      eventPipe.send(.deviceSuspended(device: device, reason: reason))
    }
  }
}
