import Foundation
import StoreKit
import VoxboardShared

/// Manages the one-time in-app purchase that unlocks unlimited transcription.
@Observable
@MainActor
final class StoreManager {

    // MARK: - Product ID

    static let unlockProductID = "bontecou.Voxboard.unlock"

    // MARK: - Migration

    /// The highest build number that was shipped as a paid ($4.99) app.
    /// Users who downloaded any of these builds should be grandfathered into
    /// the unlimited tier automatically when the app transitions to free.
    private static let lastPaidBuildNumber = 4

    // MARK: - State

    var product: Product?
    var isPurchasing: Bool = false
    var isRestoring: Bool = false
    var errorMessage: String?

    // MARK: - Dependencies

    private let usageTracker: UsageTracker
    nonisolated(unsafe) private var transactionListenerTask: Task<Void, Never>?

    // MARK: - Init / Deinit

    init(usageTracker: UsageTracker) {
        self.usageTracker = usageTracker
    }

    func start() {
        migrateIfNeeded()          // ← run before anything else
        transactionListenerTask = listenForTransactions()
        Task { await loadProducts() }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Legacy Paid-App Migration

    /// Grants unlimited access to users who purchased the original $4.99 app.
    ///
    /// How it works: the App Store receipt embeds `originalApplicationVersion`,
    /// which holds the CFBundleVersion (build number) of the first build the user
    /// downloaded. If that build is ≤ `lastPaidBuildNumber`, the user paid for the
    /// app and should receive the unlock for free.
    ///
    /// This runs at most once per install (guarded by a UserDefaults flag).
    private func migrateIfNeeded() {
        let defaults = AppConstants.sharedDefaults ?? UserDefaults.standard
        let flagKey  = "v2_legacyPaidMigrationDone"
        guard !defaults.bool(forKey: flagKey) else { return }
        defaults.set(true, forKey: flagKey)

        // Already unlocked? Nothing to do.
        guard !usageTracker.hasUnlocked else { return }

        guard
            let receiptURL  = Bundle.main.appStoreReceiptURL,
            let receiptData = try? Data(contentsOf: receiptURL),
            let originalBuildStr = Self.extractOriginalApplicationVersion(from: receiptData),
            let originalBuild    = Int(originalBuildStr)
        else { return }

        print("[StoreManager] Receipt originalApplicationVersion = \(originalBuildStr)")

        if originalBuild <= Self.lastPaidBuildNumber {
            print("[StoreManager] Granting legacy unlock (paid build \(originalBuild))")
            usageTracker.unlock()
        }
    }

    /// Minimal ASN.1 scanner that extracts `originalApplicationVersion` (attribute
    /// type 19, 0x13) from the App Store receipt without requiring full PKCS#7 parsing.
    ///
    /// Receipt attribute layout (each attribute):
    /// ```
    /// SEQUENCE {
    ///   INTEGER  (attribute type)
    ///   INTEGER  (attribute version)
    ///   OCTET STRING {
    ///     IA5String (value)
    ///   }
    /// }
    /// ```
    nonisolated private static func extractOriginalApplicationVersion(from receipt: Data) -> String? {
        let bytes = [UInt8](receipt)
        let count = bytes.count

        // We look for the byte sequence [0x02, 0x01, 0x13] which encodes
        // INTEGER (length 1) value = 19 (0x13) — the originalApplicationVersion
        // attribute type.
        let needle: [UInt8] = [0x02, 0x01, 0x13]

        var i = 0
        while i <= count - needle.count {
            guard bytes[i] == needle[0],
                  bytes[i + 1] == needle[1],
                  bytes[i + 2] == needle[2] else {
                i += 1
                continue
            }

            // Found attribute type 19. Advance past [02 01 13].
            var pos = i + 3

            // Skip the attribute-version INTEGER: 02 <len> <bytes…>
            guard pos + 1 < count, bytes[pos] == 0x02 else { i += 1; continue }
            pos += 1
            let verLen = Int(bytes[pos]); pos += 1
            pos += verLen

            // Expect an OCTET STRING (0x04) wrapping the IA5String.
            guard pos + 1 < count, bytes[pos] == 0x04 else { i += 1; continue }
            pos += 1
            // Read the OCTET STRING length (handle multi-byte lengths).
            let (octetLen, octetAdvance) = decodeBerLength(bytes: bytes, pos: pos)
            guard octetLen > 0 else { i += 1; continue }
            pos += octetAdvance

            // Inside the OCTET STRING: IA5String (0x16) <len> <ascii…>
            guard pos + 1 < count, bytes[pos] == 0x16 else { i += 1; continue }
            pos += 1
            let (strLen, strAdvance) = decodeBerLength(bytes: bytes, pos: pos)
            pos += strAdvance

            guard strLen > 0, pos + strLen <= count else { i += 1; continue }
            let strBytes = bytes[pos ..< pos + strLen]
            return String(bytes: strBytes, encoding: .ascii)
        }
        return nil
    }

    /// Decodes a BER/DER length field. Returns (length, bytesConsumed).
    nonisolated private static func decodeBerLength(bytes: [UInt8], pos: Int) -> (Int, Int) {
        guard pos < bytes.count else { return (0, 0) }
        let first = bytes[pos]
        if first & 0x80 == 0 {
            // Short form: length fits in one byte.
            return (Int(first), 1)
        }
        let numOctets = Int(first & 0x7F)
        guard pos + numOctets < bytes.count else { return (0, 1) }
        var length = 0
        for k in 0 ..< numOctets {
            length = (length << 8) | Int(bytes[pos + 1 + k])
        }
        return (length, 1 + numOctets)
    }

    // MARK: - Load Products

    func loadProducts() async {
        do {
            let products = try await Product.products(for: [Self.unlockProductID])
            product = products.first
        } catch {
            print("[StoreManager] Failed to load products: \(error)")
        }
    }

    // MARK: - Purchase

    func purchase() async {
        guard let product else {
            errorMessage = "Product not available"
            return
        }
        isPurchasing = true
        errorMessage = nil

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                usageTracker.unlock()
                await transaction.finish()
            case .userCancelled:
                break
            case .pending:
                errorMessage = "Purchase pending approval"
            @unknown default:
                break
            }
        } catch {
            errorMessage = "Purchase failed: \(error.localizedDescription)"
        }

        isPurchasing = false
    }

    // MARK: - Restore

    func restorePurchases() async {
        isRestoring = true
        errorMessage = nil

        do {
            try await AppStore.sync()
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
            isRestoring = false
            return
        }

        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.unlockProductID {
                usageTracker.unlock()
                await transaction.finish()
            }
        }

        isRestoring = false
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Never> {
        // Inherit MainActor context so we can safely mutate @Observable state directly.
        Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result,
                   transaction.productID == Self.unlockProductID {
                    self.usageTracker.unlock()
                    await transaction.finish()
                }
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

    // MARK: - Display Helpers

    var displayPrice: String {
        product?.displayPrice ?? "$9.99"
    }
}

// MARK: - Errors

enum StoreError: LocalizedError {
    case failedVerification

    var errorDescription: String? {
        switch self {
        case .failedVerification:
            return "Transaction verification failed"
        }
    }
}
