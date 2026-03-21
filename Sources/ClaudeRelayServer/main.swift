import NIO
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import ClaudeRelayKit
import Foundation

// Ensure config directory exists
try ConfigManager.ensureDirectory()
let config = try ConfigManager.load()

let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

let tokenStore = TokenStore(directory: RelayConfig.configDirectory)
let sessionManager = SessionManager(config: config, tokenStore: tokenStore)

let wsServer = WebSocketServer(
    group: group, port: config.wsPort,
    sessionManager: sessionManager, tokenStore: tokenStore
)
let adminServer = AdminHTTPServer(
    group: group, port: config.adminPort,
    sessionManager: sessionManager, tokenStore: tokenStore
)

try await wsServer.start()
try await adminServer.start()

print("ClaudeRelay server running")
print("  WebSocket: 0.0.0.0:\(config.wsPort)")
print("  Admin API: 127.0.0.1:\(config.adminPort)")

// Wait for SIGINT/SIGTERM
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

let semaphore = DispatchSemaphore(value: 0)

sigintSource.setEventHandler { semaphore.signal() }
sigtermSource.setEventHandler { semaphore.signal() }
sigintSource.resume()
sigtermSource.resume()

semaphore.wait()

print("\nShutting down...")
try await wsServer.stop()
try await adminServer.stop()
try await group.shutdownGracefully()
