// swift-tools-version: 6.0
import PackageDescription

// Platform-neutral logic shared by the app and the Now Playing extension.
// macOS is listed only so `swift test` can run without an iOS SDK.
let package = Package(
    name: "StandByKit",
    platforms: [.iOS("27.0"), .macOS(.v14)],
    products: [.library(name: "StandByKit", targets: ["StandByKit"])],
    dependencies: [.package(path: "../../Shared/StandByProtocol")],
    targets: [
        .target(
            name: "StandByKit",
            dependencies: [.product(name: "StandByProtocol", package: "StandByProtocol")],
            // The demo's album covers, from madewithmerritt.com/second-chair/ (16 November 2026).
            resources: [.copy("Resources/DemoArtwork")]
        ),
        .testTarget(name: "StandByKitTests", dependencies: ["StandByKit"]),
    ]
)
