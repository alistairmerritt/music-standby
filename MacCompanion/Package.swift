// swift-tools-version: 6.0
import PackageDescription

// The Mac companion. `swift build` / `swift test` work with Xcode selected.
// The app bundle itself is assembled by scripts/build.sh, which needs no
// SwiftPM: SwiftPM can't make an .app with an Info.plist.
let package = Package(
    name: "MacCompanion",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CompanionCore", targets: ["CompanionCore"]),
        .executable(name: "MusicStandBy", targets: ["MusicStandBy"]),
        .executable(name: "msbctl", targets: ["msbctl"]),
    ],
    dependencies: [.package(path: "../Shared/StandByProtocol")],
    targets: [
        .target(name: "CompanionCore", dependencies: [.product(name: "StandByProtocol", package: "StandByProtocol")]),
        .executableTarget(name: "MusicStandBy", dependencies: ["CompanionCore"]),
        .executableTarget(name: "msbctl", dependencies: ["CompanionCore"]),
        .testTarget(name: "CompanionCoreTests", dependencies: ["CompanionCore"]),
    ]
)
