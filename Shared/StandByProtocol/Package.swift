// swift-tools-version: 6.0
import PackageDescription

// The wire contract between the Mac companion, the relay and the iPhone app.
// Platform-neutral: Foundation and CryptoKit only.
let package = Package(
    name: "StandByProtocol",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "StandByProtocol", targets: ["StandByProtocol"])],
    targets: [
        .target(name: "StandByProtocol"),
        .testTarget(name: "StandByProtocolTests", dependencies: ["StandByProtocol"]),
    ]
)
