import Foundation

public struct OnboardingAnalyticsQuotaState: Equatable, Sendable {
    public let freeMinutesUsedBucket: OnboardingAnalyticsUsageBucket
    public let freeMinutesRemainingBucket: OnboardingAnalyticsUsageBucket
    public let freeCapturesUsedBucket: OnboardingAnalyticsCaptureUsageBucket?
    public let freeCapturesRemainingBucket: OnboardingAnalyticsCaptureUsageBucket?

    public init(
        freeMinutesUsedBucket: OnboardingAnalyticsUsageBucket,
        freeMinutesRemainingBucket: OnboardingAnalyticsUsageBucket,
        freeCapturesUsedBucket: OnboardingAnalyticsCaptureUsageBucket? = nil,
        freeCapturesRemainingBucket: OnboardingAnalyticsCaptureUsageBucket? = nil
    ) {
        self.freeMinutesUsedBucket = freeMinutesUsedBucket
        self.freeMinutesRemainingBucket = freeMinutesRemainingBucket
        self.freeCapturesUsedBucket = freeCapturesUsedBucket
        self.freeCapturesRemainingBucket = freeCapturesRemainingBucket
    }

    public init(
        totalSecondsUsed: Double,
        freeLimitSeconds: Double,
        successfulCapturesUsed: Int? = nil,
        freeCaptureLimit: Int = UsageTracker.freeCaptureLimit,
        hasUnlocked: Bool
    ) {
        if hasUnlocked {
            self.freeMinutesUsedBucket = .unlimited
            self.freeMinutesRemainingBucket = .unlimited
            self.freeCapturesUsedBucket = successfulCapturesUsed == nil ? nil : .unlimited
            self.freeCapturesRemainingBucket = successfulCapturesUsed == nil ? nil : .unlimited
            return
        }

        self.freeMinutesUsedBucket = Self.bucket(forMinutes: totalSecondsUsed / 60.0)
        let remainingSeconds = max(0, freeLimitSeconds - totalSecondsUsed)
        self.freeMinutesRemainingBucket = Self.bucket(forMinutes: remainingSeconds / 60.0)
        self.freeCapturesUsedBucket = successfulCapturesUsed.map { Self.bucket(forCaptures: $0) }
        self.freeCapturesRemainingBucket = successfulCapturesUsed.map {
            Self.bucket(forCaptures: max(0, freeCaptureLimit - $0))
        }
    }

    public static func bucket(forMinutes minutes: Double) -> OnboardingAnalyticsUsageBucket {
        guard minutes.isFinite else { return .unknown }

        switch max(0, minutes) {
        case 0:
            return .zero
        case 0..<5:
            return .underFiveMinutes
        case 5..<15:
            return .fiveToFifteenMinutes
        default:
            return .fifteenPlusMinutes
        }
    }

    public static func bucket(forCaptures count: Int) -> OnboardingAnalyticsCaptureUsageBucket {
        switch max(0, count) {
        case 0:
            return .zero
        case 1...3:
            return .oneToThree
        case 4...7:
            return .fourToSeven
        case 8...9:
            return .eightToNine
        default:
            return .tenPlus
        }
    }
}

public struct OnboardingAnalyticsModelMetadata: Equatable, Sendable {
    public let engine: OnboardingAnalyticsModelEngine
    public let sizeBucket: OnboardingAnalyticsModelSizeBucket

    public init(engine: OnboardingAnalyticsModelEngine, sizeBucket: OnboardingAnalyticsModelSizeBucket) {
        self.engine = engine
        self.sizeBucket = sizeBucket
    }

    public init(model: WhisperModelInfo) {
        self.engine = OnboardingAnalyticsModelEngine(model.engine)
        self.sizeBucket = OnboardingAnalyticsModelSizeBucket(model: model)
    }
}

public extension OnboardingAnalyticsModelEngine {
    init(_ engine: ModelEngine) {
        if engine.isParakeet {
            self = .parakeet
        } else {
            self = .whisper
        }
    }
}

public extension OnboardingAnalyticsModelSizeBucket {
    init(model: WhisperModelInfo) {
        if model.isBundled {
            self = .bundled
            return
        }

        self = Self.bucket(fromSizeLabel: model.sizeLabel)
    }

    static func bucket(fromSizeLabel sizeLabel: String) -> OnboardingAnalyticsModelSizeBucket {
        let normalized = sizeLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "~", with: "")

        let scanner = Scanner(string: normalized)
        guard let value = scanner.scanDouble() else { return .unknown }

        if normalized.contains("gb") {
            return value >= 1 ? .oneGBPlus : .fiveHundredMBTo1GB
        }

        if normalized.contains("mb") {
            switch value {
            case 0..<100:
                return .under100MB
            case 100..<500:
                return .oneHundredTo500MB
            case 500..<1000:
                return .fiveHundredMBTo1GB
            default:
                return .oneGBPlus
            }
        }

        return .unknown
    }
}

public extension OnboardingAnalyticsFileExportFormat {
    init(_ format: ExportFileFormat) {
        switch format {
        case .txt:
            self = .txt
        case .md:
            self = .md
        case .json:
            self = .json
        case .yaml:
            self = .yaml
        }
    }
}

public extension OnboardingAnalyticsFileExportMode {
    init(_ mode: ExportFileMode) {
        switch mode {
        case .append:
            self = .append
        case .newFile:
            self = .newFile
        }
    }
}

public extension UsageTracker {
    var onboardingAnalyticsQuotaState: OnboardingAnalyticsQuotaState {
        OnboardingAnalyticsQuotaState(
            totalSecondsUsed: totalSecondsUsed,
            freeLimitSeconds: Self.freeMinutesLimit * 60.0,
            successfulCapturesUsed: successfulCapturesUsed,
            freeCaptureLimit: Self.freeCaptureLimit,
            hasUnlocked: hasUnlocked
        )
    }
}

public extension OnboardingAnalyticsClient {
    func trackOnboardingStarted(
        step: OnboardingAnalyticsStep = .welcome,
        quotaState: OnboardingAnalyticsQuotaState? = nil
    ) {
        track(OnboardingAnalyticsEvent(
            name: .onboardingStarted,
            properties: properties(
                onboardingStep: step,
                quotaState: quotaState
            )
        ))
    }

    func trackOnboardingStepViewed(
        _ step: OnboardingAnalyticsStep,
        quotaState: OnboardingAnalyticsQuotaState? = nil
    ) {
        track(OnboardingAnalyticsEvent(
            name: .onboardingStepViewed,
            properties: properties(
                onboardingStep: step,
                quotaState: quotaState
            )
        ))
    }

    func trackMicrophonePermissionCompleted(
        status: OnboardingAnalyticsPermissionStatus,
        quotaState: OnboardingAnalyticsQuotaState? = nil
    ) {
        track(OnboardingAnalyticsEvent(
            name: .microphonePermissionCompleted,
            properties: properties(
                onboardingStep: .microphoneAccess,
                permissionStatus: status,
                quotaState: quotaState,
                errorCategory: status == .granted ? nil : .microphoneDenied
            )
        ))
    }

    func trackModelSetupCompleted(
        metadata: OnboardingAnalyticsModelMetadata,
        quotaState: OnboardingAnalyticsQuotaState? = nil
    ) {
        track(OnboardingAnalyticsEvent(
            name: .modelSetupCompleted,
            properties: properties(
                onboardingStep: .modelSetup,
                modelMetadata: metadata,
                quotaState: quotaState
            )
        ))
    }

    func trackKeyboardSetupStarted(quotaState: OnboardingAnalyticsQuotaState? = nil) {
        track(OnboardingAnalyticsEvent(
            name: .keyboardSetupStarted,
            properties: properties(
                onboardingStep: .keyboardEnablement,
                quotaState: quotaState
            )
        ))
    }

    func trackKeyboardSetupCompleted(quotaState: OnboardingAnalyticsQuotaState? = nil) {
        track(OnboardingAnalyticsEvent(
            name: .keyboardSetupCompleted,
            properties: properties(
                onboardingStep: .keyboardEnablement,
                quotaState: quotaState
            )
        ))
    }

    func trackFileExportSetupCompleted(
        format: OnboardingAnalyticsFileExportFormat,
        mode: OnboardingAnalyticsFileExportMode,
        quotaState: OnboardingAnalyticsQuotaState? = nil
    ) {
        track(OnboardingAnalyticsEvent(
            name: .fileExportSetupCompleted,
            properties: properties(
                onboardingStep: .fileExport,
                fileExportFormat: format,
                fileExportMode: mode,
                quotaState: quotaState
            )
        ))
    }

    func trackPaywallShown(
        context: OnboardingAnalyticsPaywallContext,
        quotaState: OnboardingAnalyticsQuotaState? = nil
    ) {
        track(OnboardingAnalyticsEvent(
            name: .paywallShown,
            properties: properties(
                onboardingStep: context == .onboarding ? .unlock : nil,
                quotaState: quotaState,
                paywallContext: context
            )
        ))
    }

    func trackPurchaseStarted(
        context: OnboardingAnalyticsPaywallContext,
        productId: OnboardingAnalyticsProductID = .lifetimeUnlock,
        quotaState: OnboardingAnalyticsQuotaState? = nil
    ) {
        track(OnboardingAnalyticsEvent(
            name: .purchaseStarted,
            properties: properties(
                onboardingStep: context == .onboarding ? .unlock : nil,
                quotaState: quotaState,
                paywallContext: context,
                productId: productId,
                purchaseOutcome: .started
            )
        ))
    }

    func trackPurchaseFinished(
        outcome: OnboardingAnalyticsPurchaseOutcome,
        context: OnboardingAnalyticsPaywallContext,
        errorCategory: OnboardingAnalyticsErrorCategory? = nil,
        productId: OnboardingAnalyticsProductID = .lifetimeUnlock,
        quotaState: OnboardingAnalyticsQuotaState? = nil
    ) {
        track(OnboardingAnalyticsEvent(
            name: .purchaseFinished,
            properties: properties(
                onboardingStep: context == .onboarding ? .unlock : nil,
                quotaState: quotaState,
                paywallContext: context,
                productId: productId,
                purchaseOutcome: outcome,
                errorCategory: errorCategory
            )
        ))
    }

    func trackRestoreStarted(
        context: OnboardingAnalyticsPaywallContext = .restore,
        productId: OnboardingAnalyticsProductID = .lifetimeUnlock,
        quotaState: OnboardingAnalyticsQuotaState? = nil
    ) {
        track(OnboardingAnalyticsEvent(
            name: .restoreStarted,
            properties: properties(
                quotaState: quotaState,
                paywallContext: context,
                productId: productId,
                purchaseOutcome: .started
            )
        ))
    }

    func trackRestoreFinished(
        outcome: OnboardingAnalyticsPurchaseOutcome,
        context: OnboardingAnalyticsPaywallContext = .restore,
        errorCategory: OnboardingAnalyticsErrorCategory? = nil,
        productId: OnboardingAnalyticsProductID = .lifetimeUnlock,
        quotaState: OnboardingAnalyticsQuotaState? = nil
    ) {
        track(OnboardingAnalyticsEvent(
            name: .restoreFinished,
            properties: properties(
                quotaState: quotaState,
                paywallContext: context,
                productId: productId,
                purchaseOutcome: outcome,
                errorCategory: errorCategory
            )
        ))
    }

    func trackOnboardingCompleted(
        modelMetadata: OnboardingAnalyticsModelMetadata? = nil,
        quotaState: OnboardingAnalyticsQuotaState? = nil
    ) {
        track(OnboardingAnalyticsEvent(
            name: .onboardingCompleted,
            properties: properties(
                onboardingStep: .ready,
                modelMetadata: modelMetadata,
                quotaState: quotaState
            )
        ))
    }

    private func properties(
        onboardingStep: OnboardingAnalyticsStep? = nil,
        permissionStatus: OnboardingAnalyticsPermissionStatus? = nil,
        modelMetadata: OnboardingAnalyticsModelMetadata? = nil,
        fileExportFormat: OnboardingAnalyticsFileExportFormat? = nil,
        fileExportMode: OnboardingAnalyticsFileExportMode? = nil,
        quotaState: OnboardingAnalyticsQuotaState? = nil,
        paywallContext: OnboardingAnalyticsPaywallContext? = nil,
        productId: OnboardingAnalyticsProductID? = nil,
        purchaseOutcome: OnboardingAnalyticsPurchaseOutcome? = nil,
        errorCategory: OnboardingAnalyticsErrorCategory? = nil
    ) -> OnboardingAnalyticsProperties {
        OnboardingAnalyticsProperties(
            onboardingStep: onboardingStep,
            permissionStatus: permissionStatus,
            modelEngine: modelMetadata?.engine,
            modelSizeBucket: modelMetadata?.sizeBucket,
            fileExportFormat: fileExportFormat,
            fileExportMode: fileExportMode,
            freeMinutesUsedBucket: quotaState?.freeMinutesUsedBucket,
            freeMinutesRemainingBucket: quotaState?.freeMinutesRemainingBucket,
            freeCapturesUsedBucket: quotaState?.freeCapturesUsedBucket,
            freeCapturesRemainingBucket: quotaState?.freeCapturesRemainingBucket,
            paywallContext: paywallContext,
            productId: productId,
            purchaseOutcome: purchaseOutcome,
            errorCategory: errorCategory
        )
    }
}
