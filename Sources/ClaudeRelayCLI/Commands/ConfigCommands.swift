import ArgumentParser
import Foundation

struct ConfigGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Manage configuration",
        subcommands: [
            ConfigShowCommand.self,
            ConfigSetCommand.self,
            ConfigValidateCommand.self
        ]
    )
}

// MARK: - Show

struct ConfigShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show current configuration"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            let config: [String: ConfigValue] = try await client.get("/config")

            if globals.json {
                print(OutputFormatter.formatJSON(config))
            } else {
                let headers = ["KEY", "VALUE"]
                let rows = config.sorted(by: { $0.key < $1.key }).map { key, value in
                    [key, value.description]
                }
                print(OutputFormatter.formatTable(headers: headers, rows: rows))
            }
        } catch {
            print(OutputFormatter.formatError(error, json: globals.json))
            throw ExitCode.failure
        }
    }
}

// MARK: - Set

struct ConfigSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set a configuration value"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Configuration key")
    var key: String

    @Argument(help: "Configuration value")
    var value: String

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            let body = ["value": value]
            let _: ConfigSetResponse = try await client.put("/config/\(key)", body: body)
            if !globals.quiet {
                print("Set \(key) = \(value)")
            }
        } catch {
            print(OutputFormatter.formatError(error, json: globals.json))
            throw ExitCode.failure
        }
    }
}

// MARK: - Validate

struct ConfigValidateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate current configuration"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            let config: [String: ConfigValue] = try await client.get("/config")

            var errors: [String] = []

            // Basic validation checks
            if let wsPort = config["wsPort"] {
                if let port = Int(wsPort.description), port < 1 || port > 65535 {
                    errors.append("wsPort: must be between 1 and 65535")
                }
            }

            if let adminPort = config["adminPort"] {
                if let port = Int(adminPort.description), port < 1 || port > 65535 {
                    errors.append("adminPort: must be between 1 and 65535")
                }
            }

            if let wsPort = config["wsPort"], let adminPort = config["adminPort"] {
                let ws = Int(wsPort.description) ?? 0
                let admin = Int(adminPort.description) ?? 0
                if ws > 0 && ws == admin {
                    errors.append("wsPort and adminPort cannot be the same (\(ws))")
                }
            }

            if globals.json {
                let result = ValidationResult(valid: errors.isEmpty, errors: errors)
                print(OutputFormatter.formatJSON(result))
            } else {
                if errors.isEmpty {
                    print("Configuration is valid.")
                } else {
                    print("Configuration errors:")
                    for error in errors {
                        print("  - \(error)")
                    }
                    throw ExitCode.failure
                }
            }
        } catch {
            print(OutputFormatter.formatError(error, json: globals.json))
            throw ExitCode.failure
        }
    }
}

// MARK: - Models

enum ConfigValue: Codable, CustomStringConvertible {
    case string(String)
    case int(Int)
    case bool(Bool)

    var description: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .bool(let b): return String(b)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .bool(let b): try container.encode(b)
        }
    }
}

struct ConfigSetResponse: Codable {
    let ok: Bool?
    let key: String?
    let value: String?
}

struct ValidationResult: Codable {
    let valid: Bool
    let errors: [String]
}
