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

    func testCaptureUsageBucketsAreCoarse() {
        XCTAssertEqual(OnboardingAnalyticsQuotaState.bucket(forCaptures: 0), .zero)
        XCTAssertEqual(OnboardingAnalyticsQuotaState.bucket(forCaptures: 1), .oneToThree)
        XCTAssertEqual(OnboardingAnalyticsQuotaState.bucket(forCaptures: 3), .oneToThree)
        XCTAssertEqual(OnboardingAnalyticsQuotaState.bucket(forCaptures: 4), .fourToSeven)
        XCTAssertEqual(OnboardingAnalyticsQuotaState.bucket(forCaptures: 7), .fourToSeven)
        XCTAssertEqual(OnboardingAnalyticsQuotaState.bucket(forCaptures: 8), .eightToNine)
        XCTAssertEqual(OnboardingAnalyticsQuotaState.bucket(forCaptures: 9), .eightToNine)
        XCTAssertEqual(OnboardingAnalyticsQuotaState.bucket(forCaptures: 10), .tenPlus)
    }

    func testQuotaStateUsesUnlimitedBucketForUnlockedUsers() {
        let quotaState = OnboardingAnalyticsQuotaState(
            totalSecondsUsed: 12_000,
            freeLimitSeconds: 900,
            successfulCapturesUsed: 10,
            hasUnlocked: true
        )

        XCTAssertEqual(quotaState.freeMinutesUsedBucket, .unlimited)
        XCTAssertEqual(quotaState.freeMinutesRemainingBucket, .unlimited)
        XCTAssertEqual(quotaState.freeCapturesUsedBucket, .unlimited)
        XCTAssertEqual(quotaState.freeCapturesRemainingBucket, .unlimited)
    }

    func testModelMetadataDoesNotExposeModelNameOrPath() {
        let baseModel = WhisperModelInfo.availableModels.first { $0.id == "ggml-base" }!
        let parakeetModel = WhisperModelInfo.availableModels.first { $0.id == "parakeet-v3" }!

        XCTAssertEqual(OnboardingAnalyticsModelMetadata(model: baseModel).engine, .whisper)
        XCTAssertEqual(OnboardingAnalyticsModelMetadata(model: baseModel).sizeBucket, .oneHundredTo500MB)
        XCTAssertEqual(OnboardingAnalyticsModelMetadata(model: parakeetModel).engine, .parakeet)
        XCTAssertEqual(OnboardingAnalyticsModelMetadata(model: parakeetModel).sizeBucket, .fiveHundredMBTo1GB)

        let appleSpeech = OnboardingAnalyticsModelMetadata(engine: .appleSpeech, sizeBucket: .unknown)
        XCTAssertEqual(appleSpeech.engine.rawValue, "apple_speech")
        XCTAssertEqual(appleSpeech.sizeBucket, .unknown)
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
            freeMinutesRemainingBucket: .underFiveMinutes,
            freeCapturesUsedBucket: .eightToNine,
            freeCapturesRemainingBucket: .oneToThree
        )

        client.trackPaywallShown(context: .captureLimit, quotaState: quotaState)
        await client.flushAndWait()

        let payload = await transport.payloadsValue().first
        XCTAssertEqual(payload?.eventName, "onboarding_paywall_shown")
        XCTAssertEqual(payload?.properties[.paywallContext], .string("capture_limit"))
        XCTAssertEqual(payload?.properties[.freeMinutesUsedBucket], .string("5_15_min"))
        XCTAssertEqual(payload?.properties[.freeMinutesRemainingBucket], .string("0_5_min"))
        XCTAssertEqual(payload?.properties[.freeCapturesUsedBucket], .string("8_9"))
        XCTAssertEqual(payload?.properties[.freeCapturesRemainingBucket], .string("1_3"))
    }
}
