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

    private func destinations() async throws -> [CaptureDestinationEntity] {
        try await CaptureIntentSupport.loadLibrary().destinations.map(CaptureDestinationEntity.init)
    }
}

@available(iOS 17.0, *)
struct CaptureVoxEntity: AppEntity, Identifiable, Hashable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Capture Vox"
    static var defaultQuery = CaptureVoxEntityQuery()

    let id: String
    let name: String
    let symbolName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbolName))
    }

    init(profile: CaptureVoxProfile) {
        id = profile.id
        name = profile.displayName
        symbolName = profile.symbolName
    }
}

@available(iOS 17.0, *)
struct CaptureVoxEntityQuery: EntityQuery, EnumerableEntityQuery {
    func entities(for identifiers: [String]) async throws -> [CaptureVoxEntity] {
        let requested = Set(identifiers)
        return profiles().filter { requested.contains($0.id) }
    }

    func suggestedEntities() async throws -> [CaptureVoxEntity] { profiles() }
    func allEntities() async throws -> [CaptureVoxEntity] { profiles() }

    func defaultResult() async -> CaptureVoxEntity? {
        let selectedID = CaptureVoxProfileStore.selectedProfileID(defaults: AppConstants.sharedDefaults)
        return profiles().first(where: { $0.id == selectedID }) ?? profiles().first
    }

    private func profiles() -> [CaptureVoxEntity] {
        CaptureVoxProfileStore.enabledProfiles(defaults: AppConstants.sharedDefaults)
            .map(CaptureVoxEntity.init(profile:))
    }
}

@available(iOS 17.0, *)
struct CaptureTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Text to Markdown"
    static let description = IntentDescription("Sends text to a configured Markdown or Obsidian destination.")
    static var openAppWhenRun = true

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Vox", description: "The reusable workflow that processes and routes this capture.")
    var vox: CaptureVoxEntity?

    @Parameter(title: "Destination", description: "Optional one-time route override.")
    var destination: CaptureDestinationEntity?

    init() {}

    init(
        text: String,
        vox: CaptureVoxEntity? = nil,
        destination: CaptureDestinationEntity? = nil
    ) {
        self.text = text
        self.vox = vox
        self.destination = destination
    }

    func perform() async throws -> some IntentResult {
        guard text.count <= CaptureInputLimits.maximumTextCharacters else {
            throw CaptureIntentError.textTooLarge
        }
        try await CaptureIntentSupport.enqueue(
            payloads: [.text(text)],
            voxEntity: vox,
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

    @Parameter(title: "Vox", description: "The reusable workflow that processes and routes this capture.")
    var vox: CaptureVoxEntity?

    @Parameter(title: "Destination", description: "Optional one-time route override.")
    var destination: CaptureDestinationEntity?

    init() {}

    init(
        url: URL,
        vox: CaptureVoxEntity? = nil,
        destination: CaptureDestinationEntity? = nil
    ) {
        self.url = url
        self.vox = vox
        self.destination = destination
    }

    func perform() async throws -> some IntentResult {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw CaptureIntentError.invalidURL
        }
        try await CaptureIntentSupport.enqueue(
            payloads: [.url(url, title: nil)],
            voxEntity: vox,
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

    @Parameter(title: "Vox", description: "The reusable workflow that processes and routes this capture.")
    var vox: CaptureVoxEntity?

    @Parameter(title: "Destination", description: "Optional one-time route override.")
    var destination: CaptureDestinationEntity?

    init() {}

    init(
        file: IntentFile,
        vox: CaptureVoxEntity? = nil,
        destination: CaptureDestinationEntity? = nil
    ) {
        self.file = file
        self.vox = vox
        self.destination = destination
    }

    func perform() async throws -> some IntentResult {
        try await CaptureIntentSupport.enqueue(
            file: file,
            voxEntity: vox,
            destinationEntity: destination
        )
        return .result()
    }
}

@available(iOS 17.0, *)
struct OpenQuickCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Quick Capture"
    static let description = IntentDescription("Opens the durable Vox.md quick-capture composer with a reusable Vox workflow.")
    static var openAppWhenRun = true

    @Parameter(title: "Vox")
    var vox: CaptureVoxEntity?

    init() {}

    init(vox: CaptureVoxEntity?) {
        self.vox = vox
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureIntentSupport.requestComposer(voxEntity: vox)
        return .result()
    }
}

@available(iOS 17.0, *)
struct OpenCaptureVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Record a Capture"
    static let description = IntentDescription("Opens Quick Capture and records into the selected Vox entirely on device.")
    static var openAppWhenRun = true

    @Parameter(title: "Vox")
    var vox: CaptureVoxEntity?

    init() {}

    init(vox: CaptureVoxEntity?) {
        self.vox = vox
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureIntentSupport.requestComposer(input: .voice, voxEntity: vox)
        return .result()
    }
}

@available(iOS 17.0, *)
struct OpenCaptureScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture a Screenshot"
    static let description = IntentDescription("Opens Quick Capture and adds screenshots through the selected Vox.")
    static var openAppWhenRun = true

    @Parameter(title: "Vox")
    var vox: CaptureVoxEntity?

    init() {}

    init(vox: CaptureVoxEntity?) {
        self.vox = vox
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureIntentSupport.requestComposer(input: .screenshots, voxEntity: vox)
        return .result()
    }
}

@available(iOS 17.0, *)
enum CaptureIntentSupport {
    static func requestComposer(
        input: CaptureRequestedInput? = nil,
        voxEntity: CaptureVoxEntity? = nil
    ) {
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
        if let voxID = resolvedProfile(for: voxEntity)?.id {
            AppConstants.sharedDefaults?.set(voxID, forKey: CaptureVoxProfileStore.selectedCaptureProfileIDKey)
            AppConstants.sharedDefaults?.set(voxID, forKey: AppConstants.pendingQuickCaptureVoxIdKey)
        } else {
            AppConstants.sharedDefaults?.removeObject(forKey: AppConstants.pendingQuickCaptureVoxIdKey)
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
        voxEntity: CaptureVoxEntity?,
        destinationEntity: CaptureDestinationEntity?,
        requestID: UUID = UUID()
    ) async throws {
        guard let root = AppConstants.captureDirectoryURL else {
            throw CaptureIntentError.storageUnavailable
        }
        let profile = resolvedProfile(for: voxEntity)
        let selectedID = try await selectedDestinationID(
            for: destinationEntity,
            profile: profile
        )
        let processingState: CaptureVoxProcessingState = profile?.captureProcessingEnabled == true
            && profile?.postProcessingMode != CaptureVoxProcessingMode.none
            ? .pending
            : (profile == nil ? .notRequested : .applied)
        let request = CaptureRequest(
            id: requestID,
            source: .shortcut,
            destinationID: selectedID,
            payloads: payloads,
            frontmatter: profile?.staticFrontmatter ?? [:],
            voxProfile: profile,
            voxProcessingState: processingState
        )
        try await CaptureInbox(rootDirectoryURL: root).enqueue(request)
    }

    static func enqueue(
        file: IntentFile,
        voxEntity: CaptureVoxEntity?,
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
                voxEntity: voxEntity,
                destinationEntity: destinationEntity,
                requestID: requestID
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            throw error
        }
    }

    private static func selectedDestinationID(
        for destinationEntity: CaptureDestinationEntity?,
        profile: CaptureVoxProfile?
    ) async throws -> UUID {
        let library = try await loadLibrary()
        RecordingFlowStore.migrateLegacyCaptureBindings(library.legacyFlowBindings)
        var routeProfile = profile
        if routeProfile?.captureDestinationID == nil, let profileID = routeProfile?.id {
            routeProfile?.captureDestinationID = library.legacyFlowBindings[profileID]
        }
        let entityID = destinationEntity.flatMap { UUID(uuidString: $0.destinationIDString) }
        let selectedID = CaptureVoxRouteResolver.destinationID(
            selectionMode: entityID == nil ? .inherited : .explicit,
            explicitDestinationID: entityID,
            profile: routeProfile,
            destinations: library.destinations,
            libraryDefaultDestinationID: library.defaultDestinationID
        )
        guard let selectedID,
              library.destinations.contains(where: { $0.id == selectedID }) else {
            throw CaptureIntentError.destinationRequired
        }
        return selectedID
    }

    private static func resolvedProfile(for entity: CaptureVoxEntity?) -> CaptureVoxProfile? {
        let requestedID = entity?.id
            ?? CaptureVoxProfileStore.selectedProfileID(defaults: AppConstants.sharedDefaults)
        return CaptureVoxProfileStore.profile(
            id: requestedID,
            defaults: AppConstants.sharedDefaults
        )
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
