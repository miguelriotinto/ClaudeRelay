import Foundation

/// Contains metadata about a CodeRelay session.
public struct SessionInfo: Codable, Equatable, Sendable {
    public let id: UUID
    public let state: SessionState
    public let tokenId: String
    public let createdAt: Date
    public let cols: UInt16
    public let rows: UInt16

    public init(
        id: UUID,
        state: SessionState,
        tokenId: String,
        createdAt: Date,
        cols: UInt16,
        rows: UInt16
    ) {
        self.id = id
        self.state = state
        self.tokenId = tokenId
        self.createdAt = createdAt
        self.cols = cols
        self.rows = rows
    }
}
