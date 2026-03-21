import ArgumentParser

@main
struct ClaudeRelay: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claude-relay",
        abstract: "CodeRelay CLI tool"
    )

    func run() throws {
        print("claude-relay v0.1.0")
    }
}
