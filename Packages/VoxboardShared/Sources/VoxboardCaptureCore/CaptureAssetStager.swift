import Foundation

public enum CaptureAssetStagerError: Error, Equatable, LocalizedError, Sendable {
    case sourceMissing(String)
    case sourceIsDirectory(String)
    case unsafeStagedPath(String)
    case assetTooLarge(filename: String, byteCount: Int64, limit: Int64)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let path):
            return "The selected capture file is no longer available: \(path)"
        case .sourceIsDirectory(let path):
            return "Folders cannot be captured as a single attachment: \(path)"
        case .unsafeStagedPath(let path):
            return "The staged capture path is unsafe: \(path)"
        case .assetTooLarge(let filename, let byteCount, let limit):
            return "The capture asset ‘\(filename)’ is \(byteCount) bytes, above the \(limit)-byte safety limit."
        }
    }
}

/// Durably stages user-selected media beside a capture draft. The actor makes
/// collision handling deterministic when Photos, Files, and scanners finish at
/// the same time.
public actor CaptureAssetStager {
    public static let defaultMaximumByteCount: Int64 = 100 * 1_024 * 1_024

    public let directoryURL: URL
    public let maximumByteCount: Int64
    private let fileManager: FileManager

    public init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        maximumByteCount: Int64 = CaptureAssetStager.defaultMaximumByteCount
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.maximumByteCount = maximumByteCount
    }

    public func stage(
        data: Data,
        preferredFilename: String,
        contentTypeIdentifier: String
    ) throws -> CaptureAssetReference {
        let byteCount = Int64(data.count)
        guard byteCount <= maximumByteCount else {
            throw CaptureAssetStagerError.assetTooLarge(
                filename: preferredFilename,
                byteCount: byteCount,
                limit: maximumByteCount
            )
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let filename = availableFilename(Self.sanitizedFilename(preferredFilename))
        let destinationURL = directoryURL.appendingPathComponent(filename, isDirectory: false)
        try data.write(to: destinationURL, options: [.atomic])
        return try CaptureAssetReference(
            relativePath: filename,
            originalFilename: filename,
            contentTypeIdentifier: contentTypeIdentifier,
            byteCount: byteCount
        )
    }

    public func stageCopy(
        from sourceURL: URL,
        preferredFilename: String? = nil,
        contentTypeIdentifier: String
    ) throws -> CaptureAssetReference {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw CaptureAssetStagerError.sourceMissing(sourceURL.path)
        }
        guard !isDirectory.boolValue else {
            throw CaptureAssetStagerError.sourceIsDirectory(sourceURL.path)
        }
        let requestedName = preferredFilename ?? sourceURL.lastPathComponent
        let sourceValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        if let sourceSize = sourceValues.fileSize, Int64(sourceSize) > maximumByteCount {
            throw CaptureAssetStagerError.assetTooLarge(
                filename: requestedName,
                byteCount: Int64(sourceSize),
                limit: maximumByteCount
            )
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let filename = availableFilename(Self.sanitizedFilename(
            requestedName,
            fallbackExtension: sourceURL.pathExtension
        ))
        let destinationURL = directoryURL.appendingPathComponent(filename, isDirectory: false)
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            let values = try destinationURL.resourceValues(forKeys: [.fileSizeKey])
            if let copiedSize = values.fileSize, Int64(copiedSize) > maximumByteCount {
                throw CaptureAssetStagerError.assetTooLarge(
                    filename: requestedName,
                    byteCount: Int64(copiedSize),
                    limit: maximumByteCount
                )
            }
            return try CaptureAssetReference(
                relativePath: filename,
                originalFilename: filename,
                contentTypeIdentifier: contentTypeIdentifier,
                byteCount: values.fileSize.map(Int64.init)
            )
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    public func remove(_ asset: CaptureAssetReference) throws {
        let url = try containedURL(relativePath: asset.relativePath)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Converts an untrusted display name into one safe path component. Share
    /// extensions use the same implementation so transient provider names can
    /// never escape their request's staging directory.
    public nonisolated static func sanitizedFilename(
        _ value: String,
        fallbackExtension: String = ""
    ) -> String {
        let lastComponent = value
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r\t")
        var sanitized = lastComponent.unicodeScalars
            .map { invalid.contains($0) ? "-" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while sanitized.hasPrefix(".") { sanitized.removeFirst() }
        if sanitized.isEmpty || sanitized == "." || sanitized == ".." {
            sanitized = "attachment-\(UUID().uuidString.lowercased())"
        }

        let safeExtension = fallbackExtension.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
        if !safeExtension.isEmpty, (sanitized as NSString).pathExtension.isEmpty {
            sanitized += ".\(safeExtension)"
        }
        return sanitized
    }

    private func availableFilename(_ initialFilename: String) -> String {
        let initialURL = directoryURL.appendingPathComponent(initialFilename)
        guard !fileManager.fileExists(atPath: initialURL.path) else {
            let nsName = initialFilename as NSString
            let ext = nsName.pathExtension
            let base = nsName.deletingPathExtension
            var index = 2
            while true {
                let candidate = ext.isEmpty
                    ? "\(base)-\(index)"
                    : "\(base)-\(index).\(ext)"
                if !fileManager.fileExists(atPath: directoryURL.appendingPathComponent(candidate).path) {
                    return candidate
                }
                index += 1
            }
        }
        return initialFilename
    }

    private func containedURL(relativePath: String) throws -> URL {
        do {
            return try CapturePathValidation.containedFileURL(
                relativePath: relativePath,
                rootURL: directoryURL
            )
        } catch {
            throw CaptureAssetStagerError.unsafeStagedPath(relativePath)
        }
    }
}
