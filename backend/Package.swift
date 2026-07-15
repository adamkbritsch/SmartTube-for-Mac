// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MiniTubeBackend",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.99.0"),
        .package(url: "https://github.com/vapor/leaf.git", from: "4.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Leaf", package: "leaf"),
            ],
            path: "Sources/App",
            swiftSettings: [
                .enableUpcomingFeature("ConciseMagicFile"),
            ]
        )
    ]
)
