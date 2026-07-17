import XCTest
@testable import VoxboardCaptureCore

final class CaptureInputBudgetTests: XCTestCase {
    func test_acceptsValuesAtEveryLimit() throws {
        var budget = CaptureInputBudget()

        try budget.reserveSharedItems(CaptureInputLimits.maximumSharedItemCount)
        try budget.reserveText(characters: CaptureInputLimits.maximumTextCharacters)
        try budget.reserveAsset(bytes: CaptureInputLimits.maximumAggregateAssetByteCount)

        XCTAssertEqual(budget.sharedItemCount, CaptureInputLimits.maximumSharedItemCount)
        XCTAssertEqual(budget.textCharacterCount, CaptureInputLimits.maximumTextCharacters)
        XCTAssertEqual(budget.assetByteCount, CaptureInputLimits.maximumAggregateAssetByteCount)
    }

    func test_rejectsTooManyItemsInsteadOfSilentlyDroppingThem() throws {
        var budget = CaptureInputBudget()

        XCTAssertThrowsError(
            try budget.reserveSharedItems(CaptureInputLimits.maximumSharedItemCount + 1)
        ) { error in
            XCTAssertEqual(
                error as? CaptureInputLimitError,
                .tooManySharedItems(
                    count: CaptureInputLimits.maximumSharedItemCount + 1,
                    limit: CaptureInputLimits.maximumSharedItemCount
                )
            )
        }
        XCTAssertEqual(budget.sharedItemCount, 0)
    }

    func test_rejectsCumulativeTextAndAssetOverflowWithoutMutatingTotals() throws {
        var budget = CaptureInputBudget()
        try budget.reserveText(characters: CaptureInputLimits.maximumTextCharacters - 1)
        try budget.reserveAsset(bytes: CaptureInputLimits.maximumAggregateAssetByteCount - 1)

        XCTAssertThrowsError(try budget.reserveText(characters: 2))
        XCTAssertThrowsError(try budget.reserveAsset(bytes: 2))
        XCTAssertEqual(budget.textCharacterCount, CaptureInputLimits.maximumTextCharacters - 1)
        XCTAssertEqual(budget.assetByteCount, CaptureInputLimits.maximumAggregateAssetByteCount - 1)
    }

    func test_rejectsNegativeCounters() {
        var budget = CaptureInputBudget()

        XCTAssertThrowsError(try budget.reserveSharedItems(-1))
        XCTAssertThrowsError(try budget.reserveText(characters: -1))
        XCTAssertThrowsError(try budget.reserveAsset(bytes: -1))
    }
}
