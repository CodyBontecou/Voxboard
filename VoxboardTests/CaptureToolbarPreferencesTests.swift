import XCTest
@testable import Voxboard

final class CaptureToolbarPreferencesTests: XCTestCase {
    func test_newExtractTextActionFollowsDocumentScanByDefault() throws {
        let order = CaptureToolbarPreferences.migratedActionOrder(from: nil)
        let scanIndex = try XCTUnwrap(order.firstIndex(of: .scanDocument))

        XCTAssertEqual(order[scanIndex + 1], .extractText)
    }

    func test_migrationPreservesCustomOrderAndInsertsExtractTextAfterScan() {
        let order = CaptureToolbarPreferences.migratedActionOrder(from: [
            "undo",
            "scanDocument",
            "addMedia",
            "undo",
            "retired-action",
        ])

        XCTAssertEqual(Array(order.prefix(4)), [
            .undo,
            .scanDocument,
            .extractText,
            .addMedia,
        ])
        XCTAssertEqual(order.filter { $0 == .undo }.count, 1)
        XCTAssertEqual(Set(order), Set(CaptureToolbarAction.allCases))
    }
}
