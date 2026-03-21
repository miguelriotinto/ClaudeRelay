import XCTest
@testable import ClaudeRelayServer

final class RingBufferTests: XCTestCase {

    func testWriteAndFlush() {
        var buffer = RingBuffer(capacity: 64)
        let data = Data("Hello, World!".utf8)
        buffer.write(data)
        let flushed = buffer.flush()
        XCTAssertEqual(flushed, data)
    }

    func testFlushClearsBuffer() {
        var buffer = RingBuffer(capacity: 64)
        buffer.write(Data("Hello".utf8))
        _ = buffer.flush()
        let second = buffer.flush()
        XCTAssertEqual(second, Data())
    }

    func testOverflowDropsOldestData() {
        var buffer = RingBuffer(capacity: 10)
        let first = Data([0, 1, 2, 3, 4])          // 5 bytes
        let second = Data([5, 6, 7, 8, 9, 10, 11]) // 7 bytes -> 12 total, capacity 10
        buffer.write(first)
        buffer.write(second)
        let flushed = buffer.flush()
        // Should contain the last 10 bytes: [2,3,4,5,6,7,8,9,10,11]
        XCTAssertEqual(flushed, Data([2, 3, 4, 5, 6, 7, 8, 9, 10, 11]))
    }

    func testEmptyFlush() {
        var buffer = RingBuffer(capacity: 64)
        let flushed = buffer.flush()
        XCTAssertEqual(flushed, Data())
    }

    func testExactCapacityFill() {
        var buffer = RingBuffer(capacity: 5)
        let data = Data([1, 2, 3, 4, 5])
        buffer.write(data)
        let flushed = buffer.flush()
        XCTAssertEqual(flushed, data)
    }

    func testMultipleSmallWrites() {
        var buffer = RingBuffer(capacity: 64)
        let a = Data("Hello".utf8)
        let b = Data(", ".utf8)
        let c = Data("World!".utf8)
        buffer.write(a)
        buffer.write(b)
        buffer.write(c)
        let flushed = buffer.flush()
        XCTAssertEqual(flushed, Data("Hello, World!".utf8))
    }

    func testCount() {
        var buffer = RingBuffer(capacity: 64)
        XCTAssertEqual(buffer.count, 0)
        buffer.write(Data("Hello".utf8))
        XCTAssertEqual(buffer.count, 5)
        buffer.write(Data("!".utf8))
        XCTAssertEqual(buffer.count, 6)
        _ = buffer.flush()
        XCTAssertEqual(buffer.count, 0)
    }
}
