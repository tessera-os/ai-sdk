// swift-tools-version: 6.4
import PackageDescription

let swiftSettings: [SwiftSetting] = [
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances"),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
  name: "AIOpenRouter",
  platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9)],
  products: [.library(name: "AIOpenRouter", targets: ["AIOpenRouter"])],
  dependencies: [.package(path: "../ai-core"), .package(path: "../../model-board"), .package(path: "../openai")],
  targets: [
    .target(name: "AIOpenRouter", dependencies: [.product(name: "AI", package: "ai-core"), .product(name: "ModelBoard", package: "model-board"), .product(name: "AIOpenAI", package: "openai")], swiftSettings: swiftSettings),
    .testTarget(
      name: "AIOpenRouterTests",
      dependencies: [.product(name: "AI", package: "ai-core"), .product(name: "ModelBoard", package: "model-board"), "AIOpenRouter"],
      swiftSettings: swiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
