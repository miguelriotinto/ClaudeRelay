import ArgumentParser

public struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Output in JSON format")
    var json = false

    @Flag(name: .long, help: "Suppress non-essential output")
    var quiet = false

    @Option(name: [.long, .customShort("p")], help: "Admin API port")
    var adminPort: UInt16 = 9100

    @Option(name: .long, help: "WebSocket port")
    var wsPort: UInt16?

    @Flag(name: .customLong("bind-all"),
          help: "Bind the WebSocket server on 0.0.0.0 (network-reachable) instead of 127.0.0.1.")
    var bindAll: Bool = false

    /// Backward-compatible alias: commands that used `globals.port` now use this.
    var port: UInt16 { adminPort }

    public init() {}
}
