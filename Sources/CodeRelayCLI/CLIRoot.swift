import ArgumentParser

@available(macOS 14.0, *)
public struct ClaudeRelay: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "claude-relay",
        abstract: "Manage the CodeRelay service",
        subcommands: [
            LoadCommand.self,
            UnloadCommand.self,
            StartCommand.self,
            StopCommand.self,
            RestartCommand.self,
            StatusCommand.self,
            HealthCommand.self,
            TokenGroup.self,
            SessionGroup.self,
            ConfigGroup.self,
            LogGroup.self,
        ]
    )

    public init() {}
}
