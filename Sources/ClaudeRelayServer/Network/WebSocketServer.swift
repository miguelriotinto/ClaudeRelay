import NIO
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOSSL
import ClaudeRelayKit
import Foundation

public final class WebSocketServer {
    private let group: EventLoopGroup
    private let sessionManager: SessionManager
    private let tokenStore: TokenStore
    private let config: RelayConfig
    private var channel: Channel?

    public init(group: EventLoopGroup, config: RelayConfig,
                sessionManager: SessionManager, tokenStore: TokenStore) {
        self.group = group
        self.config = config
        self.sessionManager = sessionManager
        self.tokenStore = tokenStore
    }

    /// Create SSL context from configured cert and key files.
    private func createSSLContext() throws -> NIOSSLContext {
        guard let certPath = config.tlsCert, let keyPath = config.tlsKey else {
            throw WebSocketServerError.tlsConfigMissing
        }

        let certURL = URL(fileURLWithPath: NSString(string: certPath).expandingTildeInPath)
        let keyURL = URL(fileURLWithPath: NSString(string: keyPath).expandingTildeInPath)

        guard FileManager.default.fileExists(atPath: certURL.path) else {
            throw WebSocketServerError.tlsCertNotFound(certURL.path)
        }
        guard FileManager.default.fileExists(atPath: keyURL.path) else {
            throw WebSocketServerError.tlsKeyNotFound(keyURL.path)
        }

        let certificates = try NIOSSLCertificate.fromPEMFile(certURL.path)
        let privateKey = try NIOSSLPrivateKey(file: keyURL.path, format: .pem)

        let certificateChain = certificates.map { NIOSSLCertificateSource.certificate($0) }

        var tlsConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificateChain,
            privateKey: .privateKey(privateKey)
        )
        tlsConfig.minimumTLSVersion = .tlsv12

        return try NIOSSLContext(configuration: tlsConfig)
    }

    public func start() async throws {
        let sessionManager = self.sessionManager
        let tokenStore = self.tokenStore
        let sslContext: NIOSSLContext? = try createSSLContextIfConfigured()

        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 10 * 1024 * 1024,
            shouldUpgrade: { channel, _ in
                channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, _ in
                let handler = RelayMessageHandler(
                    sessionManager: sessionManager,
                    tokenStore: tokenStore
                )
                return channel.pipeline.addHandler(handler)
            }
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // Add TLS handler if configured
                let sslFuture: EventLoopFuture<Void>
                if let sslContext = sslContext {
                    let sslHandler = NIOSSLServerHandler(context: sslContext)
                    sslFuture = channel.pipeline.addHandler(sslHandler)
                } else {
                    sslFuture = channel.eventLoop.makeSucceededVoidFuture()
                }

                return sslFuture.flatMap {
                    let config: NIOHTTPServerUpgradeConfiguration = (
                        upgraders: [upgrader],
                        completionHandler: { _ in
                            // Remove HTTP handlers after upgrade
                        }
                    )
                    return channel.pipeline.configureHTTPServerPipeline(
                        withServerUpgrade: config
                    ).flatMap {
                        // No additional handler needed; upgrade handler installs RelayMessageHandler
                        channel.eventLoop.makeSucceededVoidFuture()
                    }
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let ch = try await bootstrap.bind(host: "0.0.0.0", port: Int(config.wsPort)).get()
        self.channel = ch

        if sslContext != nil {
            RelayLogger.log(category: "websocket", "TLS enabled on port \(config.wsPort)")
        }
    }

    /// Create SSL context if TLS is configured (both cert and key present).
    private func createSSLContextIfConfigured() throws -> NIOSSLContext? {
        guard let certPath = config.tlsCert, !certPath.isEmpty,
              let keyPath = config.tlsKey, !keyPath.isEmpty else {
            return nil
        }
        return try createSSLContext()
    }

    public func stop() async throws {
        try await channel?.close()
    }
}

// MARK: - Errors

enum WebSocketServerError: Error, CustomStringConvertible {
    case tlsConfigMissing
    case tlsCertNotFound(String)
    case tlsKeyNotFound(String)

    var description: String {
        switch self {
        case .tlsConfigMissing:
            return "TLS configuration incomplete: both tlsCert and tlsKey are required"
        case .tlsCertNotFound(let path):
            return "TLS certificate not found at path: \(path)"
        case .tlsKeyNotFound(let path):
            return "TLS private key not found at path: \(path)"
        }
    }
}
