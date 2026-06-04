import Foundation

/// Minimal UserDefaults seam used by the analytics queue and sticky assignment.
public protocol OnboardingAnalyticsUserDefaultsStoring: Sendable {
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

/// Production UserDefaults adapter.
public final class SystemOnboardingAnalyticsUserDefaults: OnboardingAnalyticsUserDefaultsStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func bool(forKey key: String) -> Bool {
        defaults.bool(forKey: key)
    }

    public func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    public func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

public struct OnboardingExperimentConfig: Equatable, Sendable {
    public static let currentExperimentId = "voxboard_onboarding_activation"
    public static let baselineVariantId = "baseline_v1"

    public static let baseline = OnboardingExperimentConfig(
        validatedExperimentId: currentExperimentId,
        variantId: baselineVariantId
    )

    public let experimentId: String
    public let variantId: String

    public init?(experimentId: String, variantId: String) {
        guard Self.knownExperimentIds.contains(experimentId),
              Self.knownVariantIds.contains(variantId),
              OnboardingExperimentIdentifierValidator.isSafeIdentifier(experimentId),
              OnboardingExperimentIdentifierValidator.isSafeIdentifier(variantId) else {
            return nil
        }

        self.init(validatedExperimentId: experimentId, variantId: variantId)
    }

    public static func resolved(
        from data: Data?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> OnboardingExperimentConfig {
        #if DEBUG
        if environment["UITEST_REMOTE_CONFIG"] == "offline" {
            return .baseline
        }
        #endif

        guard let data else { return .baseline }

        let decoder = JSONDecoder()
        guard let rawConfig = try? decoder.decode(RawOnboardingExperimentConfig.self, from: data),
              let experimentId = rawConfig.experimentId,
              let variantId = rawConfig.variantId,
              let config = OnboardingExperimentConfig(
                experimentId: experimentId,
                variantId: variantId
              ) else {
            return .baseline
        }

        return config
    }

    private init(validatedExperimentId experimentId: String, variantId: String) {
        self.experimentId = experimentId
        self.variantId = variantId
    }

    private static let knownExperimentIds: Set<String> = [
        currentExperimentId,
    ]

    private static let knownVariantIds: Set<String> = [
        baselineVariantId,
    ]
}

public struct OnboardingExperimentAssignment: Codable, Equatable, Sendable {
    public let experimentId: String
    public let variantId: String
    public let assignedAt: Date

    public init(experimentId: String, variantId: String, assignedAt: Date) {
        self.experimentId = experimentId
        self.variantId = variantId
        self.assignedAt = assignedAt
    }
}

public final class OnboardingExperimentAssignmentStore: @unchecked Sendable {
    public static let defaultKey = "onboarding.experiment.assignment.v1"

    private let defaults: OnboardingAnalyticsUserDefaultsStoring
    private let key: String
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "com.bontecou.voxboard.onboarding-experiment-assignment")

    public init(
        defaults: OnboardingAnalyticsUserDefaultsStoring = SystemOnboardingAnalyticsUserDefaults(
            defaults: AppConstants.sharedDefaults ?? .standard
        ),
        key: String = OnboardingExperimentAssignmentStore.defaultKey,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.key = key
        self.now = now
    }

    public func assignment(for config: OnboardingExperimentConfig = .baseline) -> OnboardingExperimentAssignment {
        queue.sync {
            if let persistedAssignment = loadAssignment(),
               isValid(persistedAssignment, for: config) {
                return persistedAssignment
            }

            let assignment = OnboardingExperimentAssignment(
                experimentId: config.experimentId,
                variantId: config.variantId,
                assignedAt: now()
            )
            save(assignment)
            return assignment
        }
    }

    private func loadAssignment() -> OnboardingExperimentAssignment? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(OnboardingExperimentAssignment.self, from: data)
    }

    private func save(_ assignment: OnboardingExperimentAssignment) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        guard let data = try? encoder.encode(assignment) else { return }
        defaults.set(data, forKey: key)
    }

    private func isValid(
        _ assignment: OnboardingExperimentAssignment,
        for config: OnboardingExperimentConfig
    ) -> Bool {
        guard assignment.experimentId == config.experimentId else { return false }
        return OnboardingExperimentConfig(
            experimentId: assignment.experimentId,
            variantId: assignment.variantId
        ) != nil
    }
}

private struct RawOnboardingExperimentConfig: Decodable {
    let experimentId: String?
    let variantId: String?
}

private enum OnboardingExperimentIdentifierValidator {
    private static let identifierCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-"
    )
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
        "user",
    ]

    static func isSafeIdentifier(_ rawValue: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == rawValue,
              !value.isEmpty,
              value.count <= 80,
              value == value.lowercased(),
              value.unicodeScalars.allSatisfy({ identifierCharacters.contains($0) }),
              !containsRawDate(value),
              !containsSensitiveToken(value) else {
            return false
        }

        return true
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
