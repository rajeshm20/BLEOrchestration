import SwiftUI
import BLEOrchestration

struct ContentView: View {
  @State private var logs: [String] = []
  @State private var pinnedUUIDString: String = ""
  @State private var orchestrator: BLEOrchestrator?

  var body: some View {
    NavigationView {
      VStack(spacing: 16) {
        TextField("Pinned peripheral UUID", text: $pinnedUUIDString)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .textFieldStyle(.roundedBorder)

        HStack {
          Button("Start") { Task { await start() } }
          Button("Stop") { Task { await orchestrator?.stop() } }
        }

        HStack {
          Button("Pin") { Task { await pin() } }
          Button("Unpin") { Task { await unpin() } }
        }

        List(logs.reversed(), id: \.self) { line in
          Text(line).font(.system(.footnote, design: .monospaced))
        }
      }
      .padding()
      .navigationTitle("BLE Example")
    }
  }

  private func start() async {
    if orchestrator == nil {
      orchestrator = BLEOrchestrator(
        configuration: .init(
          restorationIdentifier: "com.example.ble.orchestrator",
          enableScanning: true,
          scanServices: nil,
          maxConcurrentConnections: 12
        ),
        profileProvider: { handle in
          // Replace with your real device-specific profile selection logic.
          ExampleGATTProfile()
        }
      )

      if let orchestrator {
        Task {
          for await event in orchestrator.events {
            await MainActor.run {
              logs.append("\(event)")
            }
          }
        }
      }
    }

    await orchestrator?.start()
  }

  private func pin() async {
    guard let id = UUID(uuidString: pinnedUUIDString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      logs.append("Invalid UUID")
      return
    }
    await orchestrator?.pin(id)
  }

  private func unpin() async {
    guard let id = UUID(uuidString: pinnedUUIDString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      logs.append("Invalid UUID")
      return
    }
    await orchestrator?.unpin(id)
  }
}

private struct ExampleGATTProfile: GATTProfile {
  // Placeholder UUIDs — replace with your real wearable’s GATT UUIDs.
  let requiredServices: [BLEUUID] = ["180D"] // e.g., Heart Rate service (example only)

  func requiredCharacteristics(for service: BLEUUID) -> [BLEUUID] {
    switch service.string.uppercased() {
    case "180D":
      return ["2A37"] // Heart Rate Measurement (notify) (example only)
    default:
      return []
    }
  }

  // For real devices, choose a writable characteristic used for TX.
  let txCharacteristic: BLEUUID = "2A39" // Control Point (example only; may not exist)

  let notifyCharacteristics: [BLEUUID] = ["2A37"]
}

