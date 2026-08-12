import Foundation

public enum CaptureInboxState: String, Codable, CaseIterable, Sendable {
    case pending
    case processing
    case completed
    case failed
}

public enum CaptureInboxError: Error, Equatable, LocalizedError, Sendable {
    case requestNotProcessing(UUID)

    public var errorDescription: String? {
        switch self {
        case .requestNotProcessing(let id):
            return "Capture request \(id.uuidString) is not being processed."
        }
    }
}

/// An idempotency tombstone, deliberately incapable of retaining captured
/// text, links, destination metadata, attachment names, or filesystem paths.
private struct CaptureCompletionReceipt: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var requestID: UUID
    var completedAt: Date

    init(requestID: UUID, completedAt: Date = Date()) {
        self.schemaVersion = Self.currentSchemaVersion
        self.requestID = requestID
        self.completedAt = completedAt
    }
}

public actor CaptureInbox {
    public nonisolated let rootDirectoryURL: URL
    private let coordinator: any CaptureFileCoordinating
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        rootDirectoryURL: URL,
        coordinator: any CaptureFileCoordinating = NSFileCoordinatorCaptureFileCoordinator.shared,
        fileManager: FileManager = .default
    ) {
        self.rootDirectoryURL = rootDirectoryURL
        self.coordinator = coordinator
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func enqueue(_ request: CaptureRequest) throws {
        try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            if CaptureInboxState.allCases.contains(where: {
                fileManager.fileExists(atPath: itemURL(for: request.id, state: $0).path)
            }) {
                return
            }
            let data = try encoder.encode(request)
            try data.write(to: itemURL(for: request.id, state: .pending), options: .atomic)
        }
    }

    public func claimNext(excludingRequestIDs: Set<UUID> = []) throws -> CaptureRequest? {
        try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            for pendingURL in try itemURLs(in: .pending) {
                let filenameID = UUID(
                    uuidString: pendingURL.deletingPathExtension().lastPathComponent
                )
                if let filenameID, excludingRequestIDs.contains(filenameID) {
                    continue
                }
                if let request = try claimPendingURL(pendingURL) { return request }
            }
            return nil
        }
    }

    public func claim(requestID: UUID) throws -> CaptureRequest? {
        try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            let pendingURL = itemURL(for: requestID, state: .pending)
            guard fileManager.fileExists(atPath: pendingURL.path) else { return nil }
            return try claimPendingURL(pendingURL)
        }
    }

    /// Atomically replaces a claimed request after Capture Preset processing. The exact
    /// processed payload is then reused by delivery retries instead of invoking
    /// a potentially nondeterministic processor again.
    public func replaceProcessingRequest(_ request: CaptureRequest) throws {
        try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            let url = itemURL(for: request.id, state: .processing)
            guard fileManager.fileExists(atPath: url.path) else {
                throw CaptureInboxError.requestNotProcessing(request.id)
            }
            try encoder.encode(request).write(to: url, options: .atomic)
        }
    }

    public func complete(requestID: UUID) throws {
        try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            let sourceURL = itemURL(for: requestID, state: .processing)
            let destinationURL = itemURL(for: requestID, state: .completed)
            if fileManager.fileExists(atPath: destinationURL.path) {
                if fileManager.fileExists(atPath: sourceURL.path) {
                    try fileManager.removeItem(at: sourceURL)
                }
            } else {
                guard fileManager.fileExists(atPath: sourceURL.path) else {
                    throw CaptureInboxError.requestNotProcessing(requestID)
                }
                // Write the privacy-safe tombstone before deleting the durable
                // request. A crash can leave both files, but never a completed
                // file containing the original private capture payload.
                try encoder.encode(CaptureCompletionReceipt(requestID: requestID))
                    .write(to: destinationURL, options: .atomic)
                try fileManager.removeItem(at: sourceURL)
            }
        }
        let stagingURL = rootDirectoryURL
            .appendingPathComponent("inbox-staging", isDirectory: true)
            .appendingPathComponent(requestID.uuidString.lowercased(), isDirectory: true)
        if fileManager.fileExists(atPath: stagingURL.path) {
            // Delivery is already committed and transitioned to completed.
            // Cleanup must not turn a successful capture into a false retry;
            // stale orphan cleanup will remove any provider refusal later.
            try? fileManager.removeItem(at: stagingURL)
        }
    }

    public func fail(requestID: UUID) throws {
        try transition(requestID: requestID, from: .processing, to: .failed)
    }

    /// Returns a claimed request to the pending queue without classifying a
    /// freemium quota block as a delivery failure. Its payload and stable
    /// request ID remain available after purchase or restore.
    public func returnToPending(requestID: UUID) throws {
        try transition(requestID: requestID, from: .processing, to: .pending)
    }

    public func requestIDs(in state: CaptureInboxState) throws -> [UUID] {
        try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            return try itemURLs(in: state).compactMap { url in
                if state == .completed {
                    return completionRequestID(for: url)
                }
                return try? decoder.decode(CaptureRequest.self, from: Data(contentsOf: url)).id
            }
        }
    }

    public func requestIDs(
        referencingDestination destinationID: UUID,
        states: [CaptureInboxState]
    ) throws -> [UUID] {
        try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            var ids: [UUID] = []
            for state in states {
                for url in try itemURLs(in: state) {
                    guard let request = try? decoder.decode(
                        CaptureRequest.self,
                        from: Data(contentsOf: url)
                    ), request.destinationID == destinationID else { continue }
                    ids.append(request.id)
                }
            }
            return ids
        }
    }

    /// Rewrites durable requests before a destination is removed. Completed
    /// receipts and actively processing jobs are omitted unless explicitly
    /// supplied by the caller.
    @discardableResult
    public func rerouteRequests(
        from sourceDestinationID: UUID,
        to destinationID: UUID,
        states: [CaptureInboxState]
    ) throws -> [UUID] {
        try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            var rerouted: [UUID] = []
            for state in states {
                for url in try itemURLs(in: state) {
                    guard var request = try? decoder.decode(
                        CaptureRequest.self,
                        from: Data(contentsOf: url)
                    ), request.destinationID == sourceDestinationID else { continue }
                    request.destinationID = destinationID
                    try encoder.encode(request).write(to: url, options: .atomic)
                    rerouted.append(request.id)
                }
            }
            return rerouted
        }
    }

    /// Rehomes requests left behind by destinations removed by older app
    /// versions, while preserving requests that still point at valid routes.
    @discardableResult
    public func rerouteOrphanedRequests(
        validDestinationIDs: Set<UUID>,
        to destinationID: UUID,
        states: [CaptureInboxState]
    ) throws -> [UUID] {
        try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            var rerouted: [UUID] = []
            for state in states {
                for url in try itemURLs(in: state) {
                    guard var request = try? decoder.decode(
                        CaptureRequest.self,
                        from: Data(contentsOf: url)
                    ), !validDestinationIDs.contains(request.destinationID) else { continue }
                    request.destinationID = destinationID
                    try encoder.encode(request).write(to: url, options: .atomic)
                    rerouted.append(request.id)
                }
            }
            return rerouted
        }
    }

    public func state(of requestID: UUID) throws -> CaptureInboxState? {
        try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            return CaptureInboxState.allCases.first {
                fileManager.fileExists(atPath: itemURL(for: requestID, state: $0).path)
            }
        }
    }

    /// Applies an explicit decision to the exact durable request without
    /// changing its preset snapshot or location outcome. No acquisition occurs.
    @discardableResult
    public func sendWithoutLocation(requestID: UUID) throws -> Bool {
        try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            for state in [CaptureInboxState.pending, .failed] {
                let url = itemURL(for: requestID, state: state)
                guard fileManager.fileExists(atPath: url.path),
                      var request = try? decoder.decode(
                        CaptureRequest.self,
                        from: Data(contentsOf: url)
                      ) else { continue }
                request.locationDecisionOverride = .sendWithoutLocation
                try encoder.encode(request).write(to: url, options: .atomic)
                if state == .failed {
                    let pendingURL = itemURL(for: requestID, state: .pending)
                    if fileManager.fileExists(atPath: pendingURL.path) {
                        try fileManager.removeItem(at: url)
                    } else {
                        try fileManager.moveItem(at: url, to: pendingURL)
                    }
                }
                return true
            }
            return false
        }
    }

    /// Loads a private durable request only for foreground decision UI. Callers
    /// must not copy it into history or completed tombstones.
    public func request(requestID: UUID, states: [CaptureInboxState]) throws -> CaptureRequest? {
        try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            for state in states where state != .completed {
                let url = itemURL(for: requestID, state: state)
                guard fileManager.fileExists(atPath: url.path) else { continue }
                return try decoder.decode(CaptureRequest.self, from: Data(contentsOf: url))
            }
            return nil
        }
    }

    @discardableResult
    public func retryFailed(requestID: UUID) throws -> Bool {
        try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            let failedURL = itemURL(for: requestID, state: .failed)
            guard fileManager.fileExists(atPath: failedURL.path) else { return false }
            let pendingURL = itemURL(for: requestID, state: .pending)
            if fileManager.fileExists(atPath: pendingURL.path) {
                try fileManager.removeItem(at: failedURL)
            } else {
                try fileManager.moveItem(at: failedURL, to: pendingURL)
            }
            return true
        }
    }

    @discardableResult
    public func retryAllFailed() throws -> [UUID] {
        try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            var retried: [UUID] = []
            for failedURL in try itemURLs(in: .failed) {
                guard let request = try? decoder.decode(
                    CaptureRequest.self,
                    from: Data(contentsOf: failedURL)
                ) else { continue }
                let pendingURL = itemURL(for: request.id, state: .pending)
                if fileManager.fileExists(atPath: pendingURL.path) {
                    try fileManager.removeItem(at: failedURL)
                } else {
                    try fileManager.moveItem(at: failedURL, to: pendingURL)
                }
                retried.append(request.id)
            }
            return retried
        }
    }

    /// Permanently removes a request that has not begun or has already failed.
    /// Active processing and completed receipts are never removed. This lets a
    /// user discard a failed Watch recording without a queued request delivering
    /// later behind their back.
    @discardableResult
    public func discard(requestID: UUID) throws -> Bool {
        let didDiscard = try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            let processingURL = itemURL(for: requestID, state: .processing)
            let completedURL = itemURL(for: requestID, state: .completed)
            guard !fileManager.fileExists(atPath: processingURL.path),
                  !fileManager.fileExists(atPath: completedURL.path) else {
                return false
            }

            var removed = false
            for state in [CaptureInboxState.pending, .failed] {
                let url = itemURL(for: requestID, state: state)
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                    removed = true
                }
            }
            return removed
        }

        if didDiscard {
            let stagingURL = rootDirectoryURL
                .appendingPathComponent("inbox-staging", isDirectory: true)
                .appendingPathComponent(requestID.uuidString.lowercased(), isDirectory: true)
            try? fileManager.removeItem(at: stagingURL)
        }
        return didDiscard
    }

    /// Removes abandoned staging directories only after a grace period and
    /// only when no live pending/processing/failed request references them.
    /// This cleans up extension or intent crashes that happen before enqueue.
    @discardableResult
    public func purgeOrphanedStaging(
        olderThan retentionInterval: TimeInterval,
        now: Date = Date()
    ) throws -> [UUID] {
        try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            var referenced = Set<UUID>()
            for state in [CaptureInboxState.pending, .processing, .failed] {
                for url in try itemURLs(in: state) {
                    if let request = try? decoder.decode(
                        CaptureRequest.self,
                        from: Data(contentsOf: url)
                    ) {
                        referenced.insert(request.id)
                    }
                }
            }

            let stagingRoot = rootDirectoryURL.appendingPathComponent("inbox-staging", isDirectory: true)
            guard fileManager.fileExists(atPath: stagingRoot.path) else { return [] }
            let directories = try fileManager.contentsOfDirectory(
                at: stagingRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            var purged: [UUID] = []
            for directory in directories {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                guard values.isDirectory == true,
                      let id = UUID(uuidString: directory.lastPathComponent),
                      !referenced.contains(id),
                      now.timeIntervalSince(values.contentModificationDate ?? .distantPast) >= retentionInterval else {
                    continue
                }
                try fileManager.removeItem(at: directory)
                purged.append(id)
            }
            return purged.sorted { $0.uuidString < $1.uuidString }
        }
    }

    @discardableResult
    public func purgeCompleted(
        olderThan retentionInterval: TimeInterval,
        now: Date = Date()
    ) throws -> [UUID] {
        try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            var purged: [UUID] = []
            for completedURL in try itemURLs(in: .completed) {
                let values = try completedURL.resourceValues(forKeys: [.contentModificationDateKey])
                let modificationDate = values.contentModificationDate ?? .distantPast
                guard now.timeIntervalSince(modificationDate) >= retentionInterval else { continue }
                let requestID = completionRequestID(for: completedURL)
                try fileManager.removeItem(at: completedURL)
                if let requestID { purged.append(requestID) }
            }
            return purged
        }
    }

    @discardableResult
    public func recoverStaleProcessing(
        olderThan timeout: TimeInterval,
        now: Date = Date()
    ) throws -> [UUID] {
        try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            var recovered: [UUID] = []
            for processingURL in try itemURLs(in: .processing) {
                let values = try processingURL.resourceValues(forKeys: [.contentModificationDateKey])
                let modificationDate = values.contentModificationDate ?? .distantPast
                guard now.timeIntervalSince(modificationDate) >= timeout else { continue }
                if let requestID = completionRequestID(for: processingURL),
                   fileManager.fileExists(atPath: itemURL(for: requestID, state: .completed).path) {
                    // `complete` writes its tombstone before deleting processing.
                    // A crash between those operations must never redeliver.
                    try fileManager.removeItem(at: processingURL)
                    continue
                }
                guard let request = try? decoder.decode(
                    CaptureRequest.self,
                    from: Data(contentsOf: processingURL)
                ) else {
                    let failedURL = stateDirectoryURL(.failed).appendingPathComponent(processingURL.lastPathComponent)
                    if fileManager.fileExists(atPath: failedURL.path) {
                        try fileManager.removeItem(at: processingURL)
                    } else {
                        try fileManager.moveItem(at: processingURL, to: failedURL)
                    }
                    continue
                }
                let pendingURL = itemURL(for: request.id, state: .pending)
                if fileManager.fileExists(atPath: pendingURL.path) {
                    try fileManager.removeItem(at: processingURL)
                } else {
                    try fileManager.moveItem(at: processingURL, to: pendingURL)
                }
                recovered.append(request.id)
            }
            return recovered
        }
    }

    public nonisolated func itemURL(for requestID: UUID, state: CaptureInboxState) -> URL {
        stateDirectoryURL(state)
            .appendingPathComponent(requestID.uuidString.lowercased())
            .appendingPathExtension("json")
    }

    private func claimPendingURL(_ pendingURL: URL) throws -> CaptureRequest? {
        let processingURL = stateDirectoryURL(.processing).appendingPathComponent(pendingURL.lastPathComponent)
        do {
            try fileManager.moveItem(at: pendingURL, to: processingURL)
        } catch CocoaError.fileNoSuchFile {
            return nil
        }
        do {
            // Moving a file preserves its old modification date. Refresh the
            // processing lease so stale recovery measures active work, not
            // time spent waiting in the pending queue.
            try fileManager.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: processingURL.path
            )
            return try decoder.decode(CaptureRequest.self, from: Data(contentsOf: processingURL))
        } catch {
            let failedURL = stateDirectoryURL(.failed).appendingPathComponent(processingURL.lastPathComponent)
            if fileManager.fileExists(atPath: failedURL.path) {
                try fileManager.removeItem(at: processingURL)
            } else {
                try fileManager.moveItem(at: processingURL, to: failedURL)
            }
            return nil
        }
    }

    private func transition(
        requestID: UUID,
        from sourceState: CaptureInboxState,
        to destinationState: CaptureInboxState
    ) throws {
        try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            let sourceURL = itemURL(for: requestID, state: sourceState)
            let destinationURL = itemURL(for: requestID, state: destinationState)
            if fileManager.fileExists(atPath: destinationURL.path) {
                if fileManager.fileExists(atPath: sourceURL.path) {
                    try fileManager.removeItem(at: sourceURL)
                }
                return
            }
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw CaptureInboxError.requestNotProcessing(requestID)
            }
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    private nonisolated func stateDirectoryURL(_ state: CaptureInboxState) -> URL {
        rootDirectoryURL
            .appendingPathComponent("capture-inbox", isDirectory: true)
            .appendingPathComponent(state.rawValue, isDirectory: true)
    }

    private func ensureDirectories() throws {
        for state in CaptureInboxState.allCases {
            try fileManager.createDirectory(
                at: stateDirectoryURL(state),
                withIntermediateDirectories: true
            )
        }
        try sanitizeLegacyCompletedRequests()
    }

    /// Previous releases moved the complete request JSON into `completed`.
    /// Replace those payload-bearing files on first access so upgrading users
    /// do not continue retaining delivered private content for the old grace
    /// period. Invalid completed filenames are removed because they cannot be
    /// useful idempotency tombstones.
    private func sanitizeLegacyCompletedRequests() throws {
        let completedDirectory = stateDirectoryURL(.completed)
        let urls = try fileManager.contentsOfDirectory(
            at: completedDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }

        for url in urls {
            guard let requestID = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                try fileManager.removeItem(at: url)
                continue
            }
            if let receipt = try? decoder.decode(
                CaptureCompletionReceipt.self,
                from: Data(contentsOf: url)
            ), receipt.schemaVersion == CaptureCompletionReceipt.currentSchemaVersion,
               receipt.requestID == requestID {
                continue
            }
            let completedAt = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? Date()
            try encoder.encode(CaptureCompletionReceipt(
                requestID: requestID,
                completedAt: completedAt
            )).write(to: url, options: .atomic)
        }
    }

    private func completionRequestID(for url: URL) -> UUID? {
        if let receipt = try? decoder.decode(
            CaptureCompletionReceipt.self,
            from: Data(contentsOf: url)
        ), receipt.schemaVersion == CaptureCompletionReceipt.currentSchemaVersion {
            return receipt.requestID
        }
        return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    private func itemURLs(in state: CaptureInboxState) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: stateDirectoryURL(state),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .map { url in
            let request = state == .completed
                ? nil
                : try? decoder.decode(CaptureRequest.self, from: Data(contentsOf: url))
            let receipt = state == .completed
                ? try? decoder.decode(CaptureCompletionReceipt.self, from: Data(contentsOf: url))
                : nil
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (
                url: url,
                createdAt: request?.createdAt ?? receipt?.completedAt ?? modified ?? .distantPast,
                id: request?.id.uuidString ?? receipt?.requestID.uuidString ?? url.lastPathComponent
            )
        }
        .sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt < $1.createdAt
        }
        .map(\.url)
    }
}
