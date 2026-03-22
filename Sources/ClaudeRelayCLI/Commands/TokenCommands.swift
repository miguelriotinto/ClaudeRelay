import ArgumentParser
import Foundation

struct TokenGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "token",
        abstract: "Manage tokens",
        subcommands: [
            TokenCreateCommand.self,
            TokenListCommand.self,
            TokenDeleteCommand.self,
            TokenRotateCommand.self,
            TokenInspectCommand.self
        ]
    )
}

// MARK: - Create

struct TokenCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new token"
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: .long, help: "Label for the token")
    var label: String?

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            let body = TokenCreateRequest(label: label)
            let response: TokenCreateResponse = try await client.post("/tokens", body: body)

            if globals.json {
                print(OutputFormatter.formatJSON(response))
            } else {
                // Print only the plaintext token so it can be piped
                print(response.plaintext)
            }
        } catch let error as AdminClientError where error == .serviceNotRunning {
            printServiceNotRunning()
        }
    }
}

// MARK: - List

struct TokenListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all tokens"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            let tokens: [TokenInfo] = try await client.get("/tokens")

            if globals.json {
                print(OutputFormatter.formatJSON(tokens))
            } else {
                let headers = ["ID", "LABEL", "PREFIX", "CREATED", "LAST USED"]
                let rows = tokens.map { t in
                    [t.id, t.label ?? "-", t.prefix ?? "-", t.createdAt, t.lastUsedAt ?? "never"]
                }
                print(OutputFormatter.formatTable(headers: headers, rows: rows))
            }
        } catch let error as AdminClientError where error == .serviceNotRunning {
            printServiceNotRunning()
        }
    }
}

// MARK: - Delete

struct TokenDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete one or more tokens"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Token ID(s) to delete")
    var ids: [String]

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            for id in ids {
                try await client.delete("/tokens/\(id)")
                if !globals.quiet {
                    print("Token \(id) deleted.")
                }
            }
        } catch let error as AdminClientError where error == .serviceNotRunning {
            printServiceNotRunning()
        }
    }
}

// MARK: - Rotate

struct TokenRotateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rotate",
        abstract: "Rotate a token (invalidate old, create new)"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Token ID to rotate")
    var id: String

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            let response: TokenCreateResponse = try await client.post("/tokens/\(id)/rotate")

            if globals.json {
                print(OutputFormatter.formatJSON(response))
            } else {
                // Print only the plaintext token so it can be piped
                print(response.plaintext)
            }
        } catch let error as AdminClientError where error == .serviceNotRunning {
            printServiceNotRunning()
        }
    }
}

// MARK: - Inspect

struct TokenInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Show details for a token"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Token ID to inspect")
    var id: String

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            let token: TokenInfo = try await client.get("/tokens/\(id)")

            if globals.json {
                print(OutputFormatter.formatJSON(token))
            } else {
                print("ID:         \(token.id)")
                print("Label:      \(token.label ?? "-")")
                print("Prefix:     \(token.prefix ?? "-")")
                print("Created:    \(token.createdAt)")
                print("Last Used:  \(token.lastUsedAt ?? "never")")
            }
        } catch let error as AdminClientError where error == .serviceNotRunning {
            printServiceNotRunning()
        }
    }
}

// MARK: - Models

struct TokenCreateRequest: Encodable {
    let label: String?
}

struct TokenCreateResponse: Codable {
    let token: String
    let id: String
    let label: String?

    /// Convenience alias for the raw token string.
    var plaintext: String { token }
}

struct TokenInfo: Codable {
    let id: String
    let label: String?
    let prefix: String?
    let createdAt: String
    let lastUsedAt: String?
}

// MARK: - Helper

private func printServiceNotRunning() {
    print("Service is not running.")
}
