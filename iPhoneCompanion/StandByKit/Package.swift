// swift-tools-version: 6.0
import PackageDescription

// Platform-neutral logic shared by the app and the Now Playing extension.
// macOS is listed only so `swift test` can run without an iOS SDK.
let package = Package(
    name: "StandByKit",
    platforms: [.iOS("27.0"), .macOS(.v14)],
    products: [.library(name: "StandByKit", targets: ["StandByKit"])],
    targets: [
        .target(name: "StandByKit"),
        .testTarget(name: "StandByKitTests", dependencies: ["StandByKit"]),
    ]
)
