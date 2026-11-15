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

/// Fails the build on `try?` and on an empty `catch` (AGENTS.md, Errors).
let errorCheck: [Target.PluginUsage] = [.plugin(name: "SwallowedErrorCheck", package: "swallowed-error-check")]

let package = Package(
  name: "AIOpenAI",
  platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9)],
  products: [.library(name: "AIOpenAI", targets: ["AIOpenAI"])],
  dependencies: [.package(path: "../ai-core"), .package(path: "../../model-board"), .package(path: "../../swallowed-error-check")],
  targets: [
    .target(name: "AIOpenAI", dependencies: [.product(name: "AI", package: "ai-core"), .product(name: "ModelBoard", package: "model-board")], swiftSettings: swiftSettings, plugins: errorCheck),
    .testTarget(
      name: "AIOpenAITests",
      dependencies: [.product(name: "AI", package: "ai-core"), .product(name: "ModelBoard", package: "model-board"), "AIOpenAI"],
      swiftSettings: swiftSettings,
      plugins: errorCheck
    ),
  ],
  swiftLanguageModes: [.v6]
)
