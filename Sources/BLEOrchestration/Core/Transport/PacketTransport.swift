@preconcurrency import CoreBluetooth
import Foundation

/// QoS class for outbound BLE traffic.
public enum PacketQoS: Int, Sendable, CaseIterable {
  /// Heartbeats and time-sensitive control signals.
  case realtime = 0
  /// Interactive control traffic (commands, ACKs).
  case interactive = 1
  /// Bulk transfer (telemetry history, sync, etc).
  case bulk = 2
}

/// Describes the intended write type.
public enum WritePreference: Sendable {
  /// Use write-with-response when possible (more reliable, lower throughput).
  case withResponse
  /// Use write-without-response when possible (higher throughput, must manage backpressure).
  case withoutResponse
  /// Let the scheduler decide based on runtime conditions and device capabilities.
  case automatic
}

/// An outbound logical packet to be delivered to a characteristic identified by UUID.
public struct OutgoingPacket: Sendable {
  public let characteristic: BLEUUID
  public let payload: Data
  public let qos: PacketQoS
  public let preference: WritePreference

  public init(characteristic: BLEUUID, payload: Data, qos: PacketQoS, preference: WritePreference = .automatic) {
    self.characteristic = characteristic
    self.payload = payload
    self.qos = qos
    self.preference = preference
  }
}

/// Represents a single BLE write operation (already fragmented to MTU).
struct WriteChunk: Sendable {
  let characteristic: BLEUUID
  let payload: Data
  let qos: PacketQoS
  let preference: WritePreference
}

/// MTU-aware packet fragmentation.
///
/// - Note: iOS does not expose negotiated ATT MTU directly, but the effective maximum write length
///   is available via `CBPeripheral.maximumWriteValueLength(for:)`.
struct PacketFragmenter: Sendable {
  static func fragment(packet: OutgoingPacket, maxChunkSize: Int) -> [WriteChunk] {
    guard maxChunkSize > 0 else { return [] }
    guard packet.payload.count > maxChunkSize else {
      return [WriteChunk(characteristic: packet.characteristic, payload: packet.payload, qos: packet.qos, preference: packet.preference)]
    }

    var chunks: [WriteChunk] = []
    chunks.reserveCapacity((packet.payload.count / maxChunkSize) + 1)

    var offset = 0
    while offset < packet.payload.count {
      let end = min(packet.payload.count, offset + maxChunkSize)
      let slice = packet.payload.subdata(in: offset..<end)
      chunks.append(WriteChunk(characteristic: packet.characteristic, payload: slice, qos: packet.qos, preference: packet.preference))
      offset = end
    }
    return chunks
  }
}
