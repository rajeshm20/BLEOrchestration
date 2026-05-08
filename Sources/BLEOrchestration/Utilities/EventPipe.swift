import Foundation

/// A minimal-overhead event channel for bridging non-async callback contexts into async consumption.
///
/// Delegate callbacks enqueue events onto a dedicated serial queue and `yield` to an `AsyncStream`
/// continuation. This avoids creating a `Task` per callback, which can be a measurable overhead
/// for high-frequency notification traffic.
final class EventPipe<Event: Sendable>: @unchecked Sendable {
  private let queue: DispatchQueue
  private var continuation: AsyncStream<Event>.Continuation?

  let stream: AsyncStream<Event>

  init(label: String) {
    self.queue = DispatchQueue(label: label, qos: .userInitiated)
    var localContinuation: AsyncStream<Event>.Continuation?
    self.stream = AsyncStream<Event> { cont in
      cont.onTermination = { _ in }
      localContinuation = cont
    }
    self.continuation = localContinuation
  }

  func send(_ event: Event) {
    queue.async { [weak self] in
      _ = self?.continuation?.yield(event)
    }
  }

  func finish() {
    queue.async { [weak self] in
      self?.continuation?.finish()
      self?.continuation = nil
    }
  }
}

