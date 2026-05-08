import Foundation
import os.lock

/// Thread-safe ring buffer for streaming 16 kHz mono audio.
///
/// Fixed capacity — oldest samples are overwritten on overflow. Appends
/// are safe from the audio thread; reads return independent copies so
/// async consumers (Whisper, Smart-Turn) can process without a lock.
public final class StreamingAudioBuffer: @unchecked Sendable {

    private var storage: [Float]
    private let capacity: Int
    private let sampleRate: Double

    /// Monotonic sample-count since buffer creation. Callers mark
    /// positions to extract slices later via `audioSince(position:)`.
    private var writeCount: Int = 0

    private var lock = os_unfair_lock_s()

    public init(capacitySeconds: TimeInterval, sampleRate: Double) {
        let cap = Int(capacitySeconds * sampleRate)
        self.capacity = cap
        self.sampleRate = sampleRate
        self.storage = Array(repeating: 0, count: cap)
    }

    /// Current monotonic write position. Use as a marker before
    /// calling `audioSince(position:)` to extract an utterance.
    public var currentPosition: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return writeCount
    }

    /// Append samples from the audio thread. Wraps around on overflow.
    public func append(_ samples: [Float]) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        for sample in samples {
            storage[writeCount % capacity] = sample
            writeCount += 1
        }
    }

    /// Read the most recent `duration` seconds of audio. If fewer samples are
    /// available, returns what's there. Returns an independent copy.
    public func lastSeconds(_ duration: TimeInterval) -> [Float] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let wanted = min(Int(duration * sampleRate), writeCount, capacity)
        if wanted == 0 { return [] }

        let startAbsolute = writeCount - wanted
        return extractSlice(fromAbsolute: startAbsolute, count: wanted)
    }

    /// Read audio written since the given position. If that position has
    /// been overwritten (older than capacity), returns the oldest available
    /// samples up to capacity.
    public func audioSince(position: Int) -> [Float] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let oldestAvailable = max(0, writeCount - capacity)
        let startAbsolute = max(position, oldestAvailable)
        let count = writeCount - startAbsolute
        if count <= 0 { return [] }

        return extractSlice(fromAbsolute: startAbsolute, count: count)
    }

    /// Must be called with the lock held.
    private func extractSlice(fromAbsolute start: Int, count: Int) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(count)
        for i in 0..<count {
            out.append(storage[(start + i) % capacity])
        }
        return out
    }
}
