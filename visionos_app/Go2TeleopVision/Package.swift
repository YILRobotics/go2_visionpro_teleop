// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Go2TeleopVision",
    defaultLocalization: "en",
    platforms: [
        .visionOS(.v1),
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Go2TeleopVision", targets: ["Go2TeleopVision"]),
    ],
    targets: [
        .executableTarget(
            name: "Go2TeleopVision",
            path: "Sources/Go2TeleopVision"
        ),
    ]
)
