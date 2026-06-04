import Foundation

public protocol OnboardingAnalyticsTransport: Sendable {
    func send(_ payload: OnboardingAnalyticsPayload) async throws
}

public enum OnboardingAnalyticsTransportFactory {
    public static func makeDefaultTransport(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        defaults: OnboardingAnalyticsUserDefaultsStoring = SystemOnboardingAnalyticsUserDefaults(
            defaults: AppConstants.sharedDefaults ?? .standard
        )
    ) -> OnboardingAnalyticsTransport {
        #if DEBUG
        if environment["UITEST_ANALYTICS_TRANSPORT"] == "offline" ||
            environment["ONBOARDING_ANALYTICS_TRANSPORT"] == "offline" {
            return OfflineOnboardingAnalyticsTransport()
        }
        #endif

        if let transport = CloudflareOnboardingAnalyticsTransport.configured(
            environment: environment,
            bundle: bundle,
            defaults: defaults
        ) {
            return transport
        }

        return NoOpOnboardingAnalyticsTransport()
    }
}

public struct NoOpOnboardingAnalyticsTransport: OnboardingAnalyticsTransport {
    public init() {}
    public func send(_ payload: OnboardingAnalyticsPayload) async throws {}
}

public struct OfflineOnboardingAnalyticsTransport: OnboardingAnalyticsTransport {
    public init() {}
    public func send(_ payload: OnboardingAnalyticsPayload) async throws {
        throw URLError(.notConnectedToInternet)
    }
}
