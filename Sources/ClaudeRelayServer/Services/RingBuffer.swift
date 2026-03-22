import Foundation

/// A fixed-capacity circular buffer for storing bytes.
/// When the buffer is full, new writes silently drop the oldest data.
public struct RingBuffer: Sendable {
    private var storage: [UInt8]
    private var head: Int  // next write position
    private var filled: Int

    /// The fixed capacity in bytes.
    public let capacity: Int

    /// The current number of valid bytes in the buffer.
    public var count: Int { filled }

    /// Creates a ring buffer with the given capacity in bytes.
    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
        self.storage = [UInt8](repeating: 0, count: capacity)
        self.head = 0
        self.filled = 0
    }

    /// Appends data to the buffer. If the total exceeds capacity,
    /// the oldest bytes are silently dropped.
    public mutating func write(_ data: Data) {
        let bytes = [UInt8](data)

        if bytes.count >= capacity {
            // Only the last `capacity` bytes matter
            let start = bytes.count - capacity
            storage = Array(bytes[start...])
            head = 0
            filled = capacity
            return
        }

        let count = bytes.count
        let spaceToEnd = capacity - head
        if count <= spaceToEnd {
            storage.replaceSubrange(head..<head + count, with: bytes)
        } else {
            storage.replaceSubrange(head..<capacity, with: bytes[0..<spaceToEnd])
            storage.replaceSubrange(0..<count - spaceToEnd, with: bytes[spaceToEnd...])
        }
        head = (head + count) % capacity
        filled = min(filled + count, capacity)
    }

    /// Returns all buffered data in order without clearing.
    public func read() -> Data {
        guard filled > 0 else { return Data() }

        let start = (head - filled + capacity) % capacity
        var result = [UInt8]()
        result.reserveCapacity(filled)

        if start + filled <= capacity {
            result.append(contentsOf: storage[start..<(start + filled)])
        } else {
            result.append(contentsOf: storage[start..<capacity])
            result.append(contentsOf: storage[0..<head])
        }

        return Data(result)
    }

    /// Returns all buffered data in order and clears the buffer.
    public mutating func flush() -> Data {
        let data = read()
        filled = 0
        head = 0
        return data
    }
}
