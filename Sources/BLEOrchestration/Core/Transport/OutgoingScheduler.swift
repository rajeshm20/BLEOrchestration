import Foundation

/// Scheduler implementing fairness, backpressure, and QoS for outbound traffic.
///
/// Design notes:
/// - Bounded queues prevent unbounded RAM growth under radio stalls.
/// - Credit-based flow-control avoids saturating `writeWithoutResponse` and starving the delegate queue.
/// - QoS ensures heartbeats/control are not blocked behind bulk sync.
final class OutgoingScheduler: @unchecked Sendable {
  struct Limits: Sendable {
    var maxQueueDepthRealtime: Int
    var maxQueueDepthInteractive: Int
    var maxQueueDepthBulk: Int

    public init(maxQueueDepthRealtime: Int = 256, maxQueueDepthInteractive: Int = 512, maxQueueDepthBulk: Int = 1024) {
      self.maxQueueDepthRealtime = max(1, maxQueueDepthRealtime)
      self.maxQueueDepthInteractive = max(1, maxQueueDepthInteractive)
      self.maxQueueDepthBulk = max(1, maxQueueDepthBulk)
    }

    func limit(for qos: PacketQoS) -> Int {
      switch qos {
      case .realtime: return maxQueueDepthRealtime
      case .interactive: return maxQueueDepthInteractive
      case .bulk: return maxQueueDepthBulk
      }
    }
  }

  enum EnqueueResult: Sendable, Equatable {
    case enqueued
    case droppedQueueFull
  }

  private let lock = NSLock()
  private let limits: Limits

  private var queues: [PacketQoS: [WriteChunk]] = [
    .realtime: [],
    .interactive: [],
    .bulk: [],
  ]

  private var withoutResponseCredits: Int = 0

  init(limits: Limits) {
    self.limits = limits
  }

  func setInitialWithoutResponseCredits(_ credits: Int) {
    lock.lock()
    withoutResponseCredits = max(0, credits)
    lock.unlock()
  }

  func replenishWithoutResponseCredits(_ delta: Int = 1) {
    lock.lock()
    withoutResponseCredits = max(0, withoutResponseCredits + delta)
    lock.unlock()
  }

  func enqueue(chunks: [WriteChunk]) -> EnqueueResult {
    lock.lock()
    defer { lock.unlock() }

    for chunk in chunks {
      let limit = limits.limit(for: chunk.qos)
      if queues[chunk.qos, default: []].count >= limit {
        return .droppedQueueFull
      }
      queues[chunk.qos, default: []].append(chunk)
    }
    return .enqueued
  }

  /// Dequeues the next chunk based on QoS and runtime ability to send `writeWithoutResponse`.
  ///
  /// - Returns: `(chunk, useWithoutResponse)` if available.
  func dequeueNext(canUseWithoutResponse: Bool) -> (WriteChunk, Bool)? {
    lock.lock()
    defer { lock.unlock() }

    func pop(from qos: PacketQoS) -> WriteChunk? {
      guard var q = queues[qos], !q.isEmpty else { return nil }
      let head = q.removeFirst()
      queues[qos] = q
      return head
    }

    // Strict priority: realtime > interactive > bulk.
    guard let chunk = pop(from: .realtime) ?? pop(from: .interactive) ?? pop(from: .bulk) else { return nil }

    let preferWithout: Bool
    switch chunk.preference {
    case .withResponse:
      preferWithout = false
    case .withoutResponse:
      preferWithout = true
    case .automatic:
      preferWithout = canUseWithoutResponse
    }

    if preferWithout, canUseWithoutResponse, withoutResponseCredits > 0 {
      withoutResponseCredits -= 1
      return (chunk, true)
    }
    return (chunk, false)
  }

  func snapshotQueueDepths() -> [PacketQoS: Int] {
    lock.lock()
    defer { lock.unlock() }
    return queues.mapValues { $0.count }
  }
}
