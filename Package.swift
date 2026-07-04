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
    ],
    targets: [
        .target(
            name: "Cohorly",
            path: "Sources/Cohorly"
        ),
        .testTarget(
            name: "CohorlyTests",
            dependencies: ["Cohorly"],
            path: "Tests/CohorlyTests"
        ),
    ]
)
