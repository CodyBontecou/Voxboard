import Foundation

/// Tracks the independent free transcription and successful-Capture meters,
/// plus the shared lifetime purchase state. Transcription and UI mirrors live
/// in App Group defaults; authoritative Capture accounting is coordinated by
/// `CaptureDeliveryUsageStore` and backed by a Keychain high-water mark.
@Observable
public final class UsageTracker {

    // MARK: - Constants

    public static let freeMinutesLimit: Double = 15.0
    public static let freeCaptureLimit: Int = 10
    private static let usageSecondsKey = "totalTranscriptionSeconds"
    static let hasUnlockedKey = "hasUnlocked"
    static let accessLevelKey = "unlimitedAccessLevelV1"
    private static let permanentAccessLevelKey = "permanentUnlimitedAccessLevelV1"
    private static let legacyAccessClassificationPendingKey = "legacyUnlimitedAccessClassificationPendingV1"

    // MARK: - Observable State

    public var totalSecondsUsed: Double = 0
    public var successfulCapturesUsed: Int = 0
    public private(set) var accessLevel: VoxboardAccessLevel = .free
    public private(set) var isLegacyAccessClassificationPending = false
    public private(set) var hasCurrentIndividualStoreEntitlement = false

    private let defaults: UserDefaults?
    private var permanentAccessLevel: VoxboardAccessLevel = .free

    // MARK: - Derived

    /// Source-compatible paid-state check used throughout the app and extensions.
    public var hasUnlocked: Bool { accessLevel.hasUnlimitedAccess }
    public var hasFamilyAccess: Bool { accessLevel.includesFamilySharing }
    public var isEligibleForFamilyUpgrade: Bool {
        accessLevel == .individual
            && (permanentAccessLevel == .individual || hasCurrentIndividualStoreEntitlement)
    }
    public var purchaseOptions: [VoxboardPurchaseProduct] {
        if accessLevel == .individual {
            return isEligibleForFamilyUpgrade ? [.familyUpgrade] : []
        }
        guard !isLegacyAccessClassificationPending else { return [] }
        return VoxboardPurchaseProduct.purchaseOptions(for: accessLevel)
    }
    public var minutesUsed: Double { totalSecondsUsed / 60.0 }
    public var secondsRemaining: Double { max(0, Self.freeMinutesLimit * 60 - totalSecondsUsed) }
    public var minutesRemaining: Double { secondsRemaining / 60.0 }
    public var capturesRemaining: Int { max(0, Self.freeCaptureLimit - successfulCapturesUsed) }

    /// True when the free tier is exhausted and the user hasn't purchased.
    public var isAtLimit: Bool {
        !hasUnlocked && totalSecondsUsed >= Self.freeMinutesLimit * 60
    }

    /// True when the free Capture allowance is exhausted and the user hasn't purchased.
    public var isCaptureAtLimit: Bool {
        !hasUnlocked && successfulCapturesUsed >= Self.freeCaptureLimit
    }

    /// 0…1 fraction of free transcription consumed.
    public var fractionUsed: Double {
        min(1.0, totalSecondsUsed / (Self.freeMinutesLimit * 60))
    }

    /// 0…1 fraction of free Capture deliveries consumed.
    public var captureFractionUsed: Double {
        min(1.0, Double(successfulCapturesUsed) / Double(Self.freeCaptureLimit))
    }

    // MARK: - Init

    public init(defaults: UserDefaults? = AppConstants.sharedDefaults) {
        self.defaults = defaults
        reload()
    }

    // MARK: - Mutation

    /// Add `seconds` to the cumulative counter. Call after every successful transcription.
    public func addUsage(seconds: Double) {
        totalSecondsUsed += seconds
        persist()
    }

    /// Preserve the original unlock behavior for paid-app migrations and callers
    /// that granted lifetime individual access before access levels were introduced.
    public func unlock() {
        grantPermanentIndividualAccess()
    }

    /// Grants grandfathered access that does not depend on a StoreKit entitlement.
    public func grantPermanentIndividualAccess() {
        permanentAccessLevel = VoxboardAccessLevel.highest(permanentAccessLevel, .individual)
        accessLevel = VoxboardAccessLevel.highest(accessLevel, .individual)
        isLegacyAccessClassificationPending = false
        persist()
    }

    /// Completes classification of the entitlement Boolean used by older builds.
    /// Only confirmed owners of the original paid app receive permanent access;
    /// StoreKit purchasers remain governed by their current transaction.
    public func completeLegacyAccessClassification(isOriginalPaidAppOwner: Bool) {
        if isOriginalPaidAppOwner {
            permanentAccessLevel = VoxboardAccessLevel.highest(permanentAccessLevel, .individual)
            accessLevel = VoxboardAccessLevel.highest(accessLevel, .individual)
        }
        isLegacyAccessClassificationPending = false
        persist()
    }

    /// Applies a newly verified transaction immediately. Launch and restore flows
    /// should subsequently reconcile against `Transaction.currentEntitlements`.
    public func applyVerifiedPurchase(_ product: VoxboardPurchaseProduct) {
        accessLevel = VoxboardAccessLevel.highest(accessLevel, product.grantedAccessLevel)
        if product == .individual {
            hasCurrentIndividualStoreEntitlement = true
        }
        persist()
    }

    /// Replaces StoreKit-derived access with the complete current entitlement set,
    /// while retaining access granted to owners of the original paid app.
    public func reconcileStoreEntitlements(_ products: some Sequence<VoxboardPurchaseProduct>) {
        let currentProducts = Array(products)
        hasCurrentIndividualStoreEntitlement = currentProducts.contains(.individual)
        let storeAccess = currentProducts.reduce(VoxboardAccessLevel.free) { level, product in
            VoxboardAccessLevel.highest(level, product.grantedAccessLevel)
        }
        let reconciledAccess = VoxboardAccessLevel.highest(permanentAccessLevel, storeAccess)
        if isLegacyAccessClassificationPending,
           accessLevel == .individual,
           reconciledAccess == .free {
            // Preserve the old entitlement provisionally if the receipt is not
            // available yet. A completed modern-app classification will clear it.
        } else {
            accessLevel = reconciledAccess
        }
        persist()
    }

    /// Re-read values from disk (call when the app becomes active to pick up any
    /// changes written by the keyboard extension).
    public func reload() {
        totalSecondsUsed = defaults?.double(forKey: Self.usageSecondsKey) ?? 0
        let mirroredCaptures = defaults?.integer(
            forKey: AppConstants.captureUsageMirrorKey
        ) ?? 0
        successfulCapturesUsed = max(
            mirroredCaptures,
            CaptureDeliveryUsageStore.persistedHighWaterCount
        )

        permanentAccessLevel = Self.persistedAccessLevel(
            forKey: Self.permanentAccessLevelKey,
            defaults: defaults
        ) ?? .free
        isLegacyAccessClassificationPending = defaults?.bool(
            forKey: Self.legacyAccessClassificationPendingKey
        ) ?? false

        if let persistedLevel = Self.persistedAccessLevel(
            forKey: Self.accessLevelKey,
            defaults: defaults
        ) {
            accessLevel = VoxboardAccessLevel.highest(permanentAccessLevel, persistedLevel)
        } else if defaults?.bool(forKey: Self.hasUnlockedKey) == true {
            // `hasUnlocked` represented both the original paid app and StoreKit
            // purchasers. Keep access while StoreManager classifies its source.
            accessLevel = .individual
            isLegacyAccessClassificationPending = true
            persist()
        } else {
            accessLevel = permanentAccessLevel
        }
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

    private static func persistedAccessLevel(
        forKey key: String,
        defaults: UserDefaults?
    ) -> VoxboardAccessLevel? {
        guard let rawValue = defaults?.string(forKey: key) else { return nil }
        return VoxboardAccessLevel(rawValue: rawValue)
    }

    private func persist() {
        defaults?.set(totalSecondsUsed, forKey: Self.usageSecondsKey)
        defaults?.set(accessLevel.rawValue, forKey: Self.accessLevelKey)
        defaults?.set(permanentAccessLevel.rawValue, forKey: Self.permanentAccessLevelKey)
        defaults?.set(
            isLegacyAccessClassificationPending,
            forKey: Self.legacyAccessClassificationPendingKey
        )
        // Keep the legacy mirror for extensions and older app builds.
        defaults?.set(hasUnlocked, forKey: Self.hasUnlockedKey)
    }
}
