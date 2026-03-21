import ArgumentParser
import Foundation

struct SessionGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Manage sessions",
        subcommands: [
            SessionListCommand.self,
            SessionInspectCommand.self,
            SessionTerminateCommand.self,
        ]
    )
}

// MARK: - List

struct SessionListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List active sessions"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            let sessions: [SessionInfo] = try await client.get("/sessions")

            if globals.json {
                print(OutputFormatter.formatJSON(sessions))
            } else {
                if sessions.isEmpty {
                    if !globals.quiet {
                        print("No active sessions.")
                    }
                } else {
                    let headers = ["ID", "TOKEN", "CONNECTED", "REMOTE"]
                    let rows = sessions.map { s in
                        [s.id, s.tokenLabel ?? s.tokenId ?? "-", s.connectedAt, s.remoteAddress ?? "-"]
                    }
                    print(OutputFormatter.formatTable(headers: headers, rows: rows))
                }
            }
        } catch let error as AdminClientError where error == .serviceNotRunning {
            print("Service is not running.")
        }
    }
}

// MARK: - Inspect

struct SessionInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Show details for a session"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Session ID to inspect")
    var id: String

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            let session: SessionInfo = try await client.get("/sessions/\(id)")

            if globals.json {
                print(OutputFormatter.formatJSON(session))
            } else {
                print("ID:           \(session.id)")
                print("Token:        \(session.tokenLabel ?? session.tokenId ?? "-")")
                print("Connected:    \(session.connectedAt)")
                print("Remote:       \(session.remoteAddress ?? "-")")
                if let bytes = session.bytesTransferred {
                    print("Transferred:  \(bytes) bytes")
                }
            }
        } catch let error as AdminClientError where error == .serviceNotRunning {
            print("Service is not running.")
        }
    }
}

// MARK: - Terminate

struct SessionTerminateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "terminate",
        abstract: "Terminate a session"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Session ID to terminate")
    var id: String

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            try await client.delete("/sessions/\(id)")
            if !globals.quiet {
                print("Session \(id) terminated.")
            }
        } catch let error as AdminClientError where error == .serviceNotRunning {
            print("Service is not running.")
        }
    }
}

// MARK: - Models

struct SessionInfo: Codable {
    let id: String
    let tokenId: String?
    let tokenLabel: String?
    let connectedAt: String
    let remoteAddress: String?
    let bytesTransferred: Int?
}
