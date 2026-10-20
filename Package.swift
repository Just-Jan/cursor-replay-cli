// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CursorReplayCLI",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "cursor-replay", targets: ["MouseRecorderCLI"]),
        .executable(name: "cursor-replay-probe", targets: ["CGEventProbe"])
    ],
    targets: [
        .target(name: "MouseRecorderCore"),
        .executableTarget(name: "MouseRecorderCLI", dependencies: ["MouseRecorderCore"]),
        .executableTarget(name: "CGEventProbe"),
        .testTarget(name: "MouseRecorderCoreTests", dependencies: ["MouseRecorderCore"]),
        .testTarget(name: "MouseRecorderCLITests", dependencies: ["MouseRecorderCLI"])
    ]
)
