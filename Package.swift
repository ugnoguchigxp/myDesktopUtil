// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "DeskAgent",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "DeskCore", targets: ["DeskCore"]),
    .executable(name: "desk-agent", targets: ["DeskAgent"]),
  ],
  targets: [
    .target(
      name: "DeskCore"
    ),
    .executableTarget(
      name: "DeskAgent",
      dependencies: ["DeskCore"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("ApplicationServices"),
        .linkedFramework("Carbon"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("EventKit"),
        .linkedFramework("Security"),
        .linkedFramework("ServiceManagement"),
      ]
    ),
    .testTarget(
      name: "DeskCoreTests",
      dependencies: ["DeskCore"]
    ),
    .testTarget(
      name: "DeskAgentTests",
      dependencies: ["DeskAgent", "DeskCore"]
    ),
  ]
)
