import Foundation

public final class OnboardingAnalyticsClient: @unchecked Sendable {
    public static let shared = OnboardingAnalyticsClient(
        transport: OnboardingAnalyticsTransportFactory.makeDefaultTransport(),
        retryDelayNanoseconds: OnboardingAnalyticsClient.defaultRetryDelayForCurrentLaunch
    )

    public static let defaultQueueKey = "onboarding.analytics.queue.v1"
    public static let defaultQueueSize = 50
    public static let defaultRetryDelayNanoseconds: UInt64 = 30_000_000_000

    private let isEnabled: Bool
    private let assignmentStore: OnboardingExperimentAssignmentStore
    private let runtimeContextProvider: @Sendable () -> OnboardingAnalyticsRuntimeContext?
    private let state: OnboardingAnalyticsClientState
    private let transport: OnboardingAnalyticsTransport

    public init(
        transport: OnboardingAnalyticsTransport,
        defaults: OnboardingAnalyticsUserDefaultsStoring = SystemOnboardingAnalyticsUserDefaults(
            defaults: AppConstants.sharedDefaults ?? .standard
        ),
        queueKey: String = OnboardingAnalyticsClient.defaultQueueKey,
        maxQueueSize: Int = OnboardingAnalyticsClient.defaultQueueSize,
        isEnabled: Bool = OnboardingAnalyticsClient.isEnabledByDefault,
        retryDelayNanoseconds: UInt64 = OnboardingAnalyticsClient.defaultRetryDelayNanoseconds,
        assignmentStore: OnboardingExperimentAssignmentStore? = nil,
        runtimeContextProvider: @escaping @Sendable () -> OnboardingAnalyticsRuntimeContext? = {
            OnboardingAnalyticsRuntimeContext.current()
        }
    ) {
        self.isEnabled = isEnabled
        self.assignmentStore = assignmentStore ?? OnboardingExperimentAssignmentStore(defaults: defaults)
        self.runtimeContextProvider = runtimeContextProvider
        self.transport = transport
        self.state = OnboardingAnalyticsClientState(
            store: OnboardingAnalyticsQueueStore(defaults: defaults, key: queueKey),
            maxQueueSize: max(0, maxQueueSize),
            retryDelayNanoseconds: retryDelayNanoseconds
        )
    }

    public func track(_ event: OnboardingAnalyticsEvent) {
        guard isEnabled else { return }

        let assignment = assignmentStore.assignment()
        let runtimeContext = runtimeContextProvider()
        state.enqueue(event.encodedPayload(including: assignment, runtimeContext: runtimeContext))
        state.startFlushIfNeeded(transport: transport)
    }

    public func flush() {
        guard isEnabled else { return }
        state.startFlushIfNeeded(transport: transport)
    }

    public func flushAndWait() async {
        guard isEnabled else { return }
        await state.flushAndWait(transport: transport)
    }

    public func queuedPayloads() async -> [OnboardingAnalyticsPayload] {
        state.queuedPayloads()
    }

    public static var isEnabledByDefault: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["ONBOARDING_ANALYTICS_ENABLED"] == "1"
        #else
        true
        #endif
    }

    private static var defaultRetryDelayForCurrentLaunch: UInt64 {
        #if DEBUG
        if ProcessInfo.processInfo.environment["UITEST_ANALYTICS_TRANSPORT"] == "offline" ||
            ProcessInfo.processInfo.environment["ONBOARDING_ANALYTICS_TRANSPORT"] == "offline" {
            return 0
        }
        #endif

        return defaultRetryDelayNanoseconds
    }
}

public struct OnboardingAnalyticsRuntimeContext: Sendable {
    public let appVersion: String?
    public let buildNumber: String?
    public let platform: OnboardingAnalyticsPlatform

    public init(appVersion: String?, buildNumber: String?, platform: OnboardingAnalyticsPlatform) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.platform = platform
    }

    public static func current(bundle: Bundle = .main) -> OnboardingAnalyticsRuntimeContext {
        OnboardingAnalyticsRuntimeContext(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            platform: currentPlatform
        )
    }

    private static var currentPlatform: OnboardingAnalyticsPlatform {
        #if os(macOS)
        return .macOS
        #else
        return .iOS
        #endif
    }
}

private final class OnboardingAnalyticsClientState: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.bontecou.voxboard.onboarding-analytics-client")
    private let store: OnboardingAnalyticsQueueStore
    private let maxQueueSize: Int
    private let retryDelayNanoseconds: UInt64

    private var payloads: [OnboardingAnalyticsPayload]
    private var flushTask: Task<Void, Never>?

    init(store: OnboardingAnalyticsQueueStore, maxQueueSize: Int, retryDelayNanoseconds: UInt64) {
        self.store = store
        self.maxQueueSize = maxQueueSize
        self.retryDelayNanoseconds = retryDelayNanoseconds
        self.payloads = store.load()
        trimToQueueCap()
        store.save(payloads)
    }

    func enqueue(_ payload: OnboardingAnalyticsPayload) {
        queue.sync {
            payloads.append(payloadWithStableEventId(payload))
            trimToQueueCap()
            store.save(payloads)
        }
    }

    func startFlushIfNeeded(transport: OnboardingAnalyticsTransport) {
        queue.sync {
            guard flushTask == nil else { return }

            flushTask = Task.detached(priority: .utility) { [weak self, transport] in
                await self?.flushLoop(transport: transport)
            }
        }
    }

    func flushAndWait(transport: OnboardingAnalyticsTransport) async {
        startFlushIfNeeded(transport: transport)

        let task = queue.sync { flushTask }
        await task?.value
    }

    func queuedPayloads() -> [OnboardingAnalyticsPayload] {
        queue.sync { payloads }
    }

    private func flushLoop(transport: OnboardingAnalyticsTransport) async {
        var stoppedAfterFailure = false

        while let payload = nextPayload() {
            do {
                try await transport.send(payload)
                removeSentPayload(payload)
            } catch {
                stoppedAfterFailure = true
                break
            }
        }

        queue.sync {
            if payloads.isEmpty {
                flushTask = nil
            } else if stoppedAfterFailure, retryDelayNanoseconds > 0 {
                flushTask = Task.detached(priority: .utility) { [weak self, transport, retryDelayNanoseconds] in
                    try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
                    await self?.flushLoop(transport: transport)
                }
            } else if stoppedAfterFailure {
                flushTask = nil
            } else {
                flushTask = Task.detached(priority: .utility) { [weak self, transport] in
                    await self?.flushLoop(transport: transport)
                }
            }
        }
    }

    private func nextPayload() -> OnboardingAnalyticsPayload? {
        queue.sync { payloads.first }
    }

    private func removeSentPayload(_ payload: OnboardingAnalyticsPayload) {
        queue.sync {
            guard payloads.first == payload else { return }

            payloads.removeFirst()
            store.save(payloads)
        }
    }

    private func payloadWithStableEventId(_ payload: OnboardingAnalyticsPayload) -> OnboardingAnalyticsPayload {
        guard payload.eventId == nil else { return payload }
        return payload.withEventId(UUID().uuidString.lowercased())
    }

    private func trimToQueueCap() {
        guard maxQueueSize > 0 else {
            payloads.removeAll()
            return
        }

        if payloads.count > maxQueueSize {
            payloads.removeFirst(payloads.count - maxQueueSize)
        }
    }
}

private struct OnboardingAnalyticsQueueStore: Sendable {
    private let defaults: OnboardingAnalyticsUserDefaultsStoring
    private let key: String

    init(defaults: OnboardingAnalyticsUserDefaultsStoring, key: String) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [OnboardingAnalyticsPayload] {
        guard let data = defaults.data(forKey: key) else { return [] }

        let decoder = JSONDecoder()
        return (try? decoder.decode([OnboardingAnalyticsPayload].self, from: data)) ?? []
    }

    func save(_ payloads: [OnboardingAnalyticsPayload]) {
        guard !payloads.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        if let data = try? encoder.encode(payloads) {
            defaults.set(data, forKey: key)
        }
    }
}
