// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "OrbitDockCore",
  platforms: [
    .macOS(.v14),
  ],
  products: [
    .library(
      name: "OrbitDockCore",
      targets: ["OrbitDockCore"]
    ),
  ],
  dependencies: [],
  targets: [
    .target(
      name: "OrbitDockCore",
      dependencies: []
    ),
  ]
)
