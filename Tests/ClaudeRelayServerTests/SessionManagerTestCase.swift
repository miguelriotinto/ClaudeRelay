import XCTest
import Foundation
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

// MARK: - MockPTYSession

actor MockPTYSession: PTYSessionProtocol {
    let sessionId: UUID
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var exitHandler: (@Sendable () -> Void)?
    private var terminated = false
    private var activityHandler: (@Sendable (ActivityState, CodingAgent?, UInt64) -> Void)?

    init(sessionId: UUID, cols: UInt16, rows: UInt16, scrollbackSize: Int) {
        self.sessionId = sessionId
    }

    func startReading() {}
    func setOutputHandler(_ handler: @escaping @Sendable (Data) -> Void) { outputHandler = handler }
    func setExitHandler(_ handler: @escaping @Sendable () -> Void) { exitHandler = handler }
    func clearOutputHandler() { outputHandler = nil }
    func write(_ data: Data) {}
    func resize(cols: UInt16, rows: UInt16) {}
    func readBuffer() -> Data { Data() }
    func terminate() { terminated = true }
    func getActivityState() -> ActivityState { .active }
    func getActiveAgent() -> CodingAgent? { nil }
    func setActivityHandler(_ handler: @escaping @Sendable (ActivityState, CodingAgent?, UInt64) -> Void) {
        activityHandler = handler
    }
    func recordInput() {}
    func setPollCadence(_ seconds: TimeInterval) {}
}

// MARK: - Shared base

/// Shared scaffolding for SessionManager-focused test suites. Subclasses focus on
/// lifecycle, observers, or ownership without each re-declaring a temp dir,
/// token store, and mock PTY factory.
class SessionManagerTestCase: XCTestCase {

    var tempDir: URL!
    var tokenStore: TokenStore!
    var config: RelayConfig!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tokenStore = TokenStore(directory: tempDir)
        config = RelayConfig(detachTimeout: 5, scrollbackSize: 4096)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func createTestToken(label: String = "test") async throws -> (plaintext: String, info: TokenInfo) {
        try await tokenStore.create(label: label)
    }

    func makeManager(config: RelayConfig? = nil) -> SessionManager {
        SessionManager(config: config ?? self.config, tokenStore: tokenStore, ptyFactory: { id, cols, rows, scrollback in
            MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
        })
    }
}
