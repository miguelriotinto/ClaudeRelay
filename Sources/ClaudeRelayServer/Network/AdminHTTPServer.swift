import NIO
import NIOCore
import NIOPosix
import NIOHTTP1
import Foundation
import ClaudeRelayKit

public final class AdminHTTPServer {
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
        let wsPort = self.port  // We don't have wsPort here but AdminRoutes needs config

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    let handler = AdminHTTPHandler(
                        sessionManager: sessionManager,
                        tokenStore: tokenStore
                    )
                    return channel.pipeline.addHandler(handler)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let ch = try await bootstrap.bind(host: "127.0.0.1", port: Int(port)).get()
        self.channel = ch
    }

    public func stop() async throws {
        try await channel?.close()
    }
}

// MARK: - AdminHTTPHandler

final class AdminHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let sessionManager: SessionManager
    private let tokenStore: TokenStore

    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?

    init(sessionManager: SessionManager, tokenStore: TokenStore) {
        self.sessionManager = sessionManager
        self.tokenStore = tokenStore
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            self.requestHead = head
            self.requestBody = context.channel.allocator.buffer(capacity: 0)
        case .body(var body):
            self.requestBody?.writeBuffer(&body)
        case .end:
            guard let head = requestHead else { return }
            let body = requestBody
            let sessionManager = self.sessionManager
            let tokenStore = self.tokenStore

            Task {
                let response = await AdminRoutes.handle(
                    method: head.method,
                    uri: head.uri,
                    body: body,
                    sessionManager: sessionManager,
                    tokenStore: tokenStore
                )
                context.eventLoop.execute {
                    self.writeResponse(response, context: context)
                }
            }

            self.requestHead = nil
            self.requestBody = nil
        }
    }

    private func writeResponse(_ response: AdminResponse, context: ChannelHandlerContext) {
        let status = HTTPResponseStatus(statusCode: response.statusCode)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        let data = response.body
        headers.add(name: "Content-Length", value: "\(data.count)")
        headers.add(name: "Connection", value: "close")

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }
}

// MARK: - AdminResponse

struct AdminResponse {
    let statusCode: Int
    let body: Data

    static func json(_ value: Any, status: Int = 200) -> AdminResponse {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return AdminResponse(statusCode: status, body: data)
    }

    static func encodable<T: Encodable>(_ value: T, status: Int = 200) -> AdminResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data()
        return AdminResponse(statusCode: status, body: data)
    }

    static func error(_ message: String, status: Int = 400) -> AdminResponse {
        return json(["error": message], status: status)
    }
}
