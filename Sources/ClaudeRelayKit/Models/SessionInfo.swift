import Foundation

/// Contains metadata about a ClaudeRelay session.
public struct SessionInfo: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String?
    public let state: SessionState
    public let tokenId: String
    public let createdAt: Date
    public let cols: UInt16
    public let rows: UInt16
    public let activity: ActivityState?
    /// The coding agent currently running in this session, if any.
    /// Nil when no agent is running or when the server predates multi-agent support.
    public let agent: String?

    public init(
        id: UUID,
        name: String? = nil,
        state: SessionState,
        tokenId: String,
        createdAt: Date,
        cols: UInt16,
        rows: UInt16,
        activity: ActivityState? = nil,
        agent: String? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.tokenId = tokenId
        self.createdAt = createdAt
        self.cols = cols
        self.rows = rows
        self.activity = activity
        self.agent = agent
    }
}
