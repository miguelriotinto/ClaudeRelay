import XCTest
@testable import ClaudeRelayClient

final class AuthManagerTests: XCTestCase {

    private let manager = AuthManager()
    private let testId = UUID()

    override func tearDown() {
        try? manager.deleteToken(for: testId)
        super.tearDown()
    }

    func testSaveAndLoadToken() throws {
        try manager.saveToken("test-token-123", for: testId)
        let loaded = try manager.loadToken(for: testId)
        XCTAssertEqual(loaded, "test-token-123")
    }

    func testLoadReturnNilForMissingToken() throws {
        let loaded = try manager.loadToken(for: UUID())
        XCTAssertNil(loaded)
    }

    func testDeleteRemovesToken() throws {
        try manager.saveToken("delete-me", for: testId)
        try manager.deleteToken(for: testId)
        let loaded = try manager.loadToken(for: testId)
        XCTAssertNil(loaded)
    }

    func testOverwriteExistingToken() throws {
        try manager.saveToken("old-token", for: testId)
        try manager.saveToken("new-token", for: testId)
        let loaded = try manager.loadToken(for: testId)
        XCTAssertEqual(loaded, "new-token")
    }

    func testDeleteNonExistentTokenDoesNotThrow() {
        XCTAssertNoThrow(try manager.deleteToken(for: UUID()))
    }
}
