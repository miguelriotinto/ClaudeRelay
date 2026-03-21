// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeRelay",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "claude-relay-server", targets: ["ClaudeRelayServer"]),
        .executable(name: "claude-relay", targets: ["ClaudeRelayCLI"]),
        .library(name: "ClaudeRelayKit", targets: ["ClaudeRelayKit"]),
        .library(name: "ClaudeRelayClient", targets: ["ClaudeRelayClient"]),
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
            name: "ClaudeRelayKit",
            dependencies: [
                "CPTYShim",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/ClaudeRelayKit"
        ),
        .executableTarget(
            name: "ClaudeRelayServer",
            dependencies: [
                "ClaudeRelayKit",
                "CPTYShim",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            path: "Sources/ClaudeRelayServer"
        ),
        .executableTarget(
            name: "ClaudeRelayCLI",
            dependencies: [
                "ClaudeRelayKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Sources/ClaudeRelayCLI"
        ),
        .target(
            name: "ClaudeRelayClient",
            dependencies: ["ClaudeRelayKit"],
            path: "Sources/ClaudeRelayClient"
        ),
        .testTarget(
            name: "ClaudeRelayKitTests",
            dependencies: ["ClaudeRelayKit"],
            path: "Tests/ClaudeRelayKitTests"
        ),
        .testTarget(
            name: "ClaudeRelayServerTests",
            dependencies: ["ClaudeRelayServer", "ClaudeRelayKit"],
            path: "Tests/ClaudeRelayServerTests"
        ),
        .testTarget(
            name: "ClaudeRelayCLITests",
            dependencies: ["ClaudeRelayCLI", "ClaudeRelayKit"],
            path: "Tests/ClaudeRelayCLITests"
        ),
    ]
)
