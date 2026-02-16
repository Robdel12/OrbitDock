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
    .executable(
      name: "orbitdock-cli",
      targets: ["OrbitDockCLI"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/stephencelis/SQLite.swift", from: "0.15.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
  ],
  targets: [
    .target(
      name: "OrbitDockCore",
      dependencies: [
        .product(name: "SQLite", package: "SQLite.swift"),
      ]
    ),
    .executableTarget(
      name: "OrbitDockCLI",
      dependencies: [
        "OrbitDockCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "Sources/OrbitDockCLI"
    ),
  ]
)
