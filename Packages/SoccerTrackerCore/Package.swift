// swift-tools-version: 6.0
import PackageDescription

// Platform-independent measurement core. Foundation only, so it builds and is
// tested on Linux as well as Apple platforms.
let package = Package(
    name: "SoccerTrackerCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SoccerTrackerCore", targets: ["SoccerTrackerCore"]),
    ],
    targets: [
        .target(name: "SoccerTrackerCore"),
        .testTarget(name: "SoccerTrackerCoreTests", dependencies: ["SoccerTrackerCore"]),
    ]
)
