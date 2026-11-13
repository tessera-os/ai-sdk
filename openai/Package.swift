// swift-tools-version: 6.4
import PackageDescription

let swiftSettings: [SwiftSetting] = [
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances"),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
  name: "AIOpenAI",
  platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9)],
  products: [.library(name: "AIOpenAI", targets: ["AIOpenAI"])],
  dependencies: [.package(path: "../ai-core"), .package(path: "../../model-board")],
  targets: [
    .target(name: "AIOpenAI", dependencies: [.product(name: "AI", package: "ai-core"), .product(name: "ModelBoard", package: "model-board")], swiftSettings: swiftSettings),
    .testTarget(
      name: "AIOpenAITests",
      dependencies: [.product(name: "AI", package: "ai-core"), .product(name: "ModelBoard", package: "model-board"), "AIOpenAI"],
      swiftSettings: swiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
