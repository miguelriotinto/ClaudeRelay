import ArgumentParser
import Foundation

struct LogGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "View service logs",
        subcommands: [
            LogShowCommand.self,
            LogTailCommand.self,
        ]
    )
}

// MARK: - Show

struct LogShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show recent log entries"
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: .long, help: "Number of lines to show")
    var lines: Int = 50

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            let response: LogResponse = try await client.get("/logs?lines=\(lines)")

            if globals.json {
                print(OutputFormatter.formatJSON(response))
            } else {
                for entry in response.entries {
                    print(entry)
                }
            }
        } catch let error as AdminClientError where error == .serviceNotRunning {
            print("Service is not running.")
        }
    }
}

// MARK: - Tail

struct LogTailCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tail",
        abstract: "Follow log output"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let client = AdminClient(port: globals.port)

        if !globals.quiet {
            print("Following logs (Ctrl+C to stop)...")
        }

        var lastCount = 0

        while !Task.isCancelled {
            do {
                let response: LogResponse = try await client.get("/logs?lines=20")

                let entries = response.entries
                if entries.count > lastCount {
                    let newEntries = entries.suffix(entries.count - lastCount)
                    for entry in newEntries {
                        if globals.json {
                            print(#"{"log": "\#(entry)"}"#)
                        } else {
                            print(entry)
                        }
                    }
                    lastCount = entries.count
                }
            } catch let error as AdminClientError where error == .serviceNotRunning {
                print("Service is not running.")
                return
            }

            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        }
    }
}

// MARK: - Models

struct LogResponse: Codable {
    let entries: [String]
}
