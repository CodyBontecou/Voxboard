import XCTest
@testable import VoxboardShared

final class CircularAudioBufferTests: XCTestCase {
    func testExtractAvailableReturnsBoundedChunksAndNextCursor() {
        let buffer = CircularAudioBuffer(capacity: 16)
        buffer.append((0..<10).map(Float.init))

        let first = buffer.extractAvailable(from: 2, maxCount: 4)
        XCTAssertEqual(first?.samples, [2, 3, 4, 5])
        XCTAssertEqual(first?.nextIndex, 6)

        let stopped = buffer.extractAvailable(from: 6, through: 8, maxCount: 4)
        XCTAssertEqual(stopped?.samples, [6, 7])
        XCTAssertEqual(stopped?.nextIndex, 8)
    }

    func testExtractAvailableRejectsOverwrittenCursor() {
        let buffer = CircularAudioBuffer(capacity: 4)
        buffer.append((0..<8).map(Float.init))

        XCTAssertEqual(buffer.earliestAvailableIndex, 4)
        XCTAssertNil(buffer.extractAvailable(from: 3, maxCount: 2))
        XCTAssertEqual(buffer.extractAvailable(from: 4, maxCount: 2)?.samples, [4, 5])
    }

    func testTotalSamplesWrittenUsesMonotonicAbsoluteIndex() {
        let buffer = CircularAudioBuffer(capacity: 4)
        buffer.append([1, 2, 3])
        buffer.append([4, 5])

        XCTAssertEqual(buffer.totalSamplesWritten, 5)
        XCTAssertEqual(buffer.extract(from: 1, to: 5), [2, 3, 4, 5])
    }
}
