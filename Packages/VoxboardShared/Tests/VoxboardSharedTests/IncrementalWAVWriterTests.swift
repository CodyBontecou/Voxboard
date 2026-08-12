import Foundation
import XCTest
@testable import VoxboardShared

final class IncrementalWAVWriterTests: XCTestCase {
    func test_eachAppendLeavesReadableRiffAndDataLengths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "IncrementalWAVWriterTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("active.wav")
        let writer = try IncrementalWAVWriter(url: url)
        let samples: [Float] = [-1, -0.5, 0, 0.5, 1]

        try samples.withUnsafeBufferPointer { pointer in
            try writer.append(pointer)
        }

        let dataBeforeFinalize = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: dataBeforeFinalize[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: dataBeforeFinalize[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(readUInt32LE(dataBeforeFinalize, at: 4), UInt32(36 + samples.count * 2))
        XCTAssertEqual(readUInt32LE(dataBeforeFinalize, at: 40), UInt32(samples.count * 2))
        XCTAssertEqual(dataBeforeFinalize.count, 44 + samples.count * 2)

        try writer.finalize()
        XCTAssertEqual(try Data(contentsOf: url), dataBeforeFinalize)
    }

    func test_multipleAppendsAccumulateWithoutRewritingSamples() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "IncrementalWAVWriterTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("active.wav")
        let writer = try IncrementalWAVWriter(url: url)

        for samples in [[Float](repeating: 0.25, count: 100), [Float](repeating: -0.25, count: 60)] {
            try samples.withUnsafeBufferPointer { pointer in
                try writer.append(pointer)
            }
        }
        try writer.finalize()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(readUInt32LE(data, at: 40), 320)
        XCTAssertEqual(data.count, 364)
        XCTAssertEqual(writer.recordedDataByteCount, 320)
    }

    private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { result, element in
            result | (UInt32(element.element) << UInt32(element.offset * 8))
        }
    }
}
