import ArgumentParser

public struct ClaudeRelay: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "claude-relay",
        abstract: "Manage the CodeRelay service",
        subcommands: [
            // Will be populated in later tasks:
            // load, unload, start, stop, restart, status, health, token, session, config, logs
        ]
    )

    @Flag(name: .long, help: "Output in JSON format")
    public var json = false

    @Flag(name: .long, help: "Suppress non-essential output")
    public var quiet = false

    public init() {}
}
