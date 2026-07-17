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

public struct CaptureDraft: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var requestID: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var text: String
    public var destinationID: UUID?
    /// Entry-point provenance retained with the durable draft so history stays
    /// accurate even when the app is suspended before the user submits.
    public var captureSource: CaptureSource?
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
        destinationID: UUID? = nil,
        captureSource: CaptureSource? = nil,
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
        self.destinationID = destinationID
        self.captureSource = captureSource
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
        guard destinationID != id else { return }
        destinationID = id
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
            destinationID: destinationID,
            captureSource: captureSource,
            placementOverride: placementOverride,
            relativeNotePathOverride: relativeNotePathOverride,
            entryTemplateID: entryTemplateID,
            additionalPayloads: residualPayloads
        )
    }

    public func makeRequest(source: CaptureSource) throws -> CaptureRequest {
        guard let destinationID else { throw CaptureDraftError.destinationRequired }
        var payloads: [CapturePayload] = []
        let boundaryTrimmedText = text.trimmingCharacters(in: .newlines)
        if !boundaryTrimmedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payloads.append(.text(boundaryTrimmedText))
        }
        payloads.append(contentsOf: additionalPayloads)
        return CaptureRequest(
            id: requestID,
            createdAt: createdAt,
            source: captureSource ?? source,
            destinationID: destinationID,
            payloads: payloads
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

    public func stagingDirectoryURL(for draftID: UUID) -> URL {
        stagingRootURL.appendingPathComponent(draftID.uuidString.lowercased(), isDirectory: true)
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
