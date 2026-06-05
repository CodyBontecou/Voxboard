import Foundation
import StoreKit
import VoxboardShared

/// StoreKit 2 unlock manager for the macOS companion app.
@Observable
@MainActor
final class MacStoreManager {
    static let unlockProductID = "bontecou.Voxboard.unlock"

    var product: Product?
    var isPurchasing = false
    var isRestoring = false
    var errorMessage: String?

    private let usageTracker: UsageTracker
    @ObservationIgnored
    nonisolated(unsafe) private var transactionListenerTask: Task<Void, Never>?

    init(usageTracker: UsageTracker) {
        self.usageTracker = usageTracker
    }

    func start() {
        transactionListenerTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
        Task {
            await loadProducts()
            await syncCurrentEntitlements()
        }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    var displayPrice: String {
        product?.displayPrice ?? "$9.99"
    }

    func loadProducts() async {
        do {
            product = try await Product.products(for: [Self.unlockProductID]).first
        } catch {
            errorMessage = "Could not load purchase: \(error.localizedDescription)"
        }
    }

    func purchase() async {
        guard let product else {
            errorMessage = "Purchase is not available right now."
            return
        }
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                usageTracker.unlock()
                await transaction.finish()
            case .pending:
                errorMessage = "Purchase pending approval."
            case .userCancelled:
                break
            @unknown default:
                errorMessage = "Unknown purchase result."
            }
        } catch {
            errorMessage = "Purchase failed: \(error.localizedDescription)"
        }
    }

    func restore() async {
        isRestoring = true
        errorMessage = nil
        defer { isRestoring = false }

        do {
            try await AppStore.sync()
            await syncCurrentEntitlements()
            if !usageTracker.hasUnlocked {
                errorMessage = "No Voxboard Unlimited purchase was found."
            }
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    private func syncCurrentEntitlements() async {
        for await result in Transaction.currentEntitlements {
            await handle(result)
        }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard let transaction = try? checkVerified(result),
              transaction.productID == Self.unlockProductID else {
            return
        }
        usageTracker.unlock()
        await transaction.finish()
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
