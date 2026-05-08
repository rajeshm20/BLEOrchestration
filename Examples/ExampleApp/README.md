# ExampleApp

Minimal SwiftUI iOS example showing how to integrate the `BLEOrchestration` package.

## Open & run

1. Open `Examples/ExampleApp/ExampleApp.xcodeproj` in Xcode.
2. Select an iOS 15+ device/simulator.
3. Ensure your app target has:
   - **Background Modes** → **Uses Bluetooth LE accessories** (`bluetooth-central`)
   - **Info.plist** Bluetooth usage strings as required by your product
4. Build & Run.

## What it demonstrates

- Creating `BLEOrchestrator` with a stable restoration identifier
- Providing a `GATTProfile` (placeholder UUIDs you replace with your device’s)
- Pin/unpin and listening to orchestrator `events`

