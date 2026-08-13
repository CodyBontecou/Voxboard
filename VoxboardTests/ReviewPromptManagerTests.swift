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

    @MainActor
    func testMalformedPersistedDefaultsFallBackWithoutOverwritingSourceValues() throws {
        let suiteName = "ReviewPromptManagerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("not-an-int", forKey: ReviewPromptManager.Keys.successfulCaptureCount)
        defaults.set([1, 2], forKey: ReviewPromptManager.Keys.usageDayIdentifiers)
        defaults.set("not-a-date", forKey: ReviewPromptManager.Keys.lastPromptAttemptAt)
        defaults.set("not-a-bool", forKey: ReviewPromptManager.Keys.pendingPrompt)

        let manager = ReviewPromptManager(defaults: defaults, now: { self.now })
        manager.recordAppUsageDay()

        XCTAssertEqual(defaults.string(forKey: ReviewPromptManager.Keys.successfulCaptureCount), "not-an-int")
        XCTAssertEqual(defaults.string(forKey: ReviewPromptManager.Keys.lastPromptAttemptAt), "not-a-date")
        XCTAssertEqual(defaults.string(forKey: ReviewPromptManager.Keys.pendingPrompt), "not-a-bool")
        XCTAssertEqual(defaults.stringArray(forKey: ReviewPromptManager.Keys.usageDayIdentifiers)?.count, 1)
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
