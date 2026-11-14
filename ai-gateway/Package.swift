// swift-tools-version: 6.4
import PackageDescription

/// The AI SDK's release version, the same in its five packages. CI
/// releases it when it names the current release week (RELEASES.md).
let version: String = "26.10.4"

let swiftSettings: [SwiftSetting] = [
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances"),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
  name: "ai-gateway",
  platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9)],
  products: [.library(name: "AIGateway", targets: ["AIGateway"])],
  dependencies: [.package(path: "../ai-core"), .package(path: "../../model-board")],
  targets: [
    .target(name: "AIGateway", dependencies: [.product(name: "AI", package: "ai-core"), .product(name: "ModelBoard", package: "model-board")], swiftSettings: swiftSettings),
    .testTarget(
      name: "AIGatewayTests",
      dependencies: [.product(name: "AI", package: "ai-core"), .product(name: "ModelBoard", package: "model-board"), "AIGateway"],
      swiftSettings: swiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
