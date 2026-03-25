import ArgumentParser
import Foundation
import ClaudeRelayKit

private let serviceLabel = "com.claude.relay"

// MARK: - Load

struct LoadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "load",
        abstract: "Install and start the service"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let relayDir = "\(homeDir)/.claude-relay"
        let launchAgentsDir = "\(homeDir)/Library/LaunchAgents"
        let plistPath = "\(launchAgentsDir)/\(serviceLabel).plist"

        // Update config.json if ports were specified on the command line.
        try updateConfigIfNeeded()

        // Find server binary
        let serverBinary = findServerBinary()

        // Ensure directories exist
        let fm = FileManager.default
        try fm.createDirectory(atPath: relayDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)

        // Generate plist
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(serviceLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(serverBinary)</string>
            </array>
            <key>KeepAlive</key>
            <true/>
            <key>RunAtLoad</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(relayDir)/stdout.log</string>
            <key>StandardErrorPath</key>
            <string>\(relayDir)/stderr.log</string>
        </dict>
        </plist>
        """

        try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)

        // Load via launchctl
        try runLaunchctl(["load", plistPath])

        let config = try ConfigManager.load()
        if !globals.quiet {
            print("Service installed and started.")
            print("  WebSocket: 0.0.0.0:\(config.wsPort)")
            print("  Admin API: 127.0.0.1:\(config.adminPort)")
            print("  Plist:     \(plistPath)")
        }
    }

    /// If the user passed --ws-port or --admin-port, update config.json
    /// so the server picks up the new values on startup.
    private func updateConfigIfNeeded() throws {
        // Only write if at least one port was explicitly provided.
        // Check: adminPort has a non-default value or wsPort was specified.
        let wsPortProvided = globals.wsPort != nil
        let adminPortProvided = ProcessInfo.processInfo.arguments.contains("--admin-port")
            || ProcessInfo.processInfo.arguments.contains("-p")

        guard wsPortProvided || adminPortProvided else { return }

        try ConfigManager.ensureDirectory()
        var config = (try? ConfigManager.load()) ?? .default

        if let ws = globals.wsPort {
            config.wsPort = ws
        }
        if adminPortProvided {
            config.adminPort = globals.adminPort
        }

        try ConfigManager.save(config)
    }

    private func findServerBinary() -> String {
        // Check same directory as CLI binary first (covers Homebrew and local builds)
        let cliPath = CommandLine.arguments[0]
        let cliDir = URL(fileURLWithPath: cliPath).deletingLastPathComponent().path
        let siblingCandidate = cliDir + "/claude-relay-server"
        if FileManager.default.isExecutableFile(atPath: siblingCandidate) {
            return siblingCandidate
        }

        let candidates = [
            "/opt/homebrew/bin/claude-relay-server",
            "/usr/local/bin/claude-relay-server",
            FileManager.default.homeDirectoryForCurrentUser.path + "/.claude-relay/bin/claude-relay-server"
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Default fallback
        return "/usr/local/bin/claude-relay-server"
    }
}

// MARK: - Unload

struct UnloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unload",
        abstract: "Stop and uninstall the service"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let plistPath = "\(homeDir)/Library/LaunchAgents/\(serviceLabel).plist"

        try runLaunchctl(["unload", plistPath])

        let fm = FileManager.default
        if fm.fileExists(atPath: plistPath) {
            try fm.removeItem(atPath: plistPath)
        }

        if !globals.quiet {
            print("Service stopped and uninstalled.")
        }
    }
}

// MARK: - Start

struct StartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start the service"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        try runLaunchctl(["start", serviceLabel])
        if !globals.quiet {
            print("Service started.")
        }
    }
}

// MARK: - Stop

struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the service"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        try runLaunchctl(["stop", serviceLabel])
        if !globals.quiet {
            print("Service stopped.")
        }
    }
}

// MARK: - Restart

struct RestartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Restart the service"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        try runLaunchctl(["stop", serviceLabel])
        try runLaunchctl(["start", serviceLabel])
        if !globals.quiet {
            print("Service restarted.")
        }
    }
}

// MARK: - Status

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show service status"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            let response: StatusResponse = try await client.get("/status")

            if globals.json {
                print(OutputFormatter.formatJSON(response))
            } else {
                print(OutputFormatter.formatStatus(
                    running: response.running,
                    pid: response.pid,
                    uptime: response.uptime,
                    sessions: response.sessions
                ))
            }
        } catch let error as AdminClientError where error == .serviceNotRunning {
            if globals.json {
                print(#"{"running": false, "error": "Service is not running"}"#)
            } else {
                print("Service is not running.")
            }
            throw ExitCode.failure
        } catch {
            print("Error: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

// MARK: - Health

struct HealthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "health",
        abstract: "Check if the service is reachable"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let client = AdminClient(port: globals.port)
        let running = await client.isServiceRunning()

        if globals.json {
            print(#"{"healthy": \#(running)}"#)
        } else {
            print(running ? "OK" : "Unreachable")
        }

        if !running {
            throw ExitCode.failure
        }
    }
}

// MARK: - Response Models

struct StatusResponse: Codable {
    let status: String
    let pid: Int?
    let uptimeSeconds: Int?
    let sessionCount: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case pid
        case uptimeSeconds = "uptime_seconds"
        case sessionCount = "session_count"
    }

    var running: Bool { status == "running" }
    var uptime: Int? { uptimeSeconds }
    var sessions: Int { sessionCount ?? 0 }
}

// MARK: - Helpers

private func runLaunchctl(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments

    let pipe = Pipe()
    process.standardError = pipe

    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
        let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
        let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
        throw CLIError.launchctlFailed(errorMessage.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum CLIError: Error, LocalizedError {
    case launchctlFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchctlFailed(let msg):
            return "launchctl failed: \(msg)"
        }
    }
}

// MARK: - AdminClientError Equatable

extension AdminClientError: Equatable {
    public static func == (lhs: AdminClientError, rhs: AdminClientError) -> Bool {
        switch (lhs, rhs) {
        case (.serviceNotRunning, .serviceNotRunning):
            return true
        default:
            return false
        }
    }
}
