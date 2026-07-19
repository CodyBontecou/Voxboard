import XCTest
@testable import VoxboardShared

final class TranscriptionInsertionPlannerTests: XCTestCase {
    func testReturnsExactUndeliveredSuffix() {
        XCTAssertEqual(
            TranscriptionInsertionPlanner.plan(
                deliveredText: "Hello world",
                finalText: "Hello world from Vox"
            ),
            .insert(" from Vox")
        )
    }

    func testReportsAlreadyComplete() {
        XCTAssertEqual(
            TranscriptionInsertionPlanner.plan(
                deliveredText: "Hello world.",
                finalText: "Hello world."
            ),
            .alreadyComplete
        )
    }

    func testReconcilesPunctuationAndCaseWithoutRepeatingWords() {
        XCTAssertEqual(
            TranscriptionInsertionPlanner.plan(
                deliveredText: "hello world",
                finalText: "Hello, world! More text"
            ),
            .insert("! More text")
        )
    }

    func testDoesNotDuplicatePunctuationAlreadyDeliveredLive() {
        XCTAssertEqual(
            TranscriptionInsertionPlanner.plan(
                deliveredText: "hello world.",
                finalText: "Hello, world! More text"
            ),
            .insert(" More text")
        )
    }

    func testPunctuationOnlyDifferenceNeedsNoInsertion() {
        XCTAssertEqual(
            TranscriptionInsertionPlanner.plan(
                deliveredText: "hello world.",
                finalText: "Hello, world!"
            ),
            .alreadyComplete
        )
    }

    func testRejectsWordMismatch() {
        XCTAssertEqual(
            TranscriptionInsertionPlanner.plan(
                deliveredText: "hello there",
                finalText: "hello world from Vox"
            ),
            .unsafeMismatch
        )
    }

    func testEmptyDeliveredTextInsertsFullTranscript() {
        XCTAssertEqual(
            TranscriptionInsertionPlanner.plan(
                deliveredText: "",
                finalText: "Full transcript"
            ),
            .insert("Full transcript")
        )
    }
}
