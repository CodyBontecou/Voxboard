import Foundation

public enum CaptureDraftError: Error, Equatable, LocalizedError, Sendable {
    case draftNotFound(UUID)
    case destinationRequired

    public var errorDescription: String? {
        switch self {
        case .draftNotFound(let id):
            return "Capture draft \(id.uuidString) was not found."
        case .destinationRequired:
            return "Configure a destination for this Capture Preset before capturing."
        }
    }
}

public enum CaptureDestinationSelectionMode: String, Codable, Sendable {
    /// Resolve through the selected Capture Preset. The library default is
    /// retained only as a compatibility fallback for pre-migration drafts.
    case inherited
    /// Preserve the destination explicitly chosen for this draft.
    case explicit
}

public struct CaptureDraft: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var requestID: UUID
    public var createdAt: Date
    public var updatedAt: Date
    /// The effective capture time, assigned once when substantive durable
    /// content first enters an allocated draft. `createdAt` remains the draft
    /// allocation time for backward-compatible persistence.
    public private(set) var captureStartedAt: Date?
    public var text: String
    /// The reusable capture workflow selected for this durable draft.
    public var voxID: String?
    /// Immutable Preset policy paired with an origin-time location outcome.
    /// Once a Send/import attempt resolves location, retries must not combine
    /// that older outcome with later edits to the same Preset ID.
    public var voxProfileSnapshot: CapturePresetProfile?
    /// `destinationID` is authoritative only for explicit selection. Inherited
    /// drafts resolve the selected Capture Preset at display and submission time.
    public var destinationSelectionMode: CaptureDestinationSelectionMode
    public var destinationID: UUID?
    /// Entry-point provenance retained with the durable draft so history stays
    /// accurate even when the app is suspended before the user submits.
    public var captureSource: CaptureSource?
    /// Origin-time result journaled as soon as a Send attempt resolves it. This
    /// closes the suspension/crash window before preset processing and delivery.
    public var locationOutcome: CaptureLocationOutcome?
    /// Request-scoped choice made for a durable unavailable outcome.
    public var locationDecisionOverride: CaptureLocationDecisionOverride?
    /// Set only after a successful transcription has already consumed the
    /// independent minute allowance for this draft.
    public var deliveryKind: CaptureDeliveryKind
    public var placementOverride: CapturePlacement?
    /// A capture-scoped existing Markdown note relative to the selected
    /// destination root. This never mutates the reusable destination.
    public var relativeNotePathOverride: String?
    public var entryTemplateID: UUID?
    public var additionalPayloads: [CapturePayload]
    /// Idempotency receipts for queued recording delivery. Optional so drafts
    /// written by older releases continue to decode without migration.
    public var stagedRecordingAudioReceipts: [String: CaptureAssetReference]?
    public var appliedRecordingTranscriptIDs: [UUID]?

    public init(
        id: UUID = UUID(),
        requestID: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        captureStartedAt: Date? = nil,
        text: String = "",
        voxID: String? = nil,
        voxProfileSnapshot: CapturePresetProfile? = nil,
        destinationSelectionMode: CaptureDestinationSelectionMode? = nil,
        destinationID: UUID? = nil,
        captureSource: CaptureSource? = nil,
        locationOutcome: CaptureLocationOutcome? = nil,
        locationDecisionOverride: CaptureLocationDecisionOverride? = nil,
        deliveryKind: CaptureDeliveryKind = .standard,
        placementOverride: CapturePlacement? = nil,
        relativeNotePathOverride: String? = nil,
        entryTemplateID: UUID? = nil,
        additionalPayloads: [CapturePayload] = [],
        stagedRecordingAudioReceipts: [String: CaptureAssetReference]? = nil,
        appliedRecordingTranscriptIDs: [UUID]? = nil
    ) {
        self.id = id
        self.requestID = requestID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.text = text
        self.captureStartedAt = captureStartedAt
        if self.captureStartedAt == nil,
           (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !additionalPayloads.isEmpty) {
            self.captureStartedAt = createdAt
        }
        self.voxID = voxID
        self.voxProfileSnapshot = voxProfileSnapshot
        self.destinationSelectionMode = destinationSelectionMode
            ?? (destinationID == nil ? .inherited : .explicit)
        self.destinationID = destinationID
        self.captureSource = captureSource
        self.locationOutcome = locationOutcome
        self.locationDecisionOverride = locationDecisionOverride
        self.deliveryKind = deliveryKind
        self.placementOverride = placementOverride
        self.relativeNotePathOverride = relativeNotePathOverride
        self.entryTemplateID = entryTemplateID
        self.additionalPayloads = additionalPayloads
        self.stagedRecordingAudioReceipts = stagedRecordingAudioReceipts
        self.appliedRecordingTranscriptIDs = appliedRecordingTranscriptIDs
    }

    public var hasCaptureContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !additionalPayloads.isEmpty
    }

    /// The timestamp used by requests and date-based destination formatting.
    /// Empty legacy drafts have no start time until substantive content arrives.
    public var effectiveCreatedAt: Date {
        captureStartedAt ?? createdAt
    }

    /// Starts an allocated draft exactly once, and only for substantive content.
    /// Route changes, provenance, and whitespace-only edits do not start it.
    @discardableResult
    public mutating func beginCaptureIfNeeded(at date: Date = Date()) -> Bool {
        guard captureStartedAt == nil, hasCaptureContent else { return false }
        captureStartedAt = date
        return true
    }

    /// Carries an already-durable lifecycle transition into a concurrently
    /// edited in-memory version without refreshing an existing capture time.
    public mutating func preserveCaptureStart(from persistedDraft: CaptureDraft) {
        guard id == persistedDraft.id,
              requestID == persistedDraft.requestID,
              let persistedStart = persistedDraft.captureStartedAt else { return }
        captureStartedAt = persistedStart
    }

    /// Changes the reusable destination without carrying an existing-note
    /// override across vault roots.
    public mutating func selectDestination(_ id: UUID) {
        guard destinationID != id || destinationSelectionMode != .explicit else { return }
        destinationSelectionMode = .explicit
        destinationID = id
        relativeNotePathOverride = nil
    }

    /// Selects a Capture Preset and returns routing to its owned destination.
    public mutating func selectVox(_ id: String) {
        voxID = id
        useInheritedDestination()
        placementOverride = nil
        entryTemplateID = nil
        // A location snapshot belongs to the preset and Send attempt that
        // created it; changing presets must not carry it into a different policy.
        locationOutcome = nil
        locationDecisionOverride = nil
        voxProfileSnapshot = nil
    }

    public mutating func useInheritedDestination() {
        destinationSelectionMode = .inherited
        destinationID = nil
        relativeNotePathOverride = nil
    }

    /// Removes a redundant explicit destination left by older drafts when it
    /// resolves to the same route now owned by the selected Capture Preset.
    /// Capture-scoped note, placement, and template overrides remain intact.
    @discardableResult
    public mutating func inheritDestinationIfEquivalent(to inheritedDestinationID: UUID?) -> Bool {
        guard destinationSelectionMode == .explicit,
              let destinationID,
              destinationID == inheritedDestinationID else { return false }
        destinationSelectionMode = .inherited
        self.destinationID = nil
        return true
    }

    /// Converts a version that changed while an older snapshot was being sent
    /// into a fresh idempotency request. Common append-only edits are reduced
    /// to just their new text/assets; arbitrary rewrites are kept intact so no
    /// user input can disappear.
    public func rebased(afterSubmitting submitted: CaptureDraft, now: Date = Date()) -> CaptureDraft {
        var residualText = text
        if text == submitted.text {
            residualText = ""
        } else if !submitted.text.isEmpty, text.hasPrefix(submitted.text) {
            let suffix = String(text.dropFirst(submitted.text.count))
            if suffix.first?.isNewline == true {
                residualText = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        var residualPayloads = additionalPayloads
        if additionalPayloads.count >= submitted.additionalPayloads.count,
           Array(additionalPayloads.prefix(submitted.additionalPayloads.count)) == submitted.additionalPayloads {
            residualPayloads.removeFirst(submitted.additionalPayloads.count)
        }

        return CaptureDraft(
            id: id,
            requestID: UUID(),
            createdAt: now,
            updatedAt: now,
            text: residualText,
            voxID: voxID,
            destinationSelectionMode: destinationSelectionMode,
            destinationID: destinationID,
            captureSource: captureSource,
            // Concurrent residual edits become a new Capture. They must not
            // inherit a voice exemption from the version already delivered.
            deliveryKind: .standard,
            placementOverride: placementOverride,
            relativeNotePathOverride: relativeNotePathOverride,
            entryTemplateID: entryTemplateID,
            additionalPayloads: residualPayloads
        )
    }

    public func makeRequest(
        source: CaptureSource,
        resolvedDestinationID: UUID? = nil,
        voxProfile: CapturePresetProfile? = nil
    ) throws -> CaptureRequest {
        guard let destinationID = resolvedDestinationID ?? destinationID else {
            throw CaptureDraftError.destinationRequired
        }
        let resolvedVoxProfile = voxProfileSnapshot ?? voxProfile
        var payloads: [CapturePayload] = []
        let boundaryTrimmedText = text.trimmingCharacters(in: .newlines)
        if !boundaryTrimmedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payloads.append(.text(boundaryTrimmedText))
        }
        payloads.append(contentsOf: additionalPayloads)
        let processingState: CapturePresetProcessingState
        if let resolvedVoxProfile {
            processingState = resolvedVoxProfile.captureProcessingEnabled
                && resolvedVoxProfile.postProcessingMode != .none
                && resolvedVoxProfile.resolvedPostProcessingInstruction != nil
                ? .pending
                : .applied
        } else {
            processingState = .notRequested
        }
        return CaptureRequest(
            id: requestID,
            createdAt: effectiveCreatedAt,
            source: captureSource ?? source,
            deliveryKind: deliveryKind,
            destinationID: destinationID,
            payloads: payloads,
            frontmatter: resolvedVoxProfile?.staticFrontmatter ?? [:],
            voxProfile: resolvedVoxProfile,
            voxProcessingState: processingState,
            locationOutcome: locationOutcome,
            locationDecisionOverride: locationDecisionOverride,
            originDraftUpdatedAt: updatedAt,
            relativeNotePathOverride: relativeNotePathOverride,
            placementOverride: placementOverride,
            entryTemplateIDOverride: entryTemplateID
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case requestID
        case createdAt
        case updatedAt
        case captureStartedAt
        case text
        case voxID
        case voxProfileSnapshot
        case destinationSelectionMode
        case destinationID
        case captureSource
        case locationOutcome
        case locationDecisionOverride
        case deliveryKind
        case placementOverride
        case relativeNotePathOverride
        case entryTemplateID
        case additionalPayloads
        case stagedRecordingAudioReceipts
        case appliedRecordingTranscriptIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedDestinationID = try container.decodeIfPresent(UUID.self, forKey: .destinationID)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            requestID: try container.decode(UUID.self, forKey: .requestID),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            captureStartedAt: try container.decodeIfPresent(Date.self, forKey: .captureStartedAt),
            text: try container.decodeIfPresent(String.self, forKey: .text) ?? "",
            voxID: try container.decodeIfPresent(String.self, forKey: .voxID),
            voxProfileSnapshot: try container.decodeIfPresent(
                CapturePresetProfile.self,
                forKey: .voxProfileSnapshot
            ),
            destinationSelectionMode: try container.decodeIfPresent(
                CaptureDestinationSelectionMode.self,
                forKey: .destinationSelectionMode
            ) ?? (decodedDestinationID == nil ? .inherited : .explicit),
            destinationID: decodedDestinationID,
            captureSource: try container.decodeIfPresent(CaptureSource.self, forKey: .captureSource),
            locationOutcome: try container.decodeIfPresent(CaptureLocationOutcome.self, forKey: .locationOutcome),
            locationDecisionOverride: try container.decodeIfPresent(
                CaptureLocationDecisionOverride.self,
                forKey: .locationDecisionOverride
            ),
            deliveryKind: try container.decodeIfPresent(CaptureDeliveryKind.self, forKey: .deliveryKind) ?? .standard,
            placementOverride: try container.decodeIfPresent(CapturePlacement.self, forKey: .placementOverride),
            relativeNotePathOverride: try container.decodeIfPresent(String.self, forKey: .relativeNotePathOverride),
            entryTemplateID: try container.decodeIfPresent(UUID.self, forKey: .entryTemplateID),
            additionalPayloads: try container.decodeIfPresent([CapturePayload].self, forKey: .additionalPayloads) ?? [],
            stagedRecordingAudioReceipts: try container.decodeIfPresent(
                [String: CaptureAssetReference].self,
                forKey: .stagedRecordingAudioReceipts
            ),
            appliedRecordingTranscriptIDs: try container.decodeIfPresent([UUID].self, forKey: .appliedRecordingTranscriptIDs)
        )
    }
}

public enum CapturePreparedRequestReuse {
    /// A prepared request owns its immutable preset snapshot. Live edits to the
    /// same preset ID must not invalidate it and trigger origin reacquisition.
    public static func matches(
        _ request: CaptureRequest,
        draft: CaptureDraft,
        destinationID: UUID,
        presetID: String?
    ) -> Bool {
        request.id == draft.requestID
            && request.originDraftUpdatedAt == draft.updatedAt
            && request.destinationID == destinationID
            && request.voxProfile?.id == presetID
            && request.voxProcessingState != .pending
    }
}

public actor CaptureDraftStore {
    public let rootDirectoryURL: URL
    private let coordinator: any CaptureFileCoordinating
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var draftsDirectoryURL: URL {
        rootDirectoryURL.appendingPathComponent("drafts", isDirectory: true)
    }

    private var stagingRootURL: URL {
        rootDirectoryURL.appendingPathComponent("staging", isDirectory: true)
    }

    private var preparedRequestsDirectoryURL: URL {
        rootDirectoryURL.appendingPathComponent("prepared-requests", isDirectory: true)
    }

    private var corruptDraftsDirectoryURL: URL {
        rootDirectoryURL.appendingPathComponent("drafts-corrupt", isDirectory: true)
    }

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

    @discardableResult
    public func save(_ draft: CaptureDraft, now: Date = Date()) throws -> CaptureDraft {
        var durableDraft = draft
        let url = draftFileURL(for: durableDraft.id)
        try coordinator.coordinateWriting(at: url) { coordinatedURL in
            if fileManager.fileExists(atPath: coordinatedURL.path),
               let persistedDraft = try? decoder.decode(
                   CaptureDraft.self,
                   from: Data(contentsOf: coordinatedURL)
               ) {
                durableDraft.preserveCaptureStart(from: persistedDraft)
            }
            durableDraft.beginCaptureIfNeeded(at: now)
            let data = try encoder.encode(durableDraft)
            try fileManager.createDirectory(
                at: coordinatedURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: coordinatedURL, options: .atomic)
        }
        return durableDraft
    }

    public func load(id: UUID) throws -> CaptureDraft? {
        let url = draftFileURL(for: id)
        return try coordinator.coordinateWriting(at: url) { coordinatedURL in
            guard fileManager.fileExists(atPath: coordinatedURL.path) else { return nil }
            return try decoder.decode(CaptureDraft.self, from: Data(contentsOf: coordinatedURL))
        }
    }

    /// Atomically adds the origin-time decision to the latest copy of a draft
    /// without overwriting text or attachments edited while location resolved.
    @discardableResult
    public func journalLocation(
        draftID: UUID,
        requestID: UUID,
        outcome: CaptureLocationOutcome?,
        decisionOverride: CaptureLocationDecisionOverride?,
        profileSnapshot: CapturePresetProfile? = nil,
        captureSource: CaptureSource? = nil,
        expectedVoxID: String? = nil
    ) throws -> CaptureDraft {
        guard var draft = try load(id: draftID),
              draft.requestID == requestID,
              expectedVoxID == nil || draft.voxID == expectedVoxID else {
            throw CaptureDraftError.draftNotFound(draftID)
        }
        draft.locationOutcome = outcome
        draft.locationDecisionOverride = decisionOverride
        if let profileSnapshot { draft.voxProfileSnapshot = profileSnapshot }
        if let captureSource { draft.captureSource = captureSource }
        try save(draft)
        return draft
    }

    /// Removes an abandoned import's origin journal without overwriting any
    /// text or attachments added concurrently to the draft.
    @discardableResult
    public func clearLocationJournal(
        draftID: UUID,
        requestID: UUID,
        captureSource: CaptureSource? = nil,
        expectedProfileID: String? = nil
    ) throws -> CaptureDraft {
        guard var draft = try load(id: draftID), draft.requestID == requestID else {
            throw CaptureDraftError.draftNotFound(draftID)
        }
        if let expectedProfileID,
           (draft.voxID != expectedProfileID || draft.voxProfileSnapshot?.id != expectedProfileID) {
            // A stale async import must not erase a newer Preset/location pair.
            return draft
        }
        draft.locationOutcome = nil
        draft.locationDecisionOverride = nil
        draft.voxProfileSnapshot = nil
        if let captureSource, draft.captureSource == captureSource {
            draft.captureSource = nil
        }
        try save(draft)
        return draft
    }

    public func loadAll() throws -> [CaptureDraft] {
        try coordinator.coordinateWriting(at: draftsDirectoryURL) { directoryURL in
            guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
            let urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            var drafts: [CaptureDraft] = []
            for url in urls where url.pathExtension == "json" {
                do {
                    drafts.append(try decoder.decode(
                        CaptureDraft.self,
                        from: Data(contentsOf: url)
                    ))
                } catch {
                    try quarantineCorruptDraft(at: url)
                }
            }
            return drafts.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    public func complete(draftID: UUID) throws {
        let draftURL = draftFileURL(for: draftID)
        try coordinator.coordinateWriting(at: draftURL) { coordinatedURL in
            if fileManager.fileExists(atPath: coordinatedURL.path) {
                try fileManager.removeItem(at: coordinatedURL)
            }
        }
        try? removePreparedRequest(draftID: draftID)
        let stagingURL = stagingDirectoryURL(for: draftID)
        if fileManager.fileExists(atPath: stagingURL.path) {
            // The capture and draft transition are already committed. Do not
            // report a false failure if a provider temporarily refuses local
            // cleanup; abandoned staging is safe to purge later.
            try? fileManager.removeItem(at: stagingURL)
        }
    }

    public func submit<T: Sendable>(
        draftID: UUID,
        operation: @Sendable (CaptureDraft) async throws -> T
    ) async throws -> T {
        guard let draft = try load(id: draftID) else {
            throw CaptureDraftError.draftNotFound(draftID)
        }
        let result = try await operation(draft)

        // Delete only the exact version that was submitted. If the user edited
        // the draft while the operation was in flight, preserve the newer copy.
        if try load(id: draftID) == draft {
            try complete(draftID: draftID)
        }
        return result
    }

    /// Persists the exact Preset-processed request before any destination write.
    /// A failed delivery can therefore retry without rerunning AI or reading
    /// changed Preset settings.
    public func savePreparedRequest(_ request: CaptureRequest, draftID: UUID) throws {
        let url = preparedRequestURL(for: draftID)
        try coordinator.coordinateWriting(at: url) { coordinatedURL in
            try fileManager.createDirectory(
                at: coordinatedURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(request).write(to: coordinatedURL, options: .atomic)
        }
    }

    public func loadPreparedRequest(draftID: UUID) throws -> CaptureRequest? {
        let url = preparedRequestURL(for: draftID)
        return try coordinator.coordinateWriting(at: url) { coordinatedURL in
            guard fileManager.fileExists(atPath: coordinatedURL.path) else { return nil }
            return try decoder.decode(CaptureRequest.self, from: Data(contentsOf: coordinatedURL))
        }
    }

    public func removePreparedRequest(draftID: UUID) throws {
        let url = preparedRequestURL(for: draftID)
        try coordinator.coordinateWriting(at: url) { coordinatedURL in
            if fileManager.fileExists(atPath: coordinatedURL.path) {
                try fileManager.removeItem(at: coordinatedURL)
            }
        }
    }

    public func stagingDirectoryURL(for draftID: UUID) -> URL {
        stagingRootURL.appendingPathComponent(draftID.uuidString.lowercased(), isDirectory: true)
    }

    private func preparedRequestURL(for draftID: UUID) -> URL {
        preparedRequestsDirectoryURL
            .appendingPathComponent(draftID.uuidString.lowercased())
            .appendingPathExtension("json")
    }

    private func draftFileURL(for id: UUID) -> URL {
        draftsDirectoryURL.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("json")
    }

    private func quarantineCorruptDraft(at sourceURL: URL) throws {
        try fileManager.createDirectory(
            at: corruptDraftsDirectoryURL,
            withIntermediateDirectories: true
        )
        var destinationURL = corruptDraftsDirectoryURL
            .appendingPathComponent(sourceURL.lastPathComponent)
        if fileManager.fileExists(atPath: destinationURL.path) {
            destinationURL = corruptDraftsDirectoryURL
                .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent)
                .appendingPathExtension(UUID().uuidString.lowercased() + ".json")
        }
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }
}
