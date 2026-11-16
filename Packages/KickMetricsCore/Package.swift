// swift-tools-version: 6.0
import PackageDescription

// Platform-independent measurement core. Foundation only, so it builds and is
// tested on Linux as well as Apple platforms.
let package = Package(
    name: "KickMetricsCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "KickMetricsCore", targets: ["KickMetricsCore"]),
    ],
    targets: [
        .target(name: "KickMetricsCore"),
        .testTarget(name: "KickMetricsCoreTests", dependencies: ["KickMetricsCore"]),
    ]
)
