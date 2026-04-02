/// Transfers a non-Sendable value across concurrency boundaries.
/// Safety: the wrapped value is only ever accessed back on the originating NIO event loop.
struct UnsafeTransfer<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
