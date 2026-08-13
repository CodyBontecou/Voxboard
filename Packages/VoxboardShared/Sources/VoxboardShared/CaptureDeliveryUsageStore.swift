import Foundation
import Security
import VoxboardCaptureCore

public enum CaptureDeliveryUsageStoreError: Error, Equatable, LocalizedError, Sendable {
    case storageUnavailable
    case unsupportedSchemaVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return "Shared Capture usage storage is unavailable."
        case .unsupportedSchemaVersion(let version):
            return "Capture usage schema version \(version) is not supported."
        }
    }
}

public struct CaptureDeliveryUsageSnapshot: Equatable, Sendable {
    public let successfulCapturesUsed: Int
    public let reservedCaptureSlots: Int
    public let freeCaptureLimit: Int

    public var capturesRemaining: Int {
        max(0, freeCaptureLimit - successfulCapturesUsed)
    }

    public var isAtLimit: Bool {
        successfulCapturesUsed >= freeCaptureLimit
    }
}

package struct CaptureUsageHighWaterMark: Equatable, Codable, Sendable {
    package var successfulCaptureCount: Int
    package var committedRequestIDs: Set<UUID>

    package init(successfulCaptureCount: Int, committedRequestIDs: Set<UUID> = []) {
        self.successfulCaptureCount = max(0, successfulCaptureCount)
        self.committedRequestIDs = committedRequestIDs
    }
}

package protocol CaptureUsageHighWaterMarkStoring: Sendable {
    func load() throws -> CaptureUsageHighWaterMark
    func raise(to highWaterMark: CaptureUsageHighWaterMark) throws
}

package enum CaptureUsageHighWaterMarkCodec {
    package static func decode(_ data: Data) -> CaptureUsageHighWaterMark? {
        if let decoded = try? JSONDecoder().decode(CaptureUsageHighWaterMark.self, from: data) {
            return CaptureUsageHighWaterMark(
                successfulCaptureCount: decoded.successfulCaptureCount,
                committedRequestIDs: decoded.committedRequestIDs
            )
        }
        // v1 stored only the decimal count. Preserve it as an unattributed
        // baseline while upgrading the next successful write.
        if let raw = String(data: data, encoding: .utf8), let value = Int(raw) {
            return CaptureUsageHighWaterMark(successfulCaptureCount: value)
        }
        return nil
    }
}

private struct CaptureUsageLedger: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var unattributedSuccessfulCount = 0
    var committedRequestIDs: Set<UUID> = []
    var reservationTokensByRequestID: [UUID: Set<UUID>] = [:]

    var successfulCaptureCount: Int {
        unattributedSuccessfulCount + committedRequestIDs.count
    }

    var reservedCaptureSlots: Int {
        reservationTokensByRequestID.keys.reduce(into: 0) { count, requestID in
            if !committedRequestIDs.contains(requestID) { count += 1 }
        }
    }
}

/// Exact-once accounting for successful, non-voice Capture deliveries.
///
/// The coordinated App Group ledger prevents app/macOS delivery races. A
/// Keychain high-water mark restores the used count after a normal uninstall
/// and reinstall on the same device. Neither captured content nor destination
/// metadata is stored here.
public actor CaptureDeliveryUsageStore: CaptureDeliveryAccounting {
    public static let shared = CaptureDeliveryUsageStore()

    private let ledgerURL: URL?
    private let freeCaptureLimit: Int
    private let coordinator: any CaptureFileCoordinating
    private let fileManager: FileManager
    private let highWaterStore: any CaptureUsageHighWaterMarkStoring
    private let isUnlocked: @Sendable () -> Bool
    private let mirrorSuccessfulCount: @Sendable (Int) -> Void
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public nonisolated static var persistedHighWaterCount: Int {
        (try? KeychainCaptureUsageHighWaterMarkStore.shared.load().successfulCaptureCount) ?? 0
    }

    package init(
        ledgerURL: URL? = AppConstants.captureUsageURL,
        freeCaptureLimit: Int = UsageTracker.freeCaptureLimit,
        coordinator: any CaptureFileCoordinating = NSFileCoordinatorCaptureFileCoordinator.shared,
        fileManager: FileManager = .default,
        highWaterStore: any CaptureUsageHighWaterMarkStoring = KeychainCaptureUsageHighWaterMarkStore.shared,
        isUnlocked: @escaping @Sendable () -> Bool = {
            AppConstants.sharedDefaults?.bool(forKey: UsageTracker.hasUnlockedKey) ?? false
        },
        mirrorSuccessfulCount: @escaping @Sendable (Int) -> Void = { count in
            AppConstants.sharedDefaults?.set(count, forKey: AppConstants.captureUsageMirrorKey)
        }
    ) {
        self.ledgerURL = ledgerURL
        self.freeCaptureLimit = max(0, freeCaptureLimit)
        self.coordinator = coordinator
        self.fileManager = fileManager
        self.highWaterStore = highWaterStore
        self.isUnlocked = isUnlocked
        self.mirrorSuccessfulCount = mirrorSuccessfulCount
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func reserve(for request: CaptureRequest) async throws -> CaptureDeliveryReservation {
        // Voice transcripts already consume the independent transcription
        // allowance. The lifetime purchase bypasses both free-tier meters.
        guard request.deliveryKind != .meteredVoiceTranscript, !isUnlocked() else {
            return .bypassed(requestID: request.id)
        }
        guard let ledgerURL else {
            throw CaptureDeliveryUsageStoreError.storageUnavailable
        }
        try ensureParentDirectory(for: ledgerURL)

        let token = UUID()
        let result = try coordinator.coordinateWriting(at: ledgerURL) { coordinatedURL in
            var ledger = try loadReconciledLedger(from: coordinatedURL)
            if ledger.committedRequestIDs.contains(request.id) {
                try persist(ledger, to: coordinatedURL)
                return (CaptureDeliveryReservation.alreadyCounted(requestID: request.id), ledger)
            }

            let requestAlreadyReserved = ledger.reservationTokensByRequestID[request.id]?.isEmpty == false
            if !requestAlreadyReserved,
               ledger.successfulCaptureCount + ledger.reservedCaptureSlots >= freeCaptureLimit {
                throw CaptureDeliveryQuotaError.limitReached(limit: freeCaptureLimit)
            }

            ledger.reservationTokensByRequestID[request.id, default: []].insert(token)
            try persist(ledger, to: coordinatedURL)
            return (
                CaptureDeliveryReservation.reserved(requestID: request.id, token: token),
                ledger
            )
        }
        mirrorSuccessfulCount(result.1.successfulCaptureCount)
        return result.0
    }

    public func commit(_ reservation: CaptureDeliveryReservation) async throws {
        guard case .reserved(let requestID, _) = reservation else { return }
        guard let ledgerURL else {
            throw CaptureDeliveryUsageStoreError.storageUnavailable
        }
        try ensureParentDirectory(for: ledgerURL)

        let successfulCount = try coordinator.coordinateWriting(at: ledgerURL) { coordinatedURL in
            var ledger = try loadReconciledLedger(from: coordinatedURL)
            if !ledger.committedRequestIDs.contains(requestID) {
                ledger.committedRequestIDs.insert(requestID)
            }
            ledger.reservationTokensByRequestID.removeValue(forKey: requestID)

            // Raise the uninstall-resistant value before finalizing the local
            // ledger. A Keychain failure therefore cannot silently report a
            // fully committed delivery that would reset after reinstall.
            try highWaterStore.raise(to: CaptureUsageHighWaterMark(
                successfulCaptureCount: ledger.successfulCaptureCount,
                committedRequestIDs: ledger.committedRequestIDs
            ))
            try persist(ledger, to: coordinatedURL)
            return ledger.successfulCaptureCount
        }
        mirrorSuccessfulCount(successfulCount)
    }

    public func release(_ reservation: CaptureDeliveryReservation) async {
        guard case .reserved(let requestID, let token) = reservation,
              let ledgerURL else { return }
        do {
            try ensureParentDirectory(for: ledgerURL)
            let successfulCount = try coordinator.coordinateWriting(at: ledgerURL) { coordinatedURL in
                var ledger = try loadReconciledLedger(from: coordinatedURL)
                ledger.reservationTokensByRequestID[requestID]?.remove(token)
                if ledger.reservationTokensByRequestID[requestID]?.isEmpty == true {
                    ledger.reservationTokensByRequestID.removeValue(forKey: requestID)
                }
                try persist(ledger, to: coordinatedURL)
                return ledger.successfulCaptureCount
            }
            mirrorSuccessfulCount(successfulCount)
        } catch {
            // A conservative leaked reservation is safer than opening a slot
            // after an uncertain cross-process write. The same request ID can
            // still reserve again and commit all of its tokens after retry.
        }
    }

    public func snapshot() throws -> CaptureDeliveryUsageSnapshot {
        guard let ledgerURL else {
            let highWater = (try? highWaterStore.load().successfulCaptureCount) ?? 0
            return CaptureDeliveryUsageSnapshot(
                successfulCapturesUsed: highWater,
                reservedCaptureSlots: 0,
                freeCaptureLimit: freeCaptureLimit
            )
        }
        try ensureParentDirectory(for: ledgerURL)
        let ledger = try coordinator.coordinateWriting(at: ledgerURL) { coordinatedURL in
            let ledger = try loadReconciledLedger(from: coordinatedURL)
            try persist(ledger, to: coordinatedURL)
            return ledger
        }
        mirrorSuccessfulCount(ledger.successfulCaptureCount)
        return CaptureDeliveryUsageSnapshot(
            successfulCapturesUsed: ledger.successfulCaptureCount,
            reservedCaptureSlots: ledger.reservedCaptureSlots,
            freeCaptureLimit: freeCaptureLimit
        )
    }

    private func loadReconciledLedger(from url: URL) throws -> CaptureUsageLedger {
        let highWater = try highWaterStore.load()
        var ledger: CaptureUsageLedger
        if fileManager.fileExists(atPath: url.path) {
            do {
                ledger = try decoder.decode(CaptureUsageLedger.self, from: Data(contentsOf: url))
                guard ledger.schemaVersion == CaptureUsageLedger.currentSchemaVersion else {
                    throw CaptureDeliveryUsageStoreError.unsupportedSchemaVersion(ledger.schemaVersion)
                }
            } catch let error as CaptureDeliveryUsageStoreError {
                throw error
            } catch {
                try quarantineCorruptLedger(at: url)
                ledger = CaptureUsageLedger(unattributedSuccessfulCount: highWater.successfulCaptureCount)
            }
        } else {
            ledger = CaptureUsageLedger(unattributedSuccessfulCount: highWater.successfulCaptureCount)
        }

        // Keychain stores both the high-water count and the small (maximum 10)
        // set of committed IDs. If a process dies after raising Keychain but
        // before persisting this ledger, unioning IDs prevents that same
        // request from becoming an unattributed success and being counted again.
        let mergedRequestIDs = ledger.committedRequestIDs.union(highWater.committedRequestIDs)
        let mergedSuccessfulCount = max(
            ledger.successfulCaptureCount,
            highWater.successfulCaptureCount,
            mergedRequestIDs.count
        )
        ledger.committedRequestIDs = mergedRequestIDs
        for requestID in mergedRequestIDs {
            ledger.reservationTokensByRequestID.removeValue(forKey: requestID)
        }
        ledger.unattributedSuccessfulCount = max(0, mergedSuccessfulCount - mergedRequestIDs.count)

        if ledger.successfulCaptureCount > highWater.successfulCaptureCount
            || !ledger.committedRequestIDs.isSubset(of: highWater.committedRequestIDs) {
            try highWaterStore.raise(to: CaptureUsageHighWaterMark(
                successfulCaptureCount: ledger.successfulCaptureCount,
                committedRequestIDs: ledger.committedRequestIDs
            ))
        }
        return ledger
    }

    private func persist(_ ledger: CaptureUsageLedger, to url: URL) throws {
        try encoder.encode(ledger).write(to: url, options: .atomic)
    }

    private func ensureParentDirectory(for url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func quarantineCorruptLedger(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let quarantineURL = url.deletingLastPathComponent().appendingPathComponent(
            "capture-usage-corrupt-\(UUID().uuidString.lowercased()).json"
        )
        try fileManager.moveItem(at: url, to: quarantineURL)
    }
}

/// The only production Capture pipeline. Core's `.shared` pipeline remains
/// deliberately unmetered for isolated framework clients and tests.
public enum AppCapturePipeline {
    public static let shared = CapturePipeline(
        deliveryAccounting: CaptureDeliveryUsageStore.shared
    )
}

private struct CaptureUsageKeychainError: Error, @unchecked Sendable {
    let status: OSStatus
}

private final class KeychainCaptureUsageHighWaterMarkStore: CaptureUsageHighWaterMarkStoring, @unchecked Sendable {
    static let shared = KeychainCaptureUsageHighWaterMarkStore()

    private let service = "bontecou.Voxboard.capture-freemium"
    private let account = "successful-capture-high-water-v1"
    private let lock = NSLock()

    func load() throws -> CaptureUsageHighWaterMark {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    func raise(to highWaterMark: CaptureUsageHighWaterMark) throws {
        lock.lock()
        defer { lock.unlock() }
        let current = try loadLocked()
        let mergedIDs = current.committedRequestIDs.union(highWaterMark.committedRequestIDs)
        let raised = CaptureUsageHighWaterMark(
            successfulCaptureCount: max(
                current.successfulCaptureCount,
                highWaterMark.successfulCaptureCount,
                mergedIDs.count
            ),
            committedRequestIDs: mergedIDs
        )
        guard raised != current else { return }
        try saveLocked(raised)
    }

    private func loadLocked() throws -> CaptureUsageHighWaterMark {
        var query: [String: Any] = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return CaptureUsageHighWaterMark(successfulCaptureCount: 0)
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CaptureUsageKeychainError(status: status)
        }
        if let decoded = CaptureUsageHighWaterMarkCodec.decode(data) { return decoded }
        throw CaptureUsageKeychainError(status: errSecDecode)
    }

    private func saveLocked(_ highWaterMark: CaptureUsageHighWaterMark) throws {
        let data = try JSONEncoder().encode(highWaterMark)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CaptureUsageKeychainError(status: updateStatus)
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        #if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CaptureUsageKeychainError(status: addStatus)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
