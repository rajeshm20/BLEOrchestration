// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "BLEOrchestration",
  platforms: [
    .iOS(.v15),
    .macOS(.v10_15)
  ],
  products: [
    .library(name: "BLEOrchestration", targets: ["BLEOrchestration"])
  ],
  targets: [
    .target(name: "BLEOrchestration"),
    .testTarget(name: "BLEOrchestrationTests", dependencies: ["BLEOrchestration"]),
  ]
)
