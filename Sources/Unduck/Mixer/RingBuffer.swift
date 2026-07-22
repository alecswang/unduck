import Foundation

/// Single-producer single-consumer float ring buffer.
///
/// The producer is a Core Audio tap callback and the consumer is the render
/// callback of our own output engine; both are real-time threads, so neither side
/// may allocate, lock, or block. Underruns are filled with silence rather than
/// stalling — a dropout is recoverable, a blocked render thread is not.
final class RingBuffer {
    private var storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var writeIndex = 0
    private var readIndex = 0
    private let lock = os_unfair_lock_t.allocate(capacity: 1)

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deallocate()
        lock.deallocate()
    }

    func write(_ samples: UnsafePointer<Float>, count: Int) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        for i in 0..<count {
            storage[writeIndex] = samples[i]
            writeIndex = (writeIndex + 1) % capacity
            // Overrun: the consumer is behind. Drop the oldest sample rather than
            // the newest, so what plays is the most recent audio.
            if writeIndex == readIndex { readIndex = (readIndex + 1) % capacity }
        }
    }

    /// Fills `destination` with up to `count` samples, zero-padding on underrun.
    /// Returns the number of real samples delivered.
    @discardableResult
    func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        var delivered = 0
        for i in 0..<count {
            if readIndex == writeIndex {
                destination[i] = 0
            } else {
                destination[i] = storage[readIndex]
                readIndex = (readIndex + 1) % capacity
                delivered += 1
            }
        }
        return delivered
    }

    var available: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return (writeIndex - readIndex + capacity) % capacity
    }

    func clear() {
        os_unfair_lock_lock(lock)
        readIndex = writeIndex
        os_unfair_lock_unlock(lock)
    }
}
