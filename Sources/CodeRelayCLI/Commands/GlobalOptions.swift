import ArgumentParser

public struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Output in JSON format")
    var json = false

    @Flag(name: .long, help: "Suppress non-essential output")
    var quiet = false

    @Option(name: .long, help: "Admin API port")
    var port: UInt16 = 9100

    public init() {}
}
