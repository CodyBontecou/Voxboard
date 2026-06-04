import XCTest
@testable import VoxboardShared

final class OnboardingAnalyticsFunnelTests: XCTestCase {
    func testUsageBucketsAreCoarse() {
        XCTAssertEqual(OnboardingAnalyticsQuotaState.bucket(forMinutes: 0), .zero)
        XCTAssertEqual(OnboardingAnalyticsQuotaState.bucket(forMinutes: 0.1), .underFiveMinutes)
        XCTAssertEqual(OnboardingAnalyticsQuotaState.bucket(forMinutes: 4.99), .underFiveMinutes)
        XCTAssertEqual(OnboardingAnalyticsQuotaState.bucket(forMinutes: 5), .fiveToFifteenMinutes)
        XCTAssertEqual(OnboardingAnalyticsQuotaState.bucket(forMinutes: 14.99), .fiveToFifteenMinutes)
        XCTAssertEqual(OnboardingAnalyticsQuotaState.bucket(forMinutes: 15), .fifteenPlusMinutes)
    }

    func testQuotaStateUsesUnlimitedBucketForUnlockedUsers() {
        let quotaState = OnboardingAnalyticsQuotaState(
            totalSecondsUsed: 12_000,
            freeLimitSeconds: 900,
            hasUnlocked: true
        )

        XCTAssertEqual(quotaState.freeMinutesUsedBucket, .unlimited)
        XCTAssertEqual(quotaState.freeMinutesRemainingBucket, .unlimited)
    }

    func testModelMetadataDoesNotExposeModelNameOrPath() {
        let bundledModel = WhisperModelInfo.availableModels.first { $0.id == "ggml-base" }!
        let parakeetModel = WhisperModelInfo.availableModels.first { $0.id == "parakeet-v3" }!

        XCTAssertEqual(OnboardingAnalyticsModelMetadata(model: bundledModel).engine, .whisper)
        XCTAssertEqual(OnboardingAnalyticsModelMetadata(model: bundledModel).sizeBucket, .bundled)
        XCTAssertEqual(OnboardingAnalyticsModelMetadata(model: parakeetModel).engine, .parakeet)
        XCTAssertEqual(OnboardingAnalyticsModelMetadata(model: parakeetModel).sizeBucket, .fiveHundredMBTo1GB)
    }

    func testPaywallHelperBuildsTypedFunnelEvent() async {
        let transport = RecordingOnboardingAnalyticsTransport()
        let client = OnboardingAnalyticsClient(
            transport: transport,
            defaults: FakeOnboardingAnalyticsDefaults(),
            queueKey: "onboarding.analytics.test.paywall",
            isEnabled: true,
            retryDelayNanoseconds: 0,
            runtimeContextProvider: { nil }
        )
        let quotaState = OnboardingAnalyticsQuotaState(
            freeMinutesUsedBucket: .fiveToFifteenMinutes,
            freeMinutesRemainingBucket: .underFiveMinutes
        )

        client.trackPaywallShown(context: .usageMeter, quotaState: quotaState)
        await client.flushAndWait()

        let payload = await transport.payloadsValue().first
        XCTAssertEqual(payload?.eventName, "onboarding_paywall_shown")
        XCTAssertEqual(payload?.properties[.paywallContext], .string("usage_meter"))
        XCTAssertEqual(payload?.properties[.freeMinutesUsedBucket], .string("5_15_min"))
        XCTAssertEqual(payload?.properties[.freeMinutesRemainingBucket], .string("0_5_min"))
    }
}
