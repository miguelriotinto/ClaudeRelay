// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodeRelay",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "code-relay-server", targets: ["CodeRelayServer"]),
        .executable(name: "claude-relay", targets: ["CodeRelayCLI"]),
        .library(name: "CodeRelayKit", targets: ["CodeRelayKit"]),
        .library(name: "CodeRelayClient", targets: ["CodeRelayClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "CPTYShim",
            path: "Sources/CPTYShim",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CodeRelayKit",
            dependencies: [
                "CPTYShim",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/CodeRelayKit"
        ),
        .executableTarget(
            name: "CodeRelayServer",
            dependencies: [
                "CodeRelayKit",
                "CPTYShim",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            path: "Sources/CodeRelayServer"
        ),
        .executableTarget(
            name: "CodeRelayCLI",
            dependencies: [
                "CodeRelayKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Sources/CodeRelayCLI"
        ),
        .target(
            name: "CodeRelayClient",
            dependencies: ["CodeRelayKit"],
            path: "Sources/CodeRelayClient"
        ),
        .testTarget(
            name: "CodeRelayKitTests",
            dependencies: ["CodeRelayKit"],
            path: "Tests/CodeRelayKitTests"
        ),
        .testTarget(
            name: "CodeRelayServerTests",
            dependencies: ["CodeRelayServer", "CodeRelayKit"],
            path: "Tests/CodeRelayServerTests"
        ),
        .testTarget(
            name: "CodeRelayCLITests",
            dependencies: ["CodeRelayCLI", "CodeRelayKit"],
            path: "Tests/CodeRelayCLITests"
        ),
    ]
)
