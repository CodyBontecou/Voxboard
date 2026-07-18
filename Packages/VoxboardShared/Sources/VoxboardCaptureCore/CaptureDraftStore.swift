import Foundation

public enum CaptureDraftError: Error, Equatable, LocalizedError, Sendable {
    case draftNotFound(UUID)
    case destinationRequired

    public var errorDescription: String? {
        switch self {
        case .draftNotFound(let id):
            return "Capture draft \(id.uuidString) was not found."
        case .destinationRequired:
            return "Choose a destination before capturing."
        }
    }
}

public enum CaptureDestinationSelectionMode: String, Codable, Sendable {
    /// Resolve through the selected Vox and then the library default.
    case inherited
    /// Preserve the destination explicitly chosen for this draft.
    case explicit
}

public struct CaptureDraft: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var requestID: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var text: String
    /// The reusable capture workflow selected for this durable draft.
    public var voxID: String?
    /// `destinationID` is authoritative only for explicit selection. Inherited
    /// drafts resolve Vox → library defaults at display and submission time.
    public var destinationSelectionMode: CaptureDestinationSelectionMode
    public var destinationID: UUID?
    /// Entry-point provenance retained with the durable draft so history stays
    /// accurate even when the app is suspended before the user submits.
    public var captureSource: CaptureSource?
    /// Set only after a successful transcription has already consumed the
    /// independent minute allowance for this draft.
    public var deliveryKind: CaptureDeliveryKind
    public var placementOverride: CapturePlacement?
    /// A capture-scoped existing Markdown note relative to the selected
    /// destination root. This never mutates the reusable destination.
    public var relativeNotePathOverride: String?
    public var entryTemplateID: UUID?
    public var additionalPayloads: [CapturePayload]

    public init(
        id: UUID = UUID(),
        requestID: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        text: String = "",
        voxID: String? = nil,
        destinationSelectionMode: CaptureDestinationSelectionMode? = nil,
        destinationID: UUID? = nil,
        captureSource: CaptureSource? = nil,
        deliveryKind: CaptureDeliveryKind = .standard,
        placementOverride: CapturePlacement? = nil,
        relativeNotePathOverride: String? = nil,
        entryTemplateID: UUID? = nil,
        additionalPayloads: [CapturePayload] = []
    ) {
        self.id = id
        self.requestID = requestID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.text = text
        self.voxID = voxID
        self.destinationSelectionMode = destinationSelectionMode
            ?? (destinationID == nil ? .inherited : .explicit)
        self.destinationID = destinationID
        self.captureSource = captureSource
        self.deliveryKind = deliveryKind
        self.placementOverride = placementOverride
        self.relativeNotePathOverride = relativeNotePathOverride
        self.entryTemplateID = entryTemplateID
        self.additionalPayloads = additionalPayloads
    }

    public var hasCaptureContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !additionalPayloads.isEmpty
    }

    /// Changes the reusable destination without carrying an existing-note
    /// override across vault roots.
    public mutating func selectDestination(_ id: UUID) {
        guard destinationID != id || destinationSelectionMode != .explicit else { return }
        destinationSelectionMode = .explicit
        destinationID = id
        relativeNotePathOverride = nil
    }

    /// Selects a workflow and returns routing to that Vox's inherited defaults.
    public mutating func selectVox(_ id: String) {
        voxID = id
        useInheritedDestination()
        placementOverride = nil
        entryTemplateID = nil
    }

    public mutating func useInheritedDestination() {
        destinationSelectionMode = .inherited
        destinationID = nil
        relativeNotePathOverride = nil
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
        voxProfile: CaptureVoxProfile? = nil
    ) throws -> CaptureRequest {
        guard let destinationID = resolvedDestinationID ?? destinationID else {
            throw CaptureDraftError.destinationRequired
        }
        var payloads: [CapturePayload] = []
        let boundaryTrimmedText = text.trimmingCharacters(in: .newlines)
        if !boundaryTrimmedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payloads.append(.text(boundaryTrimmedText))
        }
        payloads.append(contentsOf: additionalPayloads)
        let processingState: CaptureVoxProcessingState
        if let voxProfile {
            processingState = voxProfile.captureProcessingEnabled
                && voxProfile.postProcessingMode != .none
                && voxProfile.resolvedPostProcessingInstruction != nil
                ? .pending
                : .applied
        } else {
            processingState = .notRequested
        }
        return CaptureRequest(
            id: requestID,
            createdAt: createdAt,
            source: captureSource ?? source,
            deliveryKind: deliveryKind,
            destinationID: destinationID,
            payloads: payloads,
            frontmatter: voxProfile?.staticFrontmatter ?? [:],
            voxProfile: voxProfile,
            voxProcessingState: processingState,
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
        case text
        case voxID
        case destinationSelectionMode
        case destinationID
        case captureSource
        case deliveryKind
        case placementOverride
        case relativeNotePathOverride
        case entryTemplateID
        case additionalPayloads
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedDestinationID = try container.decodeIfPresent(UUID.self, forKey: .destinationID)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            requestID: try container.decode(UUID.self, forKey: .requestID),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            text: try container.decodeIfPresent(String.self, forKey: .text) ?? "",
            voxID: try container.decodeIfPresent(String.self, forKey: .voxID),
            destinationSelectionMode: try container.decodeIfPresent(
                CaptureDestinationSelectionMode.self,
                forKey: .destinationSelectionMode
            ) ?? (decodedDestinationID == nil ? .inherited : .explicit),
            destinationID: decodedDestinationID,
            captureSource: try container.decodeIfPresent(CaptureSource.self, forKey: .captureSource),
            deliveryKind: try container.decodeIfPresent(CaptureDeliveryKind.self, forKey: .deliveryKind) ?? .standard,
            placementOverride: try container.decodeIfPresent(CapturePlacement.self, forKey: .placementOverride),
            relativeNotePathOverride: try container.decodeIfPresent(String.self, forKey: .relativeNotePathOverride),
            entryTemplateID: try container.decodeIfPresent(UUID.self, forKey: .entryTemplateID),
            additionalPayloads: try container.decodeIfPresent([CapturePayload].self, forKey: .additionalPayloads) ?? []
        )
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

    public func save(_ draft: CaptureDraft) throws {
        let url = draftFileURL(for: draft.id)
        try coordinator.coordinateWriting(at: url) { coordinatedURL in
            let data = try encoder.encode(draft)
            try fileManager.createDirectory(
                at: coordinatedURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: coordinatedURL, options: .atomic)
        }
    }

    public func load(id: UUID) throws -> CaptureDraft? {
        let url = draftFileURL(for: id)
        return try coordinator.coordinateWriting(at: url) { coordinatedURL in
            guard fileManager.fileExists(atPath: coordinatedURL.path) else { return nil }
            return try decoder.decode(CaptureDraft.self, from: Data(contentsOf: coordinatedURL))
        }
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

    /// Persists the exact Vox-processed request before any destination write.
    /// A failed delivery can therefore retry without rerunning AI or reading
    /// changed Vox settings.
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
