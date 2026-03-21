import XCTest
import Foundation
@testable import ClaudeRelayServer
import ClaudeRelayKit

final class TokenStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCreateAndValidate() async throws {
        let store = TokenStore(directory: tempDir)
        let (plaintext, created) = try await store.create(label: "test")

        let validated = await store.validate(token: plaintext)
        XCTAssertNotNil(validated)
        XCTAssertEqual(validated?.id, created.id)
        XCTAssertEqual(validated?.label, "test")
    }

    func testValidateRejectsWrongToken() async throws {
        let store = TokenStore(directory: tempDir)
        _ = try await store.create(label: nil)

        let result = await store.validate(token: "bogus")
        XCTAssertNil(result)
    }

    func testList() async throws {
        let store = TokenStore(directory: tempDir)
        _ = try await store.create(label: "a")
        _ = try await store.create(label: "b")

        let all = await store.list()
        XCTAssertEqual(all.count, 2)
    }

    func testDelete() async throws {
        let store = TokenStore(directory: tempDir)
        let (_, info) = try await store.create(label: "del")
        try await store.delete(id: info.id)

        let all = await store.list()
        XCTAssertTrue(all.isEmpty)
    }

    func testRotate() async throws {
        let store = TokenStore(directory: tempDir)
        let (oldPlaintext, oldInfo) = try await store.create(label: "rotate-me")

        let (newPlaintext, newInfo) = try await store.rotate(id: oldInfo.id)

        // Same id and label preserved
        XCTAssertEqual(newInfo.id, oldInfo.id)
        XCTAssertEqual(newInfo.label, oldInfo.label)

        // Old token no longer valid
        let oldResult = await store.validate(token: oldPlaintext)
        XCTAssertNil(oldResult)

        // New token is valid
        let newResult = await store.validate(token: newPlaintext)
        XCTAssertNotNil(newResult)
        XCTAssertEqual(newResult?.id, oldInfo.id)
    }

    func testPersistence() async throws {
        let store1 = TokenStore(directory: tempDir)
        let (plaintext, info) = try await store1.create(label: "persist")

        // Create a completely new store instance pointing at the same directory
        let store2 = TokenStore(directory: tempDir)
        let validated = await store2.validate(token: plaintext)
        XCTAssertNotNil(validated)
        XCTAssertEqual(validated?.id, info.id)
        XCTAssertEqual(validated?.label, "persist")
    }
}
