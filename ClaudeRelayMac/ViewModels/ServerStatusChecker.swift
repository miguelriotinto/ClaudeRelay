import Foundation
import SwiftUI
import Network
import ClaudeRelayClient

/// Polls the server's WebSocket endpoint for reachability.
/// We don't poll the admin API because it's localhost-only;
/// instead we open a short-lived TCP connection to the WebSocket port.
@MainActor
final class ServerStatusChecker: ObservableObject {

    @Published private(set) var isReachable: Bool = false

    private var pollTask: Task<Void, Never>?
    private let pollInterval: TimeInterval = 5.0

    func startPolling(_ config: ConnectionConfig) {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let reachable = await Self.check(config: config)
                await MainActor.run {
                    self?.isReachable = reachable
                }
                try? await Task.sleep(nanoseconds: UInt64((self?.pollInterval ?? 5.0) * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private static func check(config: ConnectionConfig) async -> Bool {
        // Opens a short-lived TCP connection to test if the port accepts connections.
        // This works whether or not TLS is configured — we only care about reachability.
        await withCheckedContinuation { continuation in
            let host = NWEndpoint.Host(config.host)
            let port = NWEndpoint.Port(rawValue: config.port) ?? NWEndpoint.Port(integerLiteral: 9200)
            let connection = NWConnection(host: host, port: port, using: .tcp)
            let resumeLock = ResumeGuard()

            let timeout = DispatchWorkItem {
                if resumeLock.tryClaim() {
                    connection.cancel()
                    continuation.resume(returning: false)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumeLock.tryClaim() {
                        timeout.cancel()
                        connection.cancel()
                        continuation.resume(returning: true)
                    }
                case .failed, .cancelled:
                    if resumeLock.tryClaim() {
                        timeout.cancel()
                        continuation.resume(returning: false)
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }
}

/// Thread-safe one-shot guard so continuation.resume(...) is called at most once.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// Returns true exactly once; returns false for every subsequent call.
    func tryClaim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
