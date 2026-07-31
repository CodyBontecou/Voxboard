import Foundation
import StoreKit
import VoxboardShared

/// StoreKit 2 manager for lifetime individual and Family Sharing purchases.
@Observable
@MainActor
final class MacStoreManager {
    static let unlockProductID = VoxboardPurchaseProduct.individual.rawValue
    static let familyProductID = VoxboardPurchaseProduct.family.rawValue
    static let familyUpgradeProductID = VoxboardPurchaseProduct.familyUpgrade.rawValue

    private(set) var productsByID: [String: Product] = [:]
    private(set) var isEntitlementStateReady = false
    var purchasingProductID: String?
    var isRestoring = false
    var errorMessage: String?

    var isPurchasing: Bool { purchasingProductID != nil }
    var product: Product? { product(for: .individual) }
    var familyProduct: Product? { product(for: .family) }
    var familyUpgradeProduct: Product? { product(for: .familyUpgrade) }

    private let usageTracker: UsageTracker
    @ObservationIgnored private var transactionListenerTask: Task<Void, Never>?

    init(usageTracker: UsageTracker) {
        self.usageTracker = usageTracker
    }

    func start() {
        if usageTracker.isLegacyAccessClassificationPending {
            // The original paid-app migration was iOS-only. Mac access must be
            // backed by a current StoreKit transaction.
            usageTracker.completeLegacyAccessClassification(isOriginalPaidAppOwner: false)
        }
        if transactionListenerTask == nil {
            transactionListenerTask = Task { [weak self] in
                for await result in Transaction.updates {
                    guard let self,
                          case .verified(let transaction) = result,
                          let product = VoxboardPurchaseProduct(rawValue: transaction.productID) else {
                        continue
                    }
                    await transaction.finish()
                    let additionalProducts = transaction.revocationDate == nil ? [product] : []
                    await self.syncCurrentEntitlements(including: additionalProducts)
                }
            }
        }
        Task { await prepareForPurchases() }
    }

    func prepareForPurchases() async {
        await syncCurrentEntitlements()
        await loadProducts()
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    func loadProducts() async {
        do {
            let products = try await Product.products(
                for: VoxboardPurchaseProduct.allCases.map(\.rawValue)
            )
            productsByID = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
            let hasMissingOffer = usageTracker.purchaseOptions.contains {
                productsByID[$0.rawValue] == nil
            }
            errorMessage = hasMissingOffer
                ? "Some purchase options are temporarily unavailable."
                : nil
        } catch {
            errorMessage = "Could not load purchases: \(error.localizedDescription)"
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

    func purchase(
        _ purchaseProduct: VoxboardPurchaseProduct,
        context: OnboardingAnalyticsPaywallContext = .settings
    ) async {
        // Resolve reinstall, refund, and Family Sharing changes before applying
        // the discounted-upgrade eligibility rule.
        await syncCurrentEntitlements()
        let analyticsProduct = OnboardingAnalyticsProductID(purchaseProduct)

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
            errorMessage = "Purchase is not available right now."
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
                        throw MacStoreError.unrecognizedProduct
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
                    errorMessage = "Purchase verification failed."
                    OnboardingAnalyticsClient.shared.trackPurchaseFinished(
                        outcome: .failed,
                        context: context,
                        errorCategory: .verificationFailed,
                        productId: analyticsProduct,
                        quotaState: usageTracker.onboardingAnalyticsQuotaState
                    )
                }
            case .pending:
                errorMessage = "Purchase pending approval."
                OnboardingAnalyticsClient.shared.trackPurchaseFinished(
                    outcome: .pending,
                    context: context,
                    productId: analyticsProduct,
                    quotaState: usageTracker.onboardingAnalyticsQuotaState
                )
            case .userCancelled:
                OnboardingAnalyticsClient.shared.trackPurchaseFinished(
                    outcome: .cancelled,
                    context: context,
                    errorCategory: .userCancelled,
                    productId: analyticsProduct,
                    quotaState: usageTracker.onboardingAnalyticsQuotaState
                )
            @unknown default:
                errorMessage = "Unknown purchase result."
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
    func purchase() async {
        await purchase(.individual)
    }

    func restore() async {
        isRestoring = true
        errorMessage = nil
        defer { isRestoring = false }

        OnboardingAnalyticsClient.shared.trackRestoreStarted(
            context: .restore,
            quotaState: usageTracker.onboardingAnalyticsQuotaState
        )

        do {
            try await AppStore.sync()
            let restoredProducts = await syncCurrentEntitlements()
            let restored = !restoredProducts.isEmpty || usageTracker.hasUnlocked
            let analyticsProduct = VoxboardPurchaseProduct.strongest(in: restoredProducts)
                .map(OnboardingAnalyticsProductID.init)

            if !restored {
                errorMessage = "No Vox.md Unlimited purchase was found."
            }
            OnboardingAnalyticsClient.shared.trackRestoreFinished(
                outcome: restored ? .succeeded : .failed,
                context: .restore,
                errorCategory: restored ? nil : .notUnlocked,
                productId: analyticsProduct,
                quotaState: usageTracker.onboardingAnalyticsQuotaState
            )
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
            OnboardingAnalyticsClient.shared.trackRestoreFinished(
                outcome: .failed,
                context: .restore,
                errorCategory: .storeUnavailable,
                quotaState: usageTracker.onboardingAnalyticsQuotaState
            )
        }
    }

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
        isEntitlementStateReady = true
        return currentProducts
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let safe):
            return safe
        }
    }
}

private enum MacStoreError: LocalizedError {
    case unrecognizedProduct

    var errorDescription: String? {
        "The transaction did not match a Vox.md product"
    }
}
