// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "MpTracker",
    platforms: [
        .iOS(.v12)
    ],
    products: [
        .library(name: "MpTracker", targets: ["MpTracker"])
    ],
    targets: [
        .target(
            name: "MpTracker",
            path: "Sources/MpTracker"
        ),
        .testTarget(name: "MpTrackerTests", dependencies: ["MpTracker"], path: "Tests/MpTrackerTests")
    ]
)
