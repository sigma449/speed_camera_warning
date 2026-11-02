// swift-tools-version:5.9
// SpeedCamCore：不依賴 Apple 專屬框架的核心邏輯（只用 Foundation），
// 可以在 Linux（Docker swift 映像、GitHub Actions ubuntu）上直接跑 `swift test`。
import PackageDescription

let package = Package(
    name: "SpeedCamCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "SpeedCamCore", targets: ["SpeedCamCore"]),
    ],
    targets: [
        .target(
            name: "SpeedCamCore",
            path: "Sources/SpeedCamCore"
        ),
        .testTarget(
            name: "SpeedCamCoreTests",
            dependencies: ["SpeedCamCore"],
            path: "Tests/SpeedCamCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
