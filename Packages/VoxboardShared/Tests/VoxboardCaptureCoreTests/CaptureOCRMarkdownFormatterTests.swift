import XCTest
@testable import VoxboardCaptureCore

final class CaptureOCRMarkdownFormatterTests: XCTestCase {
    private let formatter = CaptureOCRMarkdownFormatter()

    func test_renderPreservesPageAndLineOrder() {
        let markdown = formatter.render(pageTexts: [
            "First line\nSecond line",
            "Third line",
        ])

        XCTAssertEqual(markdown, "First line\nSecond line\n\nThird line")
    }

    func test_renderOmitsEmptyPagesAndTrimsOnlyPageBoundaries() {
        let markdown = formatter.render(pageTexts: [
            "  \n",
            "  Kept boundary spaces  \n    indented line\n",
            "",
        ])

        XCTAssertEqual(markdown, "Kept boundary spaces  \n    indented line")
    }

    func test_renderNormalizesLineEndings() {
        let markdown = formatter.render(pageTexts: ["One\r\nTwo\rThree"])

        XCTAssertEqual(markdown, "One\nTwo\nThree")
    }

    func test_renderReturnsEmptyStringWhenNothingWasRecognized() {
        XCTAssertEqual(formatter.render(pageTexts: ["", " \n "]), "")
    }
}
