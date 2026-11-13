// swift-tools-version: 6.4
import PackageDescription

let swiftSettings: [SwiftSetting] = [
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances"),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
  name: "AIAnthropic",
  platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9)],
  products: [.library(name: "AIAnthropic", targets: ["AIAnthropic"])],
  dependencies: [.package(path: "../ai-core"), .package(path: "../../model-board")],
  targets: [
    .target(name: "AIAnthropic", dependencies: [.product(name: "AI", package: "ai-core"), .product(name: "ModelBoard", package: "model-board")], swiftSettings: swiftSettings),
    .testTarget(
      name: "AIAnthropicTests",
      dependencies: [.product(name: "AI", package: "ai-core"), .product(name: "ModelBoard", package: "model-board"), "AIAnthropic"],
      swiftSettings: swiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
