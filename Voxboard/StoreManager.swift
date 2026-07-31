import Foundation
import StoreKit
import VoxboardShared

/// Manages lifetime individual and Family Sharing purchases.
@Observable
@MainActor
final class StoreManager {

    // MARK: - Product IDs

    static let unlockProductID = VoxboardPurchaseProduct.individual.rawValue
    static let familyProductID = VoxboardPurchaseProduct.family.rawValue
    static let familyUpgradeProductID = VoxboardPurchaseProduct.familyUpgrade.rawValue

    // MARK: - Migration

    /// The highest build number that was shipped as a paid ($4.99) app.
    private static let lastPaidBuildNumber = 4

    // MARK: - State

    private(set) var productsByID: [String: Product] = [:]
    private(set) var isEntitlementStateReady = false
    var purchasingProductID: String?
    var isRestoring = false
    var errorMessage: String?

    var isPurchasing: Bool { purchasingProductID != nil }
    var product: Product? { product(for: .individual) }
    var familyProduct: Product? { product(for: .family) }
    var familyUpgradeProduct: Product? { product(for: .familyUpgrade) }

    // MARK: - Dependencies

    private let usageTracker: UsageTracker
    @ObservationIgnored private var transactionListenerTask: Task<Void, Never>?
    @ObservationIgnored private var hasVerifiedAppTransaction = false

    // MARK: - Init / Deinit

    init(usageTracker: UsageTracker) {
        self.usageTracker = usageTracker
    }

    func start() {
        if transactionListenerTask == nil {
            transactionListenerTask = listenForTransactions()
        }
        Task { await prepareForPurchases() }
    }

    func prepareForPurchases() async {
        await verifyAppTransactionIfNeeded()
        await syncCurrentEntitlements()
        await loadProducts()
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Legacy Paid-App Migration

    /// Uses Apple's signed AppTransaction to distinguish original paid-app
    /// owners from users whose old `hasUnlocked` Boolean came from StoreKit.
    private func verifyAppTransactionIfNeeded(forceRefresh: Bool = false) async {
        let defaults = AppConstants.sharedDefaults ?? UserDefaults.standard
        let flagKey = "v3_verifiedLegacyPaidAccessMigrationDone"
        if defaults.bool(forKey: flagKey) {
            hasVerifiedAppTransaction = true
            return
        }

        do {
            let verification: VerificationResult<AppTransaction>
            if forceRefresh {
                verification = try await AppTransaction.refresh()
            } else {
                verification = try await AppTransaction.shared
            }
            guard case .verified(let appTransaction) = verification,
                  appTransaction.bundleID == Bundle.main.bundleIdentifier else {
                errorMessage = "Could not verify your App Store purchase history. Try Restore Purchases."
                return
            }

            let isOriginalPaidAppOwner: Bool
            if let originalBuild = Int(appTransaction.originalAppVersion) {
                isOriginalPaidAppOwner = originalBuild <= Self.lastPaidBuildNumber
                if isOriginalPaidAppOwner {
                    print("[StoreManager] Granting verified paid-app access (build \(originalBuild))")
                }
            } else if appTransaction.environment != .production {
                // Sandbox/TestFlight commonly reports the placeholder `1.0`
                // instead of the production CFBundleVersion. Never grandfather
                // that placeholder, but allow purchase testing to continue.
                isOriginalPaidAppOwner = false
            } else {
                errorMessage = "Could not verify your App Store purchase history. Try Restore Purchases."
                return
            }
            usageTracker.completeLegacyAccessClassification(
                isOriginalPaidAppOwner: isOriginalPaidAppOwner
            )
            defaults.set(true, forKey: flagKey)
            hasVerifiedAppTransaction = true
        } catch {
            print("[StoreManager] App transaction verification failed: \(error)")
            errorMessage = "Could not verify your App Store purchase history. Try Restore Purchases."
        }
    }

    // MARK: - Products

    func loadProducts() async {
        do {
            let products = try await Product.products(
                for: VoxboardPurchaseProduct.allCases.map(\.rawValue)
            )
            productsByID = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
            let hasMissingOffer = usageTracker.purchaseOptions.contains {
                productsByID[$0.rawValue] == nil
            }
            if hasMissingOffer {
                errorMessage = "Some purchase options are temporarily unavailable."
            } else if isEntitlementStateReady {
                errorMessage = nil
            }
        } catch {
            print("[StoreManager] Failed to load products: \(error)")
            errorMessage = "Purchases are not available right now."
        }
    }

    func product(for purchaseProduct: VoxboardPurchaseProduct) -> Product? {
        productsByID[purchaseProduct.rawValue]
    }

    func displayPrice(for purchaseProduct: VoxboardPurchaseProduct) -> String? {
        product(for: purchaseProduct)?.displayPrice
    }

    var displayPrice: String? { displayPrice(for: .individual) }
    var familyDisplayPrice: String? { displayPrice(for: .family) }
    var familyUpgradeDisplayPrice: String? { displayPrice(for: .familyUpgrade) }

    // MARK: - Purchase

    func purchase(
        _ purchaseProduct: VoxboardPurchaseProduct,
        context: OnboardingAnalyticsPaywallContext = .limit
    ) async {
        // Persisted access can be stale after reinstall, refund, or a Family
        // Sharing change. Verify and reconcile before deciding which price applies.
        await verifyAppTransactionIfNeeded()
        await syncCurrentEntitlements()
        let analyticsProduct = OnboardingAnalyticsProductID(purchaseProduct)

        guard isEntitlementStateReady else {
            errorMessage = "Could not verify purchase eligibility. Try Restore Purchases."
            OnboardingAnalyticsClient.shared.trackPurchaseFinished(
                outcome: .failed,
                context: context,
                errorCategory: .verificationFailed,
                productId: analyticsProduct,
                quotaState: usageTracker.onboardingAnalyticsQuotaState
            )
            return
        }

        guard usageTracker.purchaseOptions.contains(purchaseProduct) else {
            errorMessage = purchaseProduct == .familyUpgrade
                ? "The Family upgrade is available to existing Unlimited owners."
                : "This purchase is not available for your current access level."
            OnboardingAnalyticsClient.shared.trackPurchaseFinished(
                outcome: .failed,
                context: context,
                errorCategory: .notUnlocked,
                productId: analyticsProduct,
                quotaState: usageTracker.onboardingAnalyticsQuotaState
            )
            return
        }

        guard let product = product(for: purchaseProduct) else {
            errorMessage = "Product not available"
            OnboardingAnalyticsClient.shared.trackPurchaseFinished(
                outcome: .failed,
                context: context,
                errorCategory: .storeUnavailable,
                productId: analyticsProduct,
                quotaState: usageTracker.onboardingAnalyticsQuotaState
            )
            return
        }

        purchasingProductID = purchaseProduct.rawValue
        errorMessage = nil
        defer { purchasingProductID = nil }

        OnboardingAnalyticsClient.shared.trackPurchaseStarted(
            context: context,
            productId: analyticsProduct,
            quotaState: usageTracker.onboardingAnalyticsQuotaState
        )

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                do {
                    let transaction = try checkVerified(verification)
                    guard let verifiedProduct = VoxboardPurchaseProduct(rawValue: transaction.productID) else {
                        throw StoreError.unrecognizedProduct
                    }
                    usageTracker.applyVerifiedPurchase(verifiedProduct)
                    await transaction.finish()
                    await syncCurrentEntitlements(including: [verifiedProduct])
                    OnboardingAnalyticsClient.shared.trackPurchaseFinished(
                        outcome: .succeeded,
                        context: context,
                        productId: analyticsProduct,
                        quotaState: usageTracker.onboardingAnalyticsQuotaState
                    )
                } catch {
                    errorMessage = "Purchase verification failed"
                    OnboardingAnalyticsClient.shared.trackPurchaseFinished(
                        outcome: .failed,
                        context: context,
                        errorCategory: .verificationFailed,
                        productId: analyticsProduct,
                        quotaState: usageTracker.onboardingAnalyticsQuotaState
                    )
                }
            case .userCancelled:
                OnboardingAnalyticsClient.shared.trackPurchaseFinished(
                    outcome: .cancelled,
                    context: context,
                    errorCategory: .userCancelled,
                    productId: analyticsProduct,
                    quotaState: usageTracker.onboardingAnalyticsQuotaState
                )
            case .pending:
                errorMessage = "Purchase pending approval"
                OnboardingAnalyticsClient.shared.trackPurchaseFinished(
                    outcome: .pending,
                    context: context,
                    productId: analyticsProduct,
                    quotaState: usageTracker.onboardingAnalyticsQuotaState
                )
            @unknown default:
                OnboardingAnalyticsClient.shared.trackPurchaseFinished(
                    outcome: .failed,
                    context: context,
                    errorCategory: .unknown,
                    productId: analyticsProduct,
                    quotaState: usageTracker.onboardingAnalyticsQuotaState
                )
            }
        } catch {
            errorMessage = "Purchase failed: \(error.localizedDescription)"
            OnboardingAnalyticsClient.shared.trackPurchaseFinished(
                outcome: .failed,
                context: context,
                errorCategory: .storeUnavailable,
                productId: analyticsProduct,
                quotaState: usageTracker.onboardingAnalyticsQuotaState
            )
        }
    }

    /// Backward-compatible entry point for the original individual unlock.
    func purchase(context: OnboardingAnalyticsPaywallContext = .limit) async {
        await purchase(.individual, context: context)
    }

    // MARK: - Restore / Entitlements

    func restorePurchases(context: OnboardingAnalyticsPaywallContext = .restore) async {
        isRestoring = true
        errorMessage = nil
        defer { isRestoring = false }

        OnboardingAnalyticsClient.shared.trackRestoreStarted(
            context: context,
            quotaState: usageTracker.onboardingAnalyticsQuotaState
        )

        do {
            try await AppStore.sync()
            await verifyAppTransactionIfNeeded(forceRefresh: true)
            let restoredProducts = await syncCurrentEntitlements()
            let restored = !restoredProducts.isEmpty
                || (usageTracker.hasUnlocked && !usageTracker.isLegacyAccessClassificationPending)
            let analyticsProduct = VoxboardPurchaseProduct.strongest(in: restoredProducts)
                .map(OnboardingAnalyticsProductID.init)

            if restored {
                errorMessage = nil
            } else {
                errorMessage = usageTracker.isLegacyAccessClassificationPending
                    ? "Could not verify your previous purchase. Please try again."
                    : "No Vox.md Unlimited purchase was found."
            }
            OnboardingAnalyticsClient.shared.trackRestoreFinished(
                outcome: restored ? .succeeded : .failed,
                context: context,
                errorCategory: restored ? nil : .notUnlocked,
                productId: analyticsProduct,
                quotaState: usageTracker.onboardingAnalyticsQuotaState
            )
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
            OnboardingAnalyticsClient.shared.trackRestoreFinished(
                outcome: .failed,
                context: context,
                errorCategory: .storeUnavailable,
                quotaState: usageTracker.onboardingAnalyticsQuotaState
            )
        }
    }

    /// App Group defaults are removed on uninstall, while StoreKit and shared
    /// family entitlements persist. Reconcile before quota-gated launch work.
    @discardableResult
    func syncCurrentEntitlements(
        including additionalProducts: [VoxboardPurchaseProduct] = []
    ) async -> [VoxboardPurchaseProduct] {
        var currentProducts = additionalProducts

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil,
                  let product = VoxboardPurchaseProduct(rawValue: transaction.productID) else {
                continue
            }
            if !currentProducts.contains(product) {
                currentProducts.append(product)
            }
            await transaction.finish()
        }

        usageTracker.reconcileStoreEntitlements(currentProducts)
        isEntitlementStateReady = hasVerifiedAppTransaction || !currentProducts.isEmpty
        return currentProducts
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                guard case .verified(let transaction) = result,
                      let product = VoxboardPurchaseProduct(rawValue: transaction.productID) else {
                    continue
                }
                await transaction.finish()
                let additionalProducts = transaction.revocationDate == nil ? [product] : []
                await self.syncCurrentEntitlements(including: additionalProducts)
            }
        }
    }

    // MARK: - Verification

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }
}

// MARK: - Errors

enum StoreError: LocalizedError {
    case failedVerification
    case unrecognizedProduct

    var errorDescription: String? {
        switch self {
        case .failedVerification:
            "Transaction verification failed"
        case .unrecognizedProduct:
            "The transaction did not match a Vox.md product"
        }
    }
}
