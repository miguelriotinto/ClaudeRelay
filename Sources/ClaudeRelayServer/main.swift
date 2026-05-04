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

// Every 30 minutes, evict observers older than 1 hour. Prevents unbounded
// growth if a channel dies without its ChannelInboundHandler running cleanup.
let observerPurgeTask = Task {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(30 * 60))
        guard !Task.isCancelled else { return }
        await sessionManager.purgeStaleObservers(olderThan: 60 * 60)
    }
}

let wsServer = WebSocketServer(
    group: group, config: config,
    sessionManager: sessionManager, tokenStore: tokenStore
)
let adminServer = AdminHTTPServer(
    group: group, port: config.adminPort,
    sessionManager: sessionManager, tokenStore: tokenStore
)

try await wsServer.start()
try await adminServer.start()

RelayLogger.log(category: "server", "Server started — WebSocket: 0.0.0.0:\(config.wsPort), Admin: 127.0.0.1:\(config.adminPort)")
print("ClaudeRelay server running")
print("  WebSocket: 0.0.0.0:\(config.wsPort)")
print("  Admin API: 127.0.0.1:\(config.adminPort)")

// Auto-reap child processes (PTY shells) to prevent zombies.
signal(SIGCHLD, SIG_IGN)

// Wait for SIGINT/SIGTERM using async-safe signal handling.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

    sigintSource.setEventHandler {
        sigintSource.cancel()
        sigtermSource.cancel()
        continuation.resume()
    }
    sigtermSource.setEventHandler {
        sigintSource.cancel()
        sigtermSource.cancel()
        continuation.resume()
    }
    sigintSource.resume()
    sigtermSource.resume()
}

RelayLogger.log(category: "server", "Shutdown signal received")
print("\nShutting down...")
observerPurgeTask.cancel()
await sessionManager.shutdown()
await tokenStore.flushIfDirty()
try await wsServer.stop()
try await adminServer.stop()
try await group.shutdownGracefully()
