import Foundation

public actor CaptureLibraryStore {
    public static let defaultFilename = "capture-library-v1.json"

    public let fileURL: URL
    private let coordinator: any CaptureFileCoordinating
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL,
        coordinator: any CaptureFileCoordinating = NSFileCoordinatorCaptureFileCoordinator.shared,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.coordinator = coordinator
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func load() throws -> CaptureLibraryEnvelope {
        try coordinator.coordinateWriting(at: fileURL) { coordinatedURL in
            try loadLatest(from: coordinatedURL)
        }
    }

    public func save(_ library: CaptureLibraryEnvelope) throws {
        guard library.schemaVersion == CaptureLibraryEnvelope.currentSchemaVersion else {
            throw CaptureModelError.unsupportedSchemaVersion(library.schemaVersion)
        }
        try coordinator.coordinateWriting(at: fileURL) { coordinatedURL in
            try persist(library, to: coordinatedURL)
        }
    }

    @discardableResult
    public func update(
        _ mutation: (inout CaptureLibraryEnvelope) throws -> Void
    ) throws -> CaptureLibraryEnvelope {
        let (library, _): (CaptureLibraryEnvelope, Void) = try updateReturning { library in
            try mutation(&library)
        }
        return library
    }

    /// Runs a read-modify-write transaction under the same coordinated file
    /// lock and returns a value derived from the exact version that was saved.
    /// This is used when a cross-store migration must commit the file before
    /// publishing matching App Group defaults.
    public func updateReturning<Result: Sendable>(
        _ mutation: (inout CaptureLibraryEnvelope) throws -> Result
    ) throws -> (library: CaptureLibraryEnvelope, result: Result) {
        try coordinator.coordinateWriting(at: fileURL) { coordinatedURL in
            var latest = try loadLatest(from: coordinatedURL)
            let result = try mutation(&latest)
            guard latest.schemaVersion == CaptureLibraryEnvelope.currentSchemaVersion else {
                throw CaptureModelError.unsupportedSchemaVersion(latest.schemaVersion)
            }
            try persist(latest, to: coordinatedURL)
            return (latest, result)
        }
    }

    private func loadLatest(from url: URL) throws -> CaptureLibraryEnvelope {
        guard fileManager.fileExists(atPath: url.path) else {
            return CaptureLibraryEnvelope()
        }
        let data = try Data(contentsOf: url)
        return try CaptureLibraryEnvelope.decodeValidated(from: data, decoder: decoder)
    }

    private func persist(_ library: CaptureLibraryEnvelope, to url: URL) throws {
        let data = try encoder.encode(library)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
