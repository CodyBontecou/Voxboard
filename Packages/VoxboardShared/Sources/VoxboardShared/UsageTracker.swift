import Foundation

/// Tracks cumulative transcription usage and purchase unlock state.
/// Persisted in the shared App Group UserDefaults so both the main app
/// and the keyboard extension can read it.
@Observable
public final class UsageTracker {

    // MARK: - Constants

    public static let freeMinutesLimit: Double = 15.0
    private static let usageSecondsKey = "totalTranscriptionSeconds"
    private static let hasUnlockedKey  = "hasUnlocked"

    // MARK: - Observable State

    public var totalSecondsUsed: Double = 0
    public var hasUnlocked: Bool = false

    // MARK: - Derived

    public var minutesUsed: Double { totalSecondsUsed / 60.0 }
    public var secondsRemaining: Double { max(0, Self.freeMinutesLimit * 60 - totalSecondsUsed) }
    public var minutesRemaining: Double { secondsRemaining / 60.0 }

    /// True when the free tier is exhausted and the user hasn't purchased.
    public var isAtLimit: Bool {
        !hasUnlocked && totalSecondsUsed >= Self.freeMinutesLimit * 60
    }

    /// 0…1 fraction of free tier consumed.
    public var fractionUsed: Double {
        min(1.0, totalSecondsUsed / (Self.freeMinutesLimit * 60))
    }

    // MARK: - Init

    public init() {
        reload()
    }

    // MARK: - Mutation

    /// Add `seconds` to the cumulative counter. Call after every successful transcription.
    public func addUsage(seconds: Double) {
        totalSecondsUsed += seconds
        persist()
    }

    /// Mark the premium tier as purchased. Call after a verified StoreKit transaction.
    public func unlock() {
        hasUnlocked = true
        persist()
    }

    /// Re-read values from disk (call when the app becomes active to pick up any
    /// changes written by the keyboard extension).
    public func reload() {
        totalSecondsUsed = AppConstants.sharedDefaults?.double(forKey: Self.usageSecondsKey) ?? 0
        hasUnlocked      = AppConstants.sharedDefaults?.bool(forKey: Self.hasUnlockedKey) ?? false
    }

    // MARK: - Fast static check (no @Observable overhead)

    /// Cheap check suitable for use in the keyboard extension without creating a
    /// full `UsageTracker` instance.
    public static var staticIsAtLimit: Bool {
        guard !(AppConstants.sharedDefaults?.bool(forKey: hasUnlockedKey) ?? false) else {
            return false
        }
        let seconds = AppConstants.sharedDefaults?.double(forKey: usageSecondsKey) ?? 0
        return seconds >= freeMinutesLimit * 60
    }

    // MARK: - Private

    private func persist() {
        AppConstants.sharedDefaults?.set(totalSecondsUsed, forKey: Self.usageSecondsKey)
        AppConstants.sharedDefaults?.set(hasUnlocked,      forKey: Self.hasUnlockedKey)
    }
}
