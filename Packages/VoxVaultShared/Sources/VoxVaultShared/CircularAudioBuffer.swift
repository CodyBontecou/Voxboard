import Foundation

/// A fixed-capacity circular buffer for Float audio samples.
///
/// Thread-safe for concurrent append (writer) and extract (reader).
/// Used by the persistent recorder to maintain a rolling window of audio
/// that the keyboard can request transcription of at any time.
public final class CircularAudioBuffer: @unchecked Sendable {
    private var buffer: [Float]
    private let capacity: Int
    private var writeIndex: Int = 0
    /// Total number of samples written since creation (monotonically increasing).
    public private(set) var totalSamplesWritten: Int64 = 0
    private let lock = NSLock()

    /// - Parameter capacity: Maximum number of Float samples to store.
    ///   At 16 kHz mono, 5 minutes ≈ 4,800,000 samples ≈ 19.2 MB.
    public init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Float](repeating: 0, count: capacity)
    }

    /// Append samples from an unsafe buffer pointer (zero-copy from audio tap).
    public func append(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock()
        defer { lock.unlock() }

        let count = samples.count
        var remaining = count
        var srcOffset = 0

        while remaining > 0 {
            let spaceToEnd = capacity - writeIndex
            let chunk = min(remaining, spaceToEnd)

            buffer.withUnsafeMutableBufferPointer { dst in
                let dstStart = dst.baseAddress! + writeIndex
                let srcStart = samples.baseAddress! + srcOffset
                dstStart.initialize(from: srcStart, count: chunk)
            }

            writeIndex = (writeIndex + chunk) % capacity
            srcOffset += chunk
            remaining -= chunk
        }

        totalSamplesWritten += Int64(count)
    }

    /// Append samples from an array.
    public func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    /// Extract samples from absolute index range [start, end).
    /// Returns nil if the requested range has been overwritten (too old) or is invalid.
    public func extract(from startAbsolute: Int64, to endAbsolute: Int64) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }

        let earliestAvailable = max(0, totalSamplesWritten - Int64(capacity))
        guard startAbsolute >= earliestAvailable,
              endAbsolute <= totalSamplesWritten,
              endAbsolute > startAbsolute else {
            return nil
        }

        let count = Int(endAbsolute - startAbsolute)
        var result = [Float](repeating: 0, count: count)

        // Map absolute index to buffer position
        let startPos = Int(startAbsolute % Int64(capacity))

        var remaining = count
        var dstOffset = 0
        var srcPos = startPos

        while remaining > 0 {
            let spaceToEnd = capacity - srcPos
            let chunk = min(remaining, spaceToEnd)

            buffer.withUnsafeBufferPointer { src in
                for i in 0..<chunk {
                    result[dstOffset + i] = src[srcPos + i]
                }
            }

            srcPos = (srcPos + chunk) % capacity
            dstOffset += chunk
            remaining -= chunk
        }

        return result
    }

    /// The earliest absolute sample index still available in the buffer.
    public var earliestAvailableIndex: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return max(0, totalSamplesWritten - Int64(capacity))
    }

    /// Reset the buffer, clearing all data.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        writeIndex = 0
        totalSamplesWritten = 0
    }
}
