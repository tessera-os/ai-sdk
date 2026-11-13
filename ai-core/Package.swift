// swift-tools-version: 6.4
import PackageDescription

let swiftSettings: [SwiftSetting] = [
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances"),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
  name: "AI",
  platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9)],
  products: [.library(name: "AI", targets: ["AI"])],
  dependencies: [.package(path: "../../model-board")],
  targets: [
    .target(name: "AI", dependencies: [.product(name: "ModelBoard", package: "model-board")], swiftSettings: swiftSettings),
    .testTarget(
      name: "AITests",
      dependencies: ["AI", .product(name: "ModelBoard", package: "model-board")],
      swiftSettings: swiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
