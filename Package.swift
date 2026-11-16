// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TileBandit",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TileBandit", targets: ["TileBandit"]),
        .executable(name: "TileBanditSleepGuard", targets: ["TileBanditSleepGuard"]),
    ],
    targets: [
        .executableTarget(name: "TileBandit", dependencies: ["SleepGuardKit"]),
        // The privileged helper behind "Stay Awake with Lid Closed": the one
        // part that runs as root, kept to a single file. `make app` puts it in
        // the bundle next to the app.
        .executableTarget(name: "TileBanditSleepGuard", dependencies: ["SleepGuardKit"]),
        // What the app and the helper share: the one-message interface, the
        // decisions (pure, so they can be tested) and the power readings.
        .target(name: "SleepGuardKit"),
        // The decisions of a switch that need no screen: what a workspace
        // remembers and which windows move to put its stack back. `swift test`.
        .testTarget(name: "TileBanditTests", dependencies: ["TileBandit", "SleepGuardKit"]),
    ]
)
