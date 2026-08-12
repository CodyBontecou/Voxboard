import Foundation

/// Thread-safe 16 kHz mono PCM journal for an active recording. RIFF and data
/// lengths are refreshed after every append, so the last flushed prefix remains
/// readable even if the app terminates before Stop is tapped.
public final class IncrementalWAVWriter: @unchecked Sendable {
    public let url: URL
    public let sampleRate: Double

    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private var dataByteCount: UInt64 = 0
    private var bytesSinceSynchronization: UInt64 = 0

    public init(url: URL, sampleRate: Double = 16_000) throws {
        self.url = url
        self.sampleRate = sampleRate
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forUpdating: url)
        fileHandle = handle
        try handle.write(contentsOf: Self.header(dataByteCount: 0, sampleRate: sampleRate))
        try handle.synchronize()
    }

    deinit {
        lock.withLock {
            try? finalizeUnlocked()
        }
    }

    public func append(samples: [Float]) throws {
        try samples.withUnsafeBufferPointer { pointer in
            try append(pointer)
        }
    }

    public func append(_ samples: UnsafeBufferPointer<Float>) throws {
        guard !samples.isEmpty else { return }
        var int16Samples = [Int16]()
        int16Samples.reserveCapacity(samples.count)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            int16Samples.append(Int16(clamped * 32_767))
        }
        let data = int16Samples.withUnsafeBytes { Data($0) }

        try lock.withLock {
            guard let fileHandle else { throw CocoaError(.fileWriteUnknown) }
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: data)
            dataByteCount += UInt64(data.count)
            bytesSinceSynchronization += UInt64(data.count)
            try updateHeaderUnlocked()

            let bytesPerSecond = UInt64(max(1, sampleRate.rounded())) * 2
            if bytesSinceSynchronization >= bytesPerSecond {
                try fileHandle.synchronize()
                bytesSinceSynchronization = 0
            }
        }
    }

    /// Flushes the final header and closes the file. Repeated calls are safe.
    @discardableResult
    public func finalize() throws -> URL {
        try lock.withLock {
            try finalizeUnlocked()
            return url
        }
    }

    public var recordedDataByteCount: UInt64 {
        lock.withLock { dataByteCount }
    }

    private func finalizeUnlocked() throws {
        guard let fileHandle else { return }
        try updateHeaderUnlocked()
        try fileHandle.synchronize()
        try fileHandle.close()
        self.fileHandle = nil
    }

    private func updateHeaderUnlocked() throws {
        guard let fileHandle else { return }
        let boundedDataSize = UInt32(min(dataByteCount, UInt64(UInt32.max - 36)))
        try fileHandle.seek(toOffset: 4)
        try fileHandle.write(contentsOf: Self.littleEndianData(36 + boundedDataSize))
        try fileHandle.seek(toOffset: 40)
        try fileHandle.write(contentsOf: Self.littleEndianData(boundedDataSize))
        try fileHandle.seekToEnd()
    }

    private static func header(dataByteCount: UInt32, sampleRate: Double) -> Data {
        let sampleRateValue = UInt32(max(1, min(Double(UInt32.max), sampleRate.rounded())))
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(littleEndianData(36 + dataByteCount))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(littleEndianData(UInt32(16)))
        data.append(littleEndianData(UInt16(1)))
        data.append(littleEndianData(UInt16(1)))
        data.append(littleEndianData(sampleRateValue))
        data.append(littleEndianData(sampleRateValue * 2))
        data.append(littleEndianData(UInt16(2)))
        data.append(littleEndianData(UInt16(16)))
        data.append(contentsOf: "data".utf8)
        data.append(littleEndianData(dataByteCount))
        return data
    }

    private static func littleEndianData<T: FixedWidthInteger>(_ value: T) -> Data {
        var littleEndian = value.littleEndian
        return Swift.withUnsafeBytes(of: &littleEndian) { Data($0) }
    }
}
