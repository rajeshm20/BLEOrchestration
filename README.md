## Install with Swift Package Manager

### Xcode

1. In Xcode, go to **File > Add Package Dependencies...**
2. Enter this repository URL.
3. Select the version you want to use.
4. Add `BLEorchestration` to your app target.

### Package.swift

```swift
dependencies: [
  .package(url: "https://github.com/rajeshm20/BLEOrchestration.git")
]
```

Then add the product to your target dependencies:

```swift
.package(
    url: "https://github.com/yourname/bleorchestration.git",
    branch: "main"
)
```
---



# BLE Connection Orchestration Engine (CoreBluetooth, iOS 15) — Design

**Date:** 2026-05-08  
**Target:** iOS 15+  
**Primary goals:** Maintain stable concurrent connections (10+ wearables), reconnection resilience, high packet throughput under mixed device capabilities, strong isolation and determinism via actors, CoreBluetooth delegate isolation, and background restoration via `CBCentralManagerOptionRestoreIdentifierKey`.
---

## 1. Scope

### In-scope

- Concurrent connections to **10+** BLE peripherals (wearables).
- Two acquisition modes:
  - **Known device reconnect** by persisted peripheral UUID (use `retrievePeripherals(withIdentifiers:)`).
  - **Rediscovery via scanning** (for devices not currently retrievable).
- Connection policies:
  - **Pinned set** (always keep connected when possible).
  - **Dynamic pool** (connect up to max-concurrency based on priority scoring).
  - Both policies can be active simultaneously.
- Robust reconnection:
  - Retry budgets and jittered exponential backoff.
  - Gating to avoid fleet-wide thrash and radio starvation.
- Packet throughput optimization:
  - Per-device scheduling, credit/backpressure for `writeWithoutResponse`.
  - QoS queues, bounded buffering, fairness across devices.
- Background behavior:
  - `bluetooth-central` background mode expected.
  - CoreBluetooth **state restoration** using `CBCentralManagerOptionRestoreIdentifierKey`.
  - Restoration rebinds `CBPeripheral` instances to per-device actors.

### Explicit non-goals (for this engine)

- UI / pairing screens / onboarding UX.
- Firmware update flows (DFU) unless later layered on top.
- Cross-process sharing of BLE resources.
- Security protocol design (assumes BLE pairing/bonding managed by iOS + device).

---

## 2. Architectural Overview (Approach A: Actor-first)

### 2.1 Ownership model (single responsibility)

- `BLEOrchestratorActor` (public façade + policy brain)
  - Owns lifecycle (`start/stop`), pinned/dynamic policy decisions, and max concurrency.
  - Routes app intents to device sessions.
  - Emits device lifecycle and decoded protocol events.

- `BLECentralActor` (CoreBluetooth owner)
  - The *only* owner allowed to call `CBCentralManager` APIs: scan/connect/cancel/retrieve.
  - Accepts delegate events from the proxy, translates them to device/central events.

- `DeviceConnectionActor` (per peripheral UUID)
  - Single device authority: state machine, discovery, subscriptions, transport, retries.
  - Owns per-device timers (timeouts, keepalive, backoff deadlines).

- `CoreBluetoothDelegateProxy` (delegate isolation boundary)
  - A single `NSObject` implementing `CBCentralManagerDelegate` and `CBPeripheralDelegate`.
  - Performs no business logic and minimal work inside callbacks.
  - Forwards typed events asynchronously into `BLECentralActor` / `DeviceConnectionActor`.

### 2.2 Protocol-oriented boundaries (testability, SOLID)

- `CentralControlling`
  - Scan/retrieve/connect/cancel abstractions for CoreBluetooth.
- `PeripheralControlling`
  - Wrapper surface for `CBPeripheral` interactions that need to be mocked in tests.
- `BackoffScheduling`
  - Strategy for next retry time and retry budget classification.
- `PacketTransporting`
  - Transport for framed payloads and backpressure signals.
- `StatePersisting`
  - Persists pinned UUIDs and minimal metadata required for restoration rehydration.

---

## 3. Device State Machine

### 3.1 State set (core)

Each `DeviceConnectionActor` owns a `DeviceState` value and transitions only through a reducer.

- `idle` — known device, not attempting connection.
- `resolving` — attempting to obtain a `CBPeripheral` via retrieve and/or scan match.
- `connecting` — `CBCentralManager.connect` in-flight.
- `discovering` — service/characteristic discovery + notification subscription.
- `ready` — transport open and validated; protocol handlers active.
- `degraded(reason)` — partial loss (e.g. notify disabled, timeouts); may self-heal or reconnect.
- `backingOff(attempt, nextDeadline)` — reconnect suppressed until deadline (jittered backoff).
- `suspended(reason)` — Bluetooth off/unauthorized/app stop; no connection attempts.

### 3.2 Events (normalized)

Events are normalized to a small set to keep transitions deterministic.

- Central-level:
  - `centralStateChanged(CBManagerState)`
  - `didConnect`
  - `didFailToConnect(Error?)`
  - `didDisconnect(Error?)`
  - `willRestoreState([CBPeripheral], …)`
- Peripheral-level:
  - `didDiscoverServices(Error?)`
  - `didDiscoverCharacteristics(service, Error?)`
  - `didUpdateValue(characteristic, Error?)`
  - `didWriteValue(characteristic, Error?)`
  - `isReadyToSendWriteWithoutResponse`
- Internal:
  - `timeout(kind)`
  - `policyUpdated(pinned/priority/maxConcurrency)`
  - `transportBackpressureChanged`

### 3.3 Reducer + effects

- Reducer signature:
  - `reduce(state:event:) -> (newState, [Effect])`
- Effects are intent-like (e.g., connect, start discovery, subscribe notify, schedule retry).
- The actor executes effects serially, ensuring CoreBluetooth API ordering and eliminating reentrancy hazards.

---

## 4. Reconnection Strategy + Gating

### 4.1 Reconnect controller

Per device, a `ReconnectController`:

- Classifies failures:
  - `transient` (radio/link loss)
  - `bluetoothOff` / `unauthorized`
  - `protocol` (e.g., missing characteristic / handshake mismatch)
  - `unknown`
- Applies retry budgets:
  - Faster initial retry for transient disconnects.
  - Exponential backoff with jitter for repeated failures.
  - Cooldown/circuit-break behavior on repeated protocol failures.

### 4.2 Reconnect gating

Suppress reconnect attempts when any is true:

- Central not `.poweredOn`
- Engine is stopped/suspended by app
- Device not currently eligible (un-pinned and outside dynamic pool)
- Restoration in progress for that device (avoid duplicate connect)

---

## 5. Throughput + Packet Transport

### 5.1 Outgoing scheduler (per device)

`OutgoingScheduler` responsibilities:

- Bounded per-QoS queues (prevents unbounded growth).
- Flow-control for `writeWithoutResponse` using a **credit** model:
  - Credits replenished via `peripheralIsReady(toSendWriteWithoutResponse:)`.
- Runtime selection of write type:
  - Prefer `withoutResponse` when supported and credits available.
  - Fall back to `withResponse` when required.
- Fairness:
  - Prevent a single device from starving others by applying per-device pacing and global policy knobs.

### 5.2 Incoming pipeline

- Framing + reassembly (MTU-aware fragmentation).
- Validation (length/CRC if the protocol uses it).
- Decode + dispatch to protocol handlers.

### 5.3 Tuning knobs (policy)

- Per-device class config:
  - max in-flight writes
  - max queue depth per QoS class
  - heartbeat interval
  - optional coalescing window (feature flagged per device type)

---

## 6. Delegate Isolation + Threading Rules

- Delegate proxy does minimal work inside callbacks:
  - capture references/identifiers
  - forward events to actors via nonblocking handoff
- Actors own all ordering and side effects.
- No CoreBluetooth API calls from outside `BLECentralActor` and `DeviceConnectionActor` (enforced via access control and protocol boundaries).

---

## 7. Background Restoration

### 7.1 Central configuration

- Initialize `CBCentralManager` with:
  - `CBCentralManagerOptionRestoreIdentifierKey = <stable identifier>`
  - Optional: show power alert based on product requirements.

### 7.2 Restoration flow

- `centralManager(_:willRestoreState:)` receives restored `CBPeripheral`s.
- `RestorationCoordinator`:
  - matches restored peripherals to persisted known UUIDs
  - rebinds `CBPeripheral` instances to the corresponding `DeviceConnectionActor`
  - triggers “resume” effect (validate GATT, resubscribe notifications if needed)

---

## 8. Observability

Required metrics per device:

- connection state + timestamps
- reconnect attempt count + backoff deadline
- queue depth per QoS class
- write rate (per type), error counts, last error classification
- ready time (connect → ready latency)

Logs are structured and correlated with device UUID + session id.

---

## 9. Acceptance Criteria

- Maintains stable operation with **10+ concurrent** peripherals under:
  - intermittent disconnects
  - mixed `withResponse`/`withoutResponse` capabilities
  - background mode enabled
- No deadlocks/races in delegate → actor event handling.
- On app relaunch via state restoration, previously pinned devices are rehydrated and return to `ready` (when available) without user intervention.
