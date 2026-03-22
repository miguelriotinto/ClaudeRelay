import NIO
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import ClaudeRelayKit

public final class WebSocketServer {
    private let group: EventLoopGroup
    private let sessionManager: SessionManager
    private let tokenStore: TokenStore
    private let port: UInt16
    private var channel: Channel?

    public init(group: EventLoopGroup, port: UInt16,
                sessionManager: SessionManager, tokenStore: TokenStore) {
        self.group = group
        self.port = port
        self.sessionManager = sessionManager
        self.tokenStore = tokenStore
    }

    public func start() async throws {
        let sessionManager = self.sessionManager
        let tokenStore = self.tokenStore

        let upgrader = NIOWebSocketServerUpgrader(
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
                let httpHandler = HTTPByteBufferResponsePartHandler()
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
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let ch = try await bootstrap.bind(host: "0.0.0.0", port: Int(port)).get()
        self.channel = ch
    }

    public func stop() async throws {
        try await channel?.close()
    }
}

/// Minimal handler to absorb HTTP bytes before WebSocket upgrade completes.
private final class HTTPByteBufferResponsePartHandler: ChannelOutboundHandler {
    typealias OutboundIn = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(data, promise: promise)
    }
}
