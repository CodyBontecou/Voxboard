import Foundation
import StoreKit
import UIKit
import VoxboardShared

/// Tracks App Store review prompt eligibility and asks only after a real value moment.
///
/// Policy:
/// - at least 5 successful transcriptions
/// - app usage on at least 2 separate local calendar days
/// - no prompt attempt in the last 90 days
@MainActor
final class ReviewPromptManager {
    static let shared = ReviewPromptManager()

    private enum Keys {
        static let successfulTranscriptionCount = "reviewPrompt.successfulTranscriptionCount.v1"
        static let usageDayIdentifiers = "reviewPrompt.usageDayIdentifiers.v1"
        static let lastPromptAttemptAt = "reviewPrompt.lastPromptAttemptAt.v1"
        static let pendingPrompt = "reviewPrompt.pendingPrompt.v1"
    }

    private let defaults: UserDefaults
    private let calendar: Calendar
    private let now: () -> Date
    private var promptTask: Task<Void, Never>?

    private let transcriptionThreshold = 5
    private let dayThreshold = 2
    private let recentPromptInterval: TimeInterval = 60 * 60 * 24 * 90
    private let promptDelayNanoseconds: UInt64 = 900_000_000

    init(
        defaults: UserDefaults = AppConstants.sharedDefaults ?? .standard,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
    }

    /// Call when the app foregrounds so the two-day guard reflects general app usage,
    /// not only days where a transcription was completed.
    func recordAppUsageDay() {
        recordUsageDays([now()])
    }

    /// Call after a successful transcription has been saved to history.
    func recordSuccessfulTranscription(totalTranscriptionCount: Int, transcriptDates: [Date]) {
        let currentCount = defaults.integer(forKey: Keys.successfulTranscriptionCount)
        defaults.set(max(currentCount + 1, totalTranscriptionCount), forKey: Keys.successfulTranscriptionCount)

        recordUsageDays(transcriptDates + [now()])
        requestIfEligible()
    }

    /// Attempts a previously queued review prompt, for example when the app returns foreground.
    func requestPendingPromptIfPossible() {
        guard defaults.bool(forKey: Keys.pendingPrompt) else { return }
        requestIfEligible()
    }

    private func requestIfEligible() {
        guard isEligible else { return }
        defaults.set(true, forKey: Keys.pendingPrompt)
        schedulePromptIfForeground()
    }

    private var isEligible: Bool {
        defaults.integer(forKey: Keys.successfulTranscriptionCount) >= transcriptionThreshold
            && usageDayCount >= dayThreshold
            && !hasPromptedRecently
    }

    private var usageDayCount: Int {
        Set(defaults.stringArray(forKey: Keys.usageDayIdentifiers) ?? []).count
    }

    private var hasPromptedRecently: Bool {
        let lastPromptTime = defaults.double(forKey: Keys.lastPromptAttemptAt)
        guard lastPromptTime > 0 else { return false }
        return now().timeIntervalSince1970 - lastPromptTime < recentPromptInterval
    }

    private func recordUsageDays(_ dates: [Date]) {
        var days = Set(defaults.stringArray(forKey: Keys.usageDayIdentifiers) ?? [])
        for date in dates {
            days.insert(dayIdentifier(for: date))
        }
        defaults.set(Array(days).sorted(), forKey: Keys.usageDayIdentifiers)
    }

    private func dayIdentifier(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return [components.year, components.month, components.day]
            .map { String($0 ?? 0) }
            .joined(separator: "-")
    }

    private func schedulePromptIfForeground() {
        guard promptTask == nil, activeWindowScene != nil else { return }

        promptTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.promptDelayNanoseconds ?? 0)
            guard !Task.isCancelled else { return }
            self?.requestPromptNowIfPossible()
        }
    }

    private func requestPromptNowIfPossible() {
        promptTask = nil

        guard defaults.bool(forKey: Keys.pendingPrompt), isEligible else { return }
        guard let scene = activeWindowScene else { return }

        SKStoreReviewController.requestReview(in: scene)
        defaults.set(now().timeIntervalSince1970, forKey: Keys.lastPromptAttemptAt)
        defaults.set(false, forKey: Keys.pendingPrompt)
    }

    private var activeWindowScene: UIWindowScene? {
        let foregroundScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }

        return foregroundScenes.first { scene in
            scene.windows.contains { $0.isKeyWindow }
        } ?? foregroundScenes.first
    }
}
