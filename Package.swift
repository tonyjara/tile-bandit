// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TileBandit",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TileBandit", targets: ["TileBandit"])
    ],
    targets: [
        .executableTarget(name: "TileBandit"),
        // The decisions of a switch that need no screen: what a workspace
        // remembers and which windows move to put its stack back. `swift test`.
        .testTarget(name: "TileBanditTests", dependencies: ["TileBandit"]),
    ]
)
