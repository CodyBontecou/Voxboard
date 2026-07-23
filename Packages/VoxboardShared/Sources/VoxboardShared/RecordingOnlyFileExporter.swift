import Foundation
import VoxboardCaptureCore

public struct RecordingOnlyFileExportContext: Equatable, Sendable {
    public var recordingID: String
    public var createdAt: Date
    public var presetName: String
    public var originalFilename: String

    public init(
        recordingID: String,
        createdAt: Date,
        presetName: String,
        originalFilename: String
    ) {
        self.recordingID = recordingID
        self.createdAt = createdAt
        self.presetName = presetName
        self.originalFilename = originalFilename
    }
}

public struct RecordingOnlyFileExportReceipt: Equatable, Sendable {
    public var fileURL: URL
    public var filename: String
    public var byteCount: Int
    public var wasAlreadyDelivered: Bool

    public init(
        fileURL: URL,
        filename: String,
        byteCount: Int,
        wasAlreadyDelivered: Bool
    ) {
        self.fileURL = fileURL
        self.filename = filename
        self.byteCount = byteCount
        self.wasAlreadyDelivered = wasAlreadyDelivered
    }
}

public enum RecordingOnlyFileExportError: Error, Equatable, LocalizedError, Sendable {
    case folderNotConfigured
    case invalidFolderBookmark
    case staleFolderBookmark(String)
    case destinationIsNotFolder(String)
    case invalidReservedFilename
    case filenameConflict
    case sourceMissing
    case unsupportedSourceFormat
    case copyVerificationFailed

    public var errorDescription: String? {
        switch self {
        case .folderNotConfigured:
            return "Choose a Recording Folder in this Capture Preset on iPhone, then retry."
        case .invalidFolderBookmark:
            return "The Recording Folder permission is unavailable. Choose the folder again, then retry."
        case .staleFolderBookmark(let name):
            return "The Files permission for ‘\(name)’ expired. Choose the Recording Folder again, then retry."
        case .destinationIsNotFolder(let name):
            return "‘\(name)’ is not an available Files folder. Choose the Recording Folder again."
        case .invalidReservedFilename:
            return "The recording filename could not be prepared safely."
        case .filenameConflict:
            return "Another file claimed the recording filename. Retrying will choose a new name."
        case .sourceMissing:
            return "The retained Apple Watch recording is missing."
        case .unsupportedSourceFormat:
            return "The retained Apple Watch recording is not an M4A file."
        case .copyVerificationFailed:
            return "The recording could not be verified after it was copied to Files."
        }
    }
}

/// Copies a Watch recording byte-for-byte into a user-selected Files folder.
/// The caller keeps the durable WatchInbox source until this exporter returns a
/// verified receipt and the inbox terminal state has been persisted.
public struct RecordingOnlyFileExporter: @unchecked Sendable {
    private static let invalidFilenameCharacters = CharacterSet(
        charactersIn: "/\\?%*|\"<>:\n\r\t"
    ).union(.controlCharacters)

    private let coordinator: any CaptureFileCoordinating
    private let fileManager: FileManager

    public init(
        coordinator: any CaptureFileCoordinating = NSFileCoordinatorCaptureFileCoordinator.shared,
        fileManager: FileManager = .default
    ) {
        self.coordinator = coordinator
        self.fileManager = fileManager
    }

    /// Resolves and validates the persisted folder permission without writing.
    @discardableResult
    public func validateDestination(
        settings: CapturePresetWatchRecordingSettings
    ) throws -> URL {
        let folderURL = try resolveFolder(settings: settings)
        return try withSecurityScope(for: folderURL) {
            let values = try folderURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw RecordingOnlyFileExportError.destinationIsNotFolder(
                    displayFolderName(settings: settings, resolvedURL: folderURL)
                )
            }
            return folderURL
        }
    }

    /// Selects a conflict-free filename. Persist the returned value in the
    /// WatchInbox before calling `copy` so an interrupted retry is idempotent.
    public func reserveFilename(
        context: RecordingOnlyFileExportContext,
        settings: CapturePresetWatchRecordingSettings,
        existingReservation: String?
    ) throws -> String {
        if let existingReservation {
            guard Self.isValidReservedFilename(existingReservation) else {
                throw RecordingOnlyFileExportError.invalidReservedFilename
            }
            return existingReservation
        }

        let folderURL = try validateDestination(settings: settings)
        let baseName = Self.renderedFilenameBase(
            template: settings.filenameTemplate,
            context: context
        )
        return try withSecurityScope(for: folderURL) {
            try coordinator.coordinateWriting(at: folderURL) { coordinatedFolderURL in
                Self.availableFilename(
                    baseName: baseName,
                    folderURL: coordinatedFolderURL,
                    fileManager: fileManager
                )
            }
        }
    }

    /// Copies to a temporary sibling, verifies the bytes, and atomically moves
    /// the temporary file into its reserved user-visible name.
    public func copy(
        sourceURL: URL,
        reservedFilename: String,
        settings: CapturePresetWatchRecordingSettings
    ) throws -> RecordingOnlyFileExportReceipt {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw RecordingOnlyFileExportError.sourceMissing
        }
        guard sourceURL.pathExtension.lowercased() == "m4a" else {
            throw RecordingOnlyFileExportError.unsupportedSourceFormat
        }
        guard Self.isValidReservedFilename(reservedFilename) else {
            throw RecordingOnlyFileExportError.invalidReservedFilename
        }

        let folderURL = try validateDestination(settings: settings)
        return try withSecurityScope(for: folderURL) {
            try coordinator.coordinateWriting(at: folderURL) { coordinatedFolderURL in
                let destinationURL = coordinatedFolderURL.appendingPathComponent(
                    reservedFilename,
                    isDirectory: false
                )
                let temporaryURL = coordinatedFolderURL.appendingPathComponent(
                    ".\(reservedFilename).vox-partial",
                    isDirectory: false
                )
                // A prior process may have been suspended or terminated during
                // its chunked copy. The durable inbox source is authoritative.
                try? fileManager.removeItem(at: temporaryURL)

                if fileManager.fileExists(atPath: destinationURL.path) {
                    guard try filesAreEqual(sourceURL, destinationURL) else {
                        throw RecordingOnlyFileExportError.filenameConflict
                    }
                    return try receipt(
                        for: destinationURL,
                        filename: reservedFilename,
                        wasAlreadyDelivered: true
                    )
                }

                do {
                    try copyBytes(from: sourceURL, to: temporaryURL)
                    guard try filesAreEqual(sourceURL, temporaryURL) else {
                        throw RecordingOnlyFileExportError.copyVerificationFailed
                    }

                    if fileManager.fileExists(atPath: destinationURL.path) {
                        guard try filesAreEqual(sourceURL, destinationURL) else {
                            throw RecordingOnlyFileExportError.filenameConflict
                        }
                        try? fileManager.removeItem(at: temporaryURL)
                        return try receipt(
                            for: destinationURL,
                            filename: reservedFilename,
                            wasAlreadyDelivered: true
                        )
                    }

                    try fileManager.moveItem(at: temporaryURL, to: destinationURL)
                    guard try filesAreEqual(sourceURL, destinationURL) else {
                        try? fileManager.removeItem(at: destinationURL)
                        throw RecordingOnlyFileExportError.copyVerificationFailed
                    }
                    return try receipt(
                        for: destinationURL,
                        filename: reservedFilename,
                        wasAlreadyDelivered: false
                    )
                } catch {
                    try? fileManager.removeItem(at: temporaryURL)
                    throw error
                }
            }
        }
    }

    static func renderedFilenameBase(
        template: String,
        context: RecordingOnlyFileExportContext
    ) -> String {
        let timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.calendar = Calendar(identifier: .gregorian)
        timestampFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = timestampFormatter.string(from: context.createdAt)
        let date = String(timestamp.prefix(10))
        let shortYear = String(timestamp.prefix(4).suffix(2))
        let time = String(timestamp.suffix(6))
        let id = context.recordingID.lowercased()
        let id8 = String(id.prefix(8))
        let original = (context.originalFilename as NSString).deletingPathExtension

        let configured = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedTemplate = configured.isEmpty
            ? CapturePresetWatchRecordingSettings.defaultFilenameTemplate
            : configured
        let rendered = selectedTemplate
            .replacingOccurrences(of: "{timestamp}", with: timestamp)
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{YR}", with: shortYear)
            .replacingOccurrences(of: "{time}", with: time)
            .replacingOccurrences(of: "{id}", with: id)
            .replacingOccurrences(of: "{id8}", with: id8)
            .replacingOccurrences(of: "{preset}", with: context.presetName)
            .replacingOccurrences(of: "{original}", with: original)
        let fallback = "recording-\(timestamp)-\(id8)"
        return sanitizeFilenameBase(rendered, fallback: fallback)
    }

    private func resolveFolder(
        settings: CapturePresetWatchRecordingSettings
    ) throws -> URL {
        guard let bookmark = settings.folderBookmark else {
            throw RecordingOnlyFileExportError.folderNotConfigured
        }
        let resolution: CaptureBookmarkResolver.Resolution
        do {
            resolution = try CaptureBookmarkResolver.resolve(bookmark)
        } catch {
            throw RecordingOnlyFileExportError.invalidFolderBookmark
        }
        guard !resolution.isStale else {
            throw RecordingOnlyFileExportError.staleFolderBookmark(
                displayFolderName(settings: settings, resolvedURL: resolution.url)
            )
        }
        return resolution.url
    }

    private func displayFolderName(
        settings: CapturePresetWatchRecordingSettings,
        resolvedURL: URL
    ) -> String {
        let configured = settings.folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? resolvedURL.lastPathComponent : configured
    }

    private func withSecurityScope<T>(for url: URL, operation: () throws -> T) rethrows -> T {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        return try operation()
    }

    private func copyBytes(from sourceURL: URL, to destinationURL: URL) throws {
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let source = try FileHandle(forReadingFrom: sourceURL)
        defer { try? source.close() }
        let destination = try FileHandle(forWritingTo: destinationURL)
        defer { try? destination.close() }

        while true {
            try Task.checkCancellation()
            guard let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty else {
                break
            }
            try destination.write(contentsOf: chunk)
        }
        try destination.synchronize()
    }

    private func filesAreEqual(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let lhsSize = try lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let rhsSize = try rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard lhsSize == rhsSize else { return false }

        let lhsHandle = try FileHandle(forReadingFrom: lhs)
        defer { try? lhsHandle.close() }
        let rhsHandle = try FileHandle(forReadingFrom: rhs)
        defer { try? rhsHandle.close() }
        while true {
            try Task.checkCancellation()
            let lhsChunk = try lhsHandle.read(upToCount: 1_048_576) ?? Data()
            let rhsChunk = try rhsHandle.read(upToCount: 1_048_576) ?? Data()
            guard lhsChunk == rhsChunk else { return false }
            if lhsChunk.isEmpty { return true }
        }
    }

    private func receipt(
        for destinationURL: URL,
        filename: String,
        wasAlreadyDelivered: Bool
    ) throws -> RecordingOnlyFileExportReceipt {
        let values = try destinationURL.resourceValues(forKeys: [.fileSizeKey])
        return RecordingOnlyFileExportReceipt(
            fileURL: destinationURL,
            filename: filename,
            byteCount: values.fileSize ?? 0,
            wasAlreadyDelivered: wasAlreadyDelivered
        )
    }

    private static func availableFilename(
        baseName: String,
        folderURL: URL,
        fileManager: FileManager
    ) -> String {
        var index = 1
        while true {
            let suffix = index == 1 ? "" : "-\(index)"
            let candidate = "\(baseName)\(suffix).m4a"
            let url = folderURL.appendingPathComponent(candidate, isDirectory: false)
            if !fileManager.fileExists(atPath: url.path) {
                return candidate
            }
            index += 1
        }
    }

    private static func isValidReservedFilename(_ filename: String) -> Bool {
        !filename.isEmpty
            && filename == (filename as NSString).lastPathComponent
            && filename != "."
            && filename != ".."
            && (filename as NSString).pathExtension.lowercased() == "m4a"
            && !filename.unicodeScalars.contains(where: invalidFilenameCharacters.contains)
    }

    private static func sanitizeFilenameBase(_ raw: String, fallback: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !(value as NSString).pathExtension.isEmpty {
            value = (value as NSString).deletingPathExtension
        }
        let replaced = value.unicodeScalars.map { scalar in
            invalidFilenameCharacters.contains(scalar) ? "-" : String(scalar)
        }.joined()
        let cleaned = replaced
            .replacingOccurrences(of: " ", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        let bounded = utf8Prefix(cleaned, maximumByteCount: 180)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        return bounded.isEmpty ? fallback : bounded
    }

    private static func utf8Prefix(_ value: String, maximumByteCount: Int) -> String {
        var result = ""
        var byteCount = 0
        for character in value {
            let rendered = String(character)
            let characterByteCount = rendered.utf8.count
            guard byteCount + characterByteCount <= maximumByteCount else { break }
            result.append(character)
            byteCount += characterByteCount
        }
        return result
    }
}
