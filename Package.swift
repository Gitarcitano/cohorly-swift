// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Cohorly",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "Cohorly",
            targets: ["Cohorly"]
        ),
        // Optional native crash reporting (ADR-0020). A separate product so
        // `Cohorly` never links KSCrash.
        .library(
            name: "CohorlyCrash",
            targets: ["CohorlyCrash"]
        ),
        // Optional session replay: $session_id, sampling and the chunk queue.
        // A separate product so an app without it carries no replay code.
        .library(
            name: "CohorlyReplay",
            targets: ["CohorlyReplay"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/kstenerud/KSCrash.git", from: "2.6.1"),
    ],
    targets: [
        .target(
            name: "Cohorly",
            path: "Sources/Cohorly"
        ),
        .target(
            name: "CohorlyCrash",
            dependencies: [
                "Cohorly",
                .product(name: "Recording", package: "KSCrash"),
            ],
            path: "Sources/CohorlyCrash"
        ),
        .target(
            name: "CohorlyReplay",
            dependencies: ["Cohorly"],
            path: "Sources/CohorlyReplay",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .testTarget(
            name: "CohorlyTests",
            dependencies: ["Cohorly"],
            path: "Tests/CohorlyTests"
        ),
        .testTarget(
            name: "CohorlyCrashTests",
            dependencies: ["CohorlyCrash", "Cohorly"],
            path: "Tests/CohorlyCrashTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "CohorlyReplayTests",
            dependencies: ["CohorlyReplay", "Cohorly"],
            path: "Tests/CohorlyReplayTests"
        ),
    ]
)
