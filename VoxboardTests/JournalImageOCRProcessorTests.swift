import UIKit
import XCTest
@testable import Voxboard

final class JournalImageOCRProcessorTests: XCTestCase {
    @MainActor
    func test_processRecognizesMultiplePagesInOrder() async throws {
        let firstPage = try XCTUnwrap(makePageImage(text: "ALPHA JOURNAL PAGE"))
        let secondPage = try XCTUnwrap(makePageImage(text: "OMEGA JOURNAL PAGE"))

        let markdown = try await JournalImageOCRProcessor.process(
            pageImages: [firstPage, secondPage]
        ).lowercased()
        let alpha = try XCTUnwrap(markdown.range(of: "alpha"))
        let omega = try XCTUnwrap(markdown.range(of: "omega"))

        XCTAssertLessThan(alpha.lowerBound, omega.lowerBound)
        XCTAssertTrue(markdown.contains("\n\n"))
    }

    func test_processRejectsAnEmptySelection() async {
        do {
            _ = try await JournalImageOCRProcessor.process(pageImages: [])
            XCTFail("Expected an empty image selection to fail")
        } catch {
            XCTAssertEqual(error as? JournalImageOCRProcessorError, .noImages)
        }
    }

    @MainActor
    func test_processReportsTheUnreadablePageIndex() async throws {
        let validPage = try XCTUnwrap(makePageImage(text: "VALID JOURNAL PAGE"))

        do {
            _ = try await JournalImageOCRProcessor.process(
                pageImages: [validPage, Data("not an image".utf8)]
            )
            XCTFail("Expected an unreadable selected page to fail")
        } catch {
            XCTAssertEqual(
                error as? JournalImageOCRProcessorError,
                .unreadableImage(page: 2)
            )
        }
    }

    @MainActor
    func test_documentScanStillSkipsUnreadablePages() async throws {
        let validPage = try XCTUnwrap(makePageImage(text: "SCANNED JOURNAL PAGE"))

        let scan = try await DocumentScanProcessor.process(
            pageImages: [Data("not an image".utf8), validPage]
        )

        XCTAssertTrue(scan.extractedText?.lowercased().contains("scanned") == true)
        XCTAssertFalse(scan.pdfData.isEmpty)
        XCTAssertEqual(scan.pageImages.count, 2)
    }

    @MainActor
    private func makePageImage(text: String) -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 800))
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 800))
            (text as NSString).draw(
                at: CGPoint(x: 80, y: 260),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 82, weight: .semibold),
                    .foregroundColor: UIColor.black,
                ]
            )
        }
        return image.jpegData(compressionQuality: 0.95)
    }
}
