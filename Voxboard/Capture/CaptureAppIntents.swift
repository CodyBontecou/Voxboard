import AppIntents
import Foundation
import UniformTypeIdentifiers
import VoxboardShared

@available(iOS 17.0, *)
struct CaptureDestinationEntity: AppEntity, Identifiable, Hashable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Capture Destination"
    static var defaultQuery = CaptureDestinationEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "folder"))
    }

    var destinationIDString: String { id }

    init(destination: CaptureDestination) {
        id = destination.id.uuidString.lowercased()
        name = destination.name
    }
}

@available(iOS 17.0, *)
struct CaptureDestinationEntityQuery: EntityQuery, EnumerableEntityQuery {
    func entities(for identifiers: [String]) async throws -> [CaptureDestinationEntity] {
        let requested = Set(identifiers)
        return try await destinations().filter { requested.contains($0.id) }
    }

    func suggestedEntities() async throws -> [CaptureDestinationEntity] {
        try await destinations()
    }

    func allEntities() async throws -> [CaptureDestinationEntity] {
        try await destinations()
    }

    func defaultResult() async -> CaptureDestinationEntity? {
        guard let library = try? await CaptureIntentSupport.loadLibrary(),
              let id = library.defaultDestinationID,
              let destination = library.destinations.first(where: { $0.id == id }) else {
            return nil
        }
        return CaptureDestinationEntity(destination: destination)
    }

    private func destinations() async throws -> [CaptureDestinationEntity] {
        try await CaptureIntentSupport.loadLibrary().destinations.map(CaptureDestinationEntity.init)
    }
}

@available(iOS 17.0, *)
struct CaptureTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Text to Markdown"
    static let description = IntentDescription("Sends text to a configured Markdown or Obsidian destination.")
    static var openAppWhenRun = true

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Destination")
    var destination: CaptureDestinationEntity?

    init() {}

    init(text: String, destination: CaptureDestinationEntity? = nil) {
        self.text = text
        self.destination = destination
    }

    func perform() async throws -> some IntentResult {
        guard text.count <= CaptureInputLimits.maximumTextCharacters else {
            throw CaptureIntentError.textTooLarge
        }
        try await CaptureIntentSupport.enqueue(
            payloads: [.text(text)],
            destinationEntity: destination
        )
        return .result()
    }
}

@available(iOS 17.0, *)
struct CaptureURLIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Link to Markdown"
    static let description = IntentDescription("Sends a web link to a configured Markdown or Obsidian destination.")
    static var openAppWhenRun = true

    @Parameter(title: "URL")
    var url: URL

    @Parameter(title: "Destination")
    var destination: CaptureDestinationEntity?

    init() {}

    init(url: URL, destination: CaptureDestinationEntity? = nil) {
        self.url = url
        self.destination = destination
    }

    func perform() async throws -> some IntentResult {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw CaptureIntentError.invalidURL
        }
        try await CaptureIntentSupport.enqueue(
            payloads: [.url(url, title: nil)],
            destinationEntity: destination
        )
        return .result()
    }
}

@available(iOS 17.0, *)
struct CaptureFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture File to Markdown"
    static let description = IntentDescription("Copies a file or image into a configured local Markdown destination.")
    static var openAppWhenRun = true

    @Parameter(title: "File")
    var file: IntentFile

    @Parameter(title: "Destination")
    var destination: CaptureDestinationEntity?

    init() {}

    init(file: IntentFile, destination: CaptureDestinationEntity? = nil) {
        self.file = file
        self.destination = destination
    }

    func perform() async throws -> some IntentResult {
        try await CaptureIntentSupport.enqueue(file: file, destinationEntity: destination)
        return .result()
    }
}

@available(iOS 17.0, *)
struct OpenQuickCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Quick Capture"
    static let description = IntentDescription("Opens the durable Vox.md quick-capture composer.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureIntentSupport.requestComposer()
        return .result()
    }
}

@available(iOS 17.0, *)
struct OpenCaptureVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Record a Capture"
    static let description = IntentDescription("Opens Quick Capture and starts a voice attachment entirely on device.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureIntentSupport.requestComposer(input: .voice)
        return .result()
    }
}

@available(iOS 17.0, *)
struct OpenCaptureScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture a Screenshot"
    static let description = IntentDescription("Opens Quick Capture and shows screenshots you can add to Markdown.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureIntentSupport.requestComposer(input: .screenshots)
        return .result()
    }
}

@available(iOS 17.0, *)
enum CaptureIntentSupport {
    static func requestComposer(input: CaptureRequestedInput? = nil) {
        AppConstants.sharedDefaults?.set(true, forKey: AppConstants.pendingQuickCaptureOpenKey)
        AppConstants.sharedDefaults?.set(
            CaptureSource.shortcut.rawValue,
            forKey: AppConstants.pendingQuickCaptureSourceKey
        )
        if let input {
            AppConstants.sharedDefaults?.set(input.rawValue, forKey: AppConstants.pendingQuickCaptureInputKey)
        } else {
            AppConstants.sharedDefaults?.removeObject(forKey: AppConstants.pendingQuickCaptureInputKey)
        }
    }

    static func loadLibrary() async throws -> CaptureLibraryEnvelope {
        guard let url = AppConstants.captureLibraryURL else {
            throw CaptureIntentError.storageUnavailable
        }
        return try await CaptureLibraryStore(fileURL: url).load()
    }

    static func enqueue(
        payloads: [CapturePayload],
        destinationEntity: CaptureDestinationEntity?,
        requestID: UUID = UUID()
    ) async throws {
        guard let root = AppConstants.captureDirectoryURL else {
            throw CaptureIntentError.storageUnavailable
        }
        let selectedID = try await selectedDestinationID(for: destinationEntity)
        let request = CaptureRequest(
            id: requestID,
            source: .shortcut,
            destinationID: selectedID,
            payloads: payloads
        )
        try await CaptureInbox(rootDirectoryURL: root).enqueue(request)
    }

    static func enqueue(
        file: IntentFile,
        destinationEntity: CaptureDestinationEntity?
    ) async throws {
        guard let root = AppConstants.captureDirectoryURL else {
            throw CaptureIntentError.storageUnavailable
        }
        let requestID = UUID()
        let relativeDirectory = "inbox-staging/\(requestID.uuidString.lowercased())"
        let stagingDirectory = root.appendingPathComponent(relativeDirectory, isDirectory: true)
        do {
            let type = file.type ?? UTType(filenameExtension: (file.filename as NSString).pathExtension) ?? .data
            let staged = try await CaptureAssetStager(directoryURL: stagingDirectory).stage(
                data: file.data,
                preferredFilename: file.filename,
                contentTypeIdentifier: type.identifier
            )
            let asset = try CaptureAssetReference(
                relativePath: "\(relativeDirectory)/\(staged.relativePath)",
                originalFilename: staged.originalFilename,
                contentTypeIdentifier: staged.contentTypeIdentifier,
                byteCount: staged.byteCount
            )
            let payload: CapturePayload
            if type.conforms(to: .image) {
                payload = .image(asset, altText: nil)
            } else if type.conforms(to: .audio) {
                payload = .audio(asset, transcript: nil)
            } else {
                payload = .file(asset)
            }
            try await enqueue(
                payloads: [payload],
                destinationEntity: destinationEntity,
                requestID: requestID
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            throw error
        }
    }

    private static func selectedDestinationID(
        for destinationEntity: CaptureDestinationEntity?
    ) async throws -> UUID {
        let library = try await loadLibrary()
        let entityID = destinationEntity.flatMap { UUID(uuidString: $0.destinationIDString) }
        let selectedID = entityID
            ?? library.defaultDestinationID
            ?? library.destinations.first?.id
        guard let selectedID,
              library.destinations.contains(where: { $0.id == selectedID }) else {
            throw CaptureIntentError.destinationRequired
        }
        return selectedID
    }
}

@available(iOS 17.0, *)
enum CaptureIntentError: Error, LocalizedError {
    case storageUnavailable
    case destinationRequired
    case invalidURL
    case textTooLarge

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return "Vox.md shared capture storage is unavailable."
        case .destinationRequired:
            return "Add a capture destination in Vox.md before running this shortcut."
        case .invalidURL:
            return "Only HTTP and HTTPS links can be captured."
        case .textTooLarge:
            return "Capture text is above the 100,000-character safety limit."
        }
    }
}
