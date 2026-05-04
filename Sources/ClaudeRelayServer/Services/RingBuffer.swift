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
        let count = data.count
        guard count > 0 else { return }

        if count >= capacity {
            // Oversize write — only the last `capacity` bytes matter. Use
            // unsafe mutable bytes to copy in place rather than allocating
            // a fresh Array.
            let tail = data.suffix(capacity)
            storage.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                _ = tail.copyBytes(to: UnsafeMutableBufferPointer(start: base, count: capacity))
            }
            head = 0
            filled = capacity
            return
        }

        let spaceToEnd = capacity - head
        storage.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            if count <= spaceToEnd {
                _ = data.copyBytes(to: UnsafeMutableBufferPointer(start: base + head, count: count))
            } else {
                let splitIndex = data.startIndex.advanced(by: spaceToEnd)
                let first = data[data.startIndex..<splitIndex]
                let second = data[splitIndex...]
                _ = first.copyBytes(to: UnsafeMutableBufferPointer(start: base + head, count: spaceToEnd))
                _ = second.copyBytes(to: UnsafeMutableBufferPointer(start: base, count: count - spaceToEnd))
            }
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
