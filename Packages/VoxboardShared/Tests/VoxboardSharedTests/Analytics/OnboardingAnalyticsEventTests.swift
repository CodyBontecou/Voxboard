import XCTest
@testable import VoxboardShared

final class OnboardingAnalyticsEventTests: XCTestCase {
    func testPayloadEncodesOnlyAllowlistedProperties() {
        let event = OnboardingAnalyticsEvent(
            name: .onboardingStepViewed,
            properties: OnboardingAnalyticsProperties(
                experimentId: "voxboard_onboarding_activation",
                variantId: "baseline_v1",
                appVersion: "1.2.3",
                buildNumber: "42",
                platform: .iOS,
                onboardingStep: .microphoneAccess,
                permissionStatus: .granted,
                modelEngine: .whisper,
                modelSizeBucket: .bundled,
                fileExportFormat: .md,
                fileExportMode: .newFile,
                freeMinutesUsedBucket: .underFiveMinutes,
                freeMinutesRemainingBucket: .fiveToFifteenMinutes,
                paywallContext: .onboarding,
                productId: .lifetimeUnlock,
                purchaseOutcome: .started,
                errorCategory: .unknown
            )
        )

        let payload = event.encodedPayload()

        XCTAssertNil(payload.eventId)
        XCTAssertEqual(payload.eventName, "onboarding_step_viewed")
        XCTAssertEqual(
            Set(payload.properties.keys),
            Set(OnboardingAnalyticsPropertyKey.allCases)
        )
        XCTAssertEqual(payload.properties[.onboardingStep], .string("microphone_access"))
        XCTAssertEqual(payload.properties[.productId], .string("bontecou.Voxboard.unlock"))
    }

    func testSensitiveIdentifiersAreDroppedBeforeEncoding() {
        let payload = OnboardingAnalyticsEvent(
            name: .onboardingStarted,
            properties: OnboardingAnalyticsProperties(
                experimentId: "voice_2026_05_30",
                variantId: "FolderName",
                appVersion: "1.2.beta",
                buildNumber: "12b"
            )
        ).encodedPayload()

        XCTAssertNil(payload.properties[.experimentId])
        XCTAssertNil(payload.properties[.variantId])
        XCTAssertNil(payload.properties[.appVersion])
        XCTAssertNil(payload.properties[.buildNumber])
    }

    func testAllEventNamesUseOnboardingNamespace() {
        XCTAssertTrue(OnboardingAnalyticsEventName.allCases.contains(.onboardingStarted))
        XCTAssertTrue(OnboardingAnalyticsEventName.allCases.contains(.onboardingStepViewed))
        XCTAssertTrue(OnboardingAnalyticsEventName.allCases.contains(.onboardingCompleted))

        for name in OnboardingAnalyticsEventName.allCases.map(\.rawValue) {
            XCTAssertTrue(name.hasPrefix("onboarding_"), "\(name) should stay in onboarding namespace")
        }
    }
}
