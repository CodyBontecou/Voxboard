import XCTest
@testable import VoxboardShared

final class OnboardingAnalyticsClientTests: XCTestCase {
    func testOfflineTransportQueuesStablePayloadWithAssignmentAndRuntimeContext() async {
        let defaults = FakeOnboardingAnalyticsDefaults()
        let client = OnboardingAnalyticsClient(
            transport: RecordingOnboardingAnalyticsTransport(error: URLError(.notConnectedToInternet)),
            defaults: defaults,
            queueKey: "onboarding.analytics.test.offline",
            isEnabled: true,
            retryDelayNanoseconds: 0,
            runtimeContextProvider: {
                OnboardingAnalyticsRuntimeContext(appVersion: "1.7.0", buildNumber: "123", platform: .iOS)
            }
        )

        client.track(OnboardingAnalyticsEvent(name: .onboardingStarted))
        await client.flushAndWait()

        let queuedPayloads = await client.queuedPayloads()
        let payload = try! XCTUnwrap(queuedPayloads.first)

        XCTAssertEqual(queuedPayloads.count, 1)
        XCTAssertNotNil(UUID(uuidString: try! XCTUnwrap(payload.eventId)))
        XCTAssertEqual(payload.eventName, "onboarding_started")
        XCTAssertEqual(payload.properties[.experimentId], .string("voxboard_onboarding_activation"))
        XCTAssertEqual(payload.properties[.variantId], .string("baseline_v1"))
        XCTAssertEqual(payload.properties[.appVersion], .string("1.7.0"))
        XCTAssertEqual(payload.properties[.buildNumber], .string("123"))
        XCTAssertEqual(payload.properties[.platform], .string("ios"))

        let data = try! XCTUnwrap(defaults.data(forKey: "onboarding.analytics.test.offline"))
        let persisted = try! JSONDecoder().decode([OnboardingAnalyticsPayload].self, from: data)
        XCTAssertEqual(persisted, queuedPayloads)
    }

    func testSuccessfulFlushRemovesQueuedPayload() async {
        let defaults = FakeOnboardingAnalyticsDefaults()
        let transport = RecordingOnboardingAnalyticsTransport()
        let client = OnboardingAnalyticsClient(
            transport: transport,
            defaults: defaults,
            queueKey: "onboarding.analytics.test.success",
            isEnabled: true,
            retryDelayNanoseconds: 0,
            runtimeContextProvider: { nil }
        )

        client.track(OnboardingAnalyticsEvent(name: .onboardingCompleted))
        await client.flushAndWait()

        let sentPayloads = await transport.payloadsValue()
        let queuedPayloads = await client.queuedPayloads()

        XCTAssertEqual(sentPayloads.count, 1)
        XCTAssertEqual(sentPayloads.first?.eventName, "onboarding_completed")
        XCTAssertTrue(queuedPayloads.isEmpty)
        XCTAssertNil(defaults.data(forKey: "onboarding.analytics.test.success"))
    }

    func testDisabledClientDoesNotQueueOrSend() async {
        let defaults = FakeOnboardingAnalyticsDefaults()
        let transport = RecordingOnboardingAnalyticsTransport()
        let client = OnboardingAnalyticsClient(
            transport: transport,
            defaults: defaults,
            queueKey: "onboarding.analytics.test.disabled",
            isEnabled: false,
            retryDelayNanoseconds: 0,
            runtimeContextProvider: { nil }
        )

        client.track(OnboardingAnalyticsEvent(name: .onboardingStarted))
        await client.flushAndWait()

        let queuedPayloads = await client.queuedPayloads()
        let sentPayloads = await transport.payloadsValue()

        XCTAssertTrue(queuedPayloads.isEmpty)
        XCTAssertTrue(sentPayloads.isEmpty)
        XCTAssertNil(defaults.data(forKey: "onboarding.analytics.test.disabled"))
    }

    func testTransportFactoryUsesNoOpWithoutEndpointAndCloudflareWithEndpoint() {
        let noEndpointTransport = OnboardingAnalyticsTransportFactory.makeDefaultTransport(
            environment: [:],
            defaults: FakeOnboardingAnalyticsDefaults()
        )
        XCTAssertTrue(noEndpointTransport is NoOpOnboardingAnalyticsTransport)

        let cloudflareTransport = OnboardingAnalyticsTransportFactory.makeDefaultTransport(
            environment: ["ONBOARDING_ANALYTICS_ENDPOINT_URL": "https://voxboard-onboarding.example"],
            defaults: FakeOnboardingAnalyticsDefaults()
        )
        XCTAssertTrue(cloudflareTransport is CloudflareOnboardingAnalyticsTransport)
    }
}

final class FakeOnboardingAnalyticsDefaults: OnboardingAnalyticsUserDefaultsStoring, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FakeOnboardingAnalyticsDefaults")
    private var storage: [String: Any] = [:]

    func string(forKey key: String) -> String? {
        queue.sync { storage[key] as? String }
    }

    func bool(forKey key: String) -> Bool {
        queue.sync { storage[key] as? Bool ?? false }
    }

    func data(forKey key: String) -> Data? {
        queue.sync { storage[key] as? Data }
    }

    func set(_ value: Any?, forKey key: String) {
        queue.sync {
            if let value {
                storage[key] = value
            } else {
                storage.removeValue(forKey: key)
            }
        }
    }

    func removeObject(forKey key: String) {
        queue.sync { _ = storage.removeValue(forKey: key) }
    }
}

actor RecordingOnboardingAnalyticsTransport: OnboardingAnalyticsTransport {
    private let error: Error?
    private var payloads: [OnboardingAnalyticsPayload] = []

    init(error: Error? = nil) {
        self.error = error
    }

    func send(_ payload: OnboardingAnalyticsPayload) async throws {
        if let error { throw error }
        payloads.append(payload)
    }

    func payloadsValue() -> [OnboardingAnalyticsPayload] {
        payloads
    }
}
