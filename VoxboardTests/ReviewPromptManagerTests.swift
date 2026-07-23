import XCTest
@testable import Voxboard

final class ReviewPromptManagerTests: XCTestCase {
    private let policy = ReviewPromptPolicy()
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testBecomesEligibleAfterThirdSuccessfulCapture() {
        XCTAssertFalse(policy.isEligible(
            successfulCaptureCount: 2,
            successfulTranscriptionCount: 0,
            usageDayCount: 1,
            lastPromptAttemptAt: nil,
            now: now
        ))

        XCTAssertTrue(policy.isEligible(
            successfulCaptureCount: 3,
            successfulTranscriptionCount: 0,
            usageDayCount: 1,
            lastPromptAttemptAt: nil,
            now: now
        ))
    }

    func testRecentPromptAttemptSuppressesCaptureMilestonePrompt() {
        XCTAssertFalse(policy.isEligible(
            successfulCaptureCount: 3,
            successfulTranscriptionCount: 0,
            usageDayCount: 1,
            lastPromptAttemptAt: now.addingTimeInterval(-60),
            now: now
        ))
    }
}
