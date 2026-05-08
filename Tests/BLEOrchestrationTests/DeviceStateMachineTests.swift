import CoreBluetooth
import XCTest

@testable import BLEOrchestration

final class DeviceStateMachineTests: XCTestCase {
  func test_disconnect_fromReady_entersBackingOff_withScheduleReconnectEffect() {
    let state: DeviceState = .ready
    let (next, effects) = DeviceStateMachine.reduce(
      state: state,
      event: .didDisconnect(error: nil),
      eligibility: .pinned,
      attempt: 3,
      backoffDelay: { _ in 1.0 }
    )

    guard case .backingOff(let attempt, let delay) = next else {
      return XCTFail("Expected backingOff")
    }
    XCTAssertEqual(attempt, 3)
    XCTAssertEqual(delay, 1.0)
    XCTAssertTrue(effects.contains(where: { if case .scheduleReconnect = $0 { return true } else { return false } }))
  }
}
