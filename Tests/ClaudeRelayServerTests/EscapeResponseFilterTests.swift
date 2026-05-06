import XCTest
@testable import ClaudeRelayServer

/// Unit tests for `EscapeResponseFilter` — extracted from `RelayMessageHandler`
/// so the logic is exercisable without spinning up a NIO channel.
final class EscapeResponseFilterTests: XCTestCase {

    func testEmptyPassesThrough() {
        XCTAssertEqual(EscapeResponseFilter.filter(Data()), Data())
    }

    func testPlainTextIsUnchanged() {
        let plain = Data("hello world\n".utf8)
        XCTAssertEqual(EscapeResponseFilter.filter(plain), plain)
    }

    func testStripsDeviceAttributesResponse() {
        // ESC [ ? 1 ; 2 c  — a realistic DA reply.
        let input = Data([0x1B, 0x5B, 0x3F, 0x31, 0x3B, 0x32, 0x63]) + Data("after".utf8)
        XCTAssertEqual(EscapeResponseFilter.filter(input), Data("after".utf8))
    }

    func testStripsCursorPositionResponse() {
        // ESC [ 24 ; 80 R — CPR
        let input = Data([0x1B, 0x5B, 0x32, 0x34, 0x3B, 0x38, 0x30, 0x52]) + Data("x".utf8)
        XCTAssertEqual(EscapeResponseFilter.filter(input), Data("x".utf8))
    }

    func testStripsDeviceStatusResponse() {
        // ESC [ 0 n — DSR
        let input = Data([0x1B, 0x5B, 0x30, 0x6E]) + Data("ok".utf8)
        XCTAssertEqual(EscapeResponseFilter.filter(input), Data("ok".utf8))
    }

    func testStripsDECREQTPARMResponse() {
        let input = Data([0x1B, 0x5B, 0x31, 0x79]) + Data("rest".utf8)
        XCTAssertEqual(EscapeResponseFilter.filter(input), Data("rest".utf8))
    }

    func testLeavesOtherCSISequencesAlone() {
        // ESC [ 2 J — clear screen. Final byte 'J' is not in the stripped set.
        let input = Data([0x1B, 0x5B, 0x32, 0x4A]) + Data("keep".utf8)
        XCTAssertEqual(EscapeResponseFilter.filter(input), input)
    }

    func testMultipleResponsesInOneBuffer() {
        let da = Data([0x1B, 0x5B, 0x63])         // ESC [ c
        let dsr = Data([0x1B, 0x5B, 0x30, 0x6E])  // ESC [ 0 n
        let input = Data("before".utf8) + da + Data("middle".utf8) + dsr + Data("after".utf8)
        XCTAssertEqual(EscapeResponseFilter.filter(input), Data("beforemiddle after".utf8)
            .replacingOccurrences(of: " ", with: ""),
            "Expected both response sequences to be stripped, leaving concatenated bystander text")
    }

    func testTruncatedCSIIsPreserved() {
        // ESC [ with no final byte should pass through unchanged.
        let input = Data([0x1B, 0x5B, 0x32, 0x34])
        XCTAssertEqual(EscapeResponseFilter.filter(input), input)
    }
}

private extension Data {
    /// Helper for the multi-response assertion's expected value.
    func replacingOccurrences(of: String, with: String) -> Data {
        guard let s = String(data: self, encoding: .utf8) else { return self }
        return Data(s.replacingOccurrences(of: of, with: with).utf8)
    }
}
