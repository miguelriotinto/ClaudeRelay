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

    /// Backward-compatible alias: commands that used `globals.port` now use this.
    var port: UInt16 { adminPort }

    public init() {}
}
