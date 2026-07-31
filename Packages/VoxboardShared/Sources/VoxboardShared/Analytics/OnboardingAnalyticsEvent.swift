import Foundation

/// Privacy-safe event model for Voxboard onboarding analytics.
///
/// Privacy contract:
/// - Allowed: experiment/variant IDs, app version/build, platform, coarse
///   onboarding step, coarse permission/model/export/paywall/purchase state, and
///   coarse free-tier usage buckets.
/// - Prohibited: audio, recordings, transcript text, dictated text, keystrokes,
///   file/folder paths, custom template text, model file paths, user-entered
///   names, email addresses, raw timestamps/dates, device names, IP addresses,
///   and user-agent strings.
///
/// Keep this model transport-agnostic. Sinks should consume `encodedPayload()`
/// and must not add keys outside `OnboardingAnalyticsPropertyKey`.
public struct OnboardingAnalyticsEvent: Equatable, Sendable {
    public let name: OnboardingAnalyticsEventName
    public let properties: OnboardingAnalyticsProperties

    public init(
        name: OnboardingAnalyticsEventName,
        properties: OnboardingAnalyticsProperties = OnboardingAnalyticsProperties()
    ) {
        self.name = name
        self.properties = properties
    }

    public func encodedPayload() -> OnboardingAnalyticsPayload {
        OnboardingAnalyticsPayload(
            eventName: name.rawValue,
            properties: properties.encodedProperties()
        )
    }

    func encodedPayload(
        including assignment: OnboardingExperimentAssignment,
        runtimeContext: OnboardingAnalyticsRuntimeContext?
    ) -> OnboardingAnalyticsPayload {
        var encodedProperties = properties.encodedProperties()

        if encodedProperties[.experimentId] == nil {
            encodedProperties[.experimentId] = .string(assignment.experimentId)
        }
        if encodedProperties[.variantId] == nil {
            encodedProperties[.variantId] = .string(assignment.variantId)
        }

        if let runtimeContext {
            let contextProperties = OnboardingAnalyticsProperties(
                appVersion: runtimeContext.appVersion,
                buildNumber: runtimeContext.buildNumber,
                platform: runtimeContext.platform
            ).encodedProperties()

            for (key, value) in contextProperties where encodedProperties[key] == nil {
                encodedProperties[key] = value
            }
        }

        return OnboardingAnalyticsPayload(
            eventName: name.rawValue,
            properties: encodedProperties
        )
    }
}

public enum OnboardingAnalyticsEventName: String, CaseIterable, Sendable {
    case onboardingStarted = "onboarding_started"
    case onboardingStepViewed = "onboarding_step_viewed"
    case microphonePermissionCompleted = "onboarding_microphone_permission_completed"
    case modelSetupCompleted = "onboarding_model_setup_completed"
    case keyboardSetupStarted = "onboarding_keyboard_setup_started"
    case keyboardSetupCompleted = "onboarding_keyboard_setup_completed"
    case fileExportSetupCompleted = "onboarding_file_export_setup_completed"
    case paywallShown = "onboarding_paywall_shown"
    case purchaseStarted = "onboarding_purchase_started"
    case purchaseFinished = "onboarding_purchase_finished"
    case restoreStarted = "onboarding_restore_started"
    case restoreFinished = "onboarding_restore_finished"
    case onboardingCompleted = "onboarding_completed"
}

public struct OnboardingAnalyticsPayload: Equatable, Sendable, Codable {
    public let eventId: String?
    public let eventName: String
    public let properties: [OnboardingAnalyticsPropertyKey: OnboardingAnalyticsValue]

    public var transportProperties: [String: OnboardingAnalyticsValue] {
        Dictionary(uniqueKeysWithValues: properties.map { ($0.key.rawValue, $0.value) })
    }

    private enum CodingKeys: String, CodingKey {
        case eventId
        case eventName
        case properties
    }

    public init(
        eventId: String? = nil,
        eventName: String,
        properties: [OnboardingAnalyticsPropertyKey: OnboardingAnalyticsValue]
    ) {
        self.eventId = eventId
        self.eventName = eventName
        self.properties = properties
    }

    public func withEventId(_ eventId: String) -> OnboardingAnalyticsPayload {
        OnboardingAnalyticsPayload(
            eventId: eventId,
            eventName: eventName,
            properties: properties
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let eventId = try container.decodeIfPresent(String.self, forKey: .eventId)
        let eventName = try container.decode(String.self, forKey: .eventName)
        let transportProperties = try container.decode(
            [String: OnboardingAnalyticsValue].self,
            forKey: .properties
        )

        self.eventId = eventId
        self.eventName = eventName
        self.properties = Dictionary(
            uniqueKeysWithValues: transportProperties.compactMap { key, value in
                guard let propertyKey = OnboardingAnalyticsPropertyKey(rawValue: key) else { return nil }
                return (propertyKey, value)
            }
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(eventId, forKey: .eventId)
        try container.encode(eventName, forKey: .eventName)
        try container.encode(transportProperties, forKey: .properties)
    }
}

public enum OnboardingAnalyticsPropertyKey: String, CaseIterable, Sendable {
    case experimentId
    case variantId
    case appVersion
    case buildNumber
    case platform
    case onboardingStep
    case permissionStatus
    case modelEngine
    case modelSizeBucket
    case fileExportFormat
    case fileExportMode
    case freeMinutesUsedBucket
    case freeMinutesRemainingBucket
    case freeCapturesUsedBucket
    case freeCapturesRemainingBucket
    case paywallContext
    case productId
    case purchaseOutcome
    case errorCategory
}

public enum OnboardingAnalyticsValue: Equatable, Sendable, Codable {
    case string(String)
    case int(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
            return
        }

        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }

        throw DecodingError.typeMismatch(
            OnboardingAnalyticsValue.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected onboarding analytics value to be a string or integer."
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        }
    }
}

public struct OnboardingAnalyticsProperties: Equatable, Sendable {
    private let experimentId: String?
    private let variantId: String?
    private let appVersion: String?
    private let buildNumber: String?
    private let platform: OnboardingAnalyticsPlatform?
    private let onboardingStep: OnboardingAnalyticsStep?
    private let permissionStatus: OnboardingAnalyticsPermissionStatus?
    private let modelEngine: OnboardingAnalyticsModelEngine?
    private let modelSizeBucket: OnboardingAnalyticsModelSizeBucket?
    private let fileExportFormat: OnboardingAnalyticsFileExportFormat?
    private let fileExportMode: OnboardingAnalyticsFileExportMode?
    private let freeMinutesUsedBucket: OnboardingAnalyticsUsageBucket?
    private let freeMinutesRemainingBucket: OnboardingAnalyticsUsageBucket?
    private let freeCapturesUsedBucket: OnboardingAnalyticsCaptureUsageBucket?
    private let freeCapturesRemainingBucket: OnboardingAnalyticsCaptureUsageBucket?
    private let paywallContext: OnboardingAnalyticsPaywallContext?
    private let productId: OnboardingAnalyticsProductID?
    private let purchaseOutcome: OnboardingAnalyticsPurchaseOutcome?
    private let errorCategory: OnboardingAnalyticsErrorCategory?

    public init(
        experimentId: String? = nil,
        variantId: String? = nil,
        appVersion: String? = nil,
        buildNumber: String? = nil,
        platform: OnboardingAnalyticsPlatform? = nil,
        onboardingStep: OnboardingAnalyticsStep? = nil,
        permissionStatus: OnboardingAnalyticsPermissionStatus? = nil,
        modelEngine: OnboardingAnalyticsModelEngine? = nil,
        modelSizeBucket: OnboardingAnalyticsModelSizeBucket? = nil,
        fileExportFormat: OnboardingAnalyticsFileExportFormat? = nil,
        fileExportMode: OnboardingAnalyticsFileExportMode? = nil,
        freeMinutesUsedBucket: OnboardingAnalyticsUsageBucket? = nil,
        freeMinutesRemainingBucket: OnboardingAnalyticsUsageBucket? = nil,
        freeCapturesUsedBucket: OnboardingAnalyticsCaptureUsageBucket? = nil,
        freeCapturesRemainingBucket: OnboardingAnalyticsCaptureUsageBucket? = nil,
        paywallContext: OnboardingAnalyticsPaywallContext? = nil,
        productId: OnboardingAnalyticsProductID? = nil,
        purchaseOutcome: OnboardingAnalyticsPurchaseOutcome? = nil,
        errorCategory: OnboardingAnalyticsErrorCategory? = nil
    ) {
        self.experimentId = OnboardingAnalyticsSanitizer.sanitizedIdentifier(experimentId)
        self.variantId = OnboardingAnalyticsSanitizer.sanitizedIdentifier(variantId)
        self.appVersion = OnboardingAnalyticsSanitizer.sanitizedAppVersion(appVersion)
        self.buildNumber = OnboardingAnalyticsSanitizer.sanitizedBuildNumber(buildNumber)
        self.platform = platform
        self.onboardingStep = onboardingStep
        self.permissionStatus = permissionStatus
        self.modelEngine = modelEngine
        self.modelSizeBucket = modelSizeBucket
        self.fileExportFormat = fileExportFormat
        self.fileExportMode = fileExportMode
        self.freeMinutesUsedBucket = freeMinutesUsedBucket
        self.freeMinutesRemainingBucket = freeMinutesRemainingBucket
        self.freeCapturesUsedBucket = freeCapturesUsedBucket
        self.freeCapturesRemainingBucket = freeCapturesRemainingBucket
        self.paywallContext = paywallContext
        self.productId = productId
        self.purchaseOutcome = purchaseOutcome
        self.errorCategory = errorCategory
    }

    public func encodedProperties() -> [OnboardingAnalyticsPropertyKey: OnboardingAnalyticsValue] {
        var encoded: [OnboardingAnalyticsPropertyKey: OnboardingAnalyticsValue] = [:]

        encode(experimentId, for: .experimentId, into: &encoded)
        encode(variantId, for: .variantId, into: &encoded)
        encode(appVersion, for: .appVersion, into: &encoded)
        encode(buildNumber, for: .buildNumber, into: &encoded)
        encode(platform?.rawValue, for: .platform, into: &encoded)
        encode(onboardingStep?.rawValue, for: .onboardingStep, into: &encoded)
        encode(permissionStatus?.rawValue, for: .permissionStatus, into: &encoded)
        encode(modelEngine?.rawValue, for: .modelEngine, into: &encoded)
        encode(modelSizeBucket?.rawValue, for: .modelSizeBucket, into: &encoded)
        encode(fileExportFormat?.rawValue, for: .fileExportFormat, into: &encoded)
        encode(fileExportMode?.rawValue, for: .fileExportMode, into: &encoded)
        encode(freeMinutesUsedBucket?.rawValue, for: .freeMinutesUsedBucket, into: &encoded)
        encode(freeMinutesRemainingBucket?.rawValue, for: .freeMinutesRemainingBucket, into: &encoded)
        encode(freeCapturesUsedBucket?.rawValue, for: .freeCapturesUsedBucket, into: &encoded)
        encode(freeCapturesRemainingBucket?.rawValue, for: .freeCapturesRemainingBucket, into: &encoded)
        encode(paywallContext?.rawValue, for: .paywallContext, into: &encoded)
        encode(productId?.rawValue, for: .productId, into: &encoded)
        encode(purchaseOutcome?.rawValue, for: .purchaseOutcome, into: &encoded)
        encode(errorCategory?.rawValue, for: .errorCategory, into: &encoded)

        return encoded
    }

    private func encode(
        _ value: String?,
        for key: OnboardingAnalyticsPropertyKey,
        into encoded: inout [OnboardingAnalyticsPropertyKey: OnboardingAnalyticsValue]
    ) {
        guard let value else { return }
        encoded[key] = .string(value)
    }
}

public enum OnboardingAnalyticsPlatform: String, CaseIterable, Sendable {
    case iOS = "ios"
    case macOS = "macos"
}

public enum OnboardingAnalyticsStep: String, CaseIterable, Sendable {
    case welcome
    case microphoneAccess = "microphone_access"
    case modelSetup = "model_setup"
    case keyboardEnablement = "keyboard_enablement"
    case fileExport = "file_export"
    case unlock
    case ready
}

public enum OnboardingAnalyticsPermissionStatus: String, CaseIterable, Sendable {
    case granted
    case denied
    case restricted
    case unavailable
    case unknown
}

public enum OnboardingAnalyticsModelEngine: String, CaseIterable, Sendable {
    case whisper
    case parakeet
    case appleSpeech = "apple_speech"
    case unknown
}

public enum OnboardingAnalyticsModelSizeBucket: String, CaseIterable, Sendable {
    case bundled
    case under100MB = "under_100_mb"
    case oneHundredTo500MB = "100_500_mb"
    case fiveHundredMBTo1GB = "500_mb_1_gb"
    case oneGBPlus = "1_gb_plus"
    case unknown
}

public enum OnboardingAnalyticsFileExportFormat: String, CaseIterable, Sendable {
    case txt
    case md
    case json
    case yaml
    case disabled
    case unknown
}

public enum OnboardingAnalyticsFileExportMode: String, CaseIterable, Sendable {
    case append
    case newFile = "new_file"
    case disabled
    case unknown
}

public enum OnboardingAnalyticsUsageBucket: String, CaseIterable, Sendable {
    case zero = "0"
    case underFiveMinutes = "0_5_min"
    case fiveToFifteenMinutes = "5_15_min"
    case fifteenPlusMinutes = "15_plus_min"
    case unlimited
    case unknown
}

public enum OnboardingAnalyticsCaptureUsageBucket: String, CaseIterable, Sendable {
    case zero = "0"
    case oneToThree = "1_3"
    case fourToSeven = "4_7"
    case eightToNine = "8_9"
    case tenPlus = "10_plus"
    case unlimited
    case unknown
}

public enum OnboardingAnalyticsPaywallContext: String, CaseIterable, Sendable {
    case onboarding
    case usageMeter = "usage_meter"
    case limit
    case recording
    case captureLimit = "capture_limit"
    case keyboard
    case widget
    case settings
    case restore
    case unknown
}

public enum OnboardingAnalyticsProductID: String, CaseIterable, Sendable {
    case lifetimeUnlock = "bontecou.Voxboard.unlock"
    case familyUnlock = "bontecou.Voxboard.family"
    case familyUpgrade = "bontecou.Voxboard.familyUpgrade"

    public init(_ product: VoxboardPurchaseProduct) {
        switch product {
        case .individual: self = .lifetimeUnlock
        case .family: self = .familyUnlock
        case .familyUpgrade: self = .familyUpgrade
        }
    }
}

public enum OnboardingAnalyticsPurchaseOutcome: String, CaseIterable, Sendable {
    case started
    case succeeded
    case failed
    case cancelled
    case pending
}

public enum OnboardingAnalyticsErrorCategory: String, CaseIterable, Sendable {
    case networkUnavailable = "network_unavailable"
    case storeUnavailable = "store_unavailable"
    case userCancelled = "user_cancelled"
    case paymentNotAllowed = "payment_not_allowed"
    case verificationFailed = "verification_failed"
    case configurationUnavailable = "configuration_unavailable"
    case noModel = "no_model"
    case microphoneDenied = "microphone_denied"
    case notUnlocked = "not_unlocked"
    case unknown
}

private enum OnboardingAnalyticsSanitizer {
    private static let identifierCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-"
    )
    private static let digitCharacters = CharacterSet(charactersIn: "0123456789")
    private static let versionCharacters = CharacterSet(charactersIn: "0123456789.")
    private static let sensitiveTokens = [
        "audio",
        "recording",
        "transcript",
        "transcription",
        "speech",
        "voice",
        "dictation",
        "keystroke",
        "keyboard_text",
        "folder",
        "file",
        "path",
        "template",
        "documents",
        "desktop",
        "downloads",
        "icloud",
        "email",
        "name",
        "user"
    ]

    static func sanitizedIdentifier(_ rawValue: String?) -> String? {
        guard let value = trimmed(rawValue), value.count <= 80 else { return nil }
        guard value == value.lowercased() else { return nil }
        guard containsOnly(value, characters: identifierCharacters) else { return nil }
        guard !containsRawDate(value) else { return nil }
        guard !containsSensitiveToken(value) else { return nil }
        return value
    }

    static func sanitizedAppVersion(_ rawValue: String?) -> String? {
        guard let value = trimmed(rawValue), value.count <= 20 else { return nil }
        guard containsOnly(value, characters: versionCharacters) else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return value
    }

    static func sanitizedBuildNumber(_ rawValue: String?) -> String? {
        guard let value = trimmed(rawValue), (1...12).contains(value.count) else { return nil }
        guard containsOnly(value, characters: digitCharacters) else { return nil }
        return value
    }

    private static func trimmed(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func containsOnly(_ value: String, characters: CharacterSet) -> Bool {
        value.unicodeScalars.allSatisfy { characters.contains($0) }
    }

    private static func containsRawDate(_ value: String) -> Bool {
        let datePatterns = [
            #"(?:^|[^0-9])(?:19|20)\d{2}[-_.](?:0[1-9]|1[0-2])[-_.](?:0[1-9]|[12]\d|3[01])(?:$|[^0-9])"#,
            #"(?:^|[^0-9])(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])(?:$|[^0-9])"#
        ]

        return datePatterns.contains { pattern in
            value.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func containsSensitiveToken(_ value: String) -> Bool {
        let normalized = value
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()

        return sensitiveTokens.contains { normalized.contains($0) }
    }
}
