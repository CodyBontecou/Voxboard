#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// Saves a user-facing copy of the source audio next to an exported transcript.
/// It prefers `.m4a` for Obsidian/Files friendliness and falls back to copying
/// the source file when conversion is unavailable.
public enum AudioAttachmentExporter {
    public enum ExportError: Error {
        case disabled
        case couldNotCreateSession
        case exportFailed
    }

    public static func exportAudioIfNeeded(
        sourceAudioURL: URL,
        transcriptFileURL: URL,
        flow: CapturePreset?,
        transcriptFolderScopeURL: URL? = nil,
        previouslyExportedURL: URL? = nil,
        deliveryTransactionDirectoryURL: URL? = nil
    ) async throws -> URL? {
        guard let flow, flow.audioSaveMode != .off else { return nil }
        let audioFolderOverride = flow.audioSaveMode == .attachmentsFolder
            ? resolveBookmarkData(flow.exportSettings.audioFolderBookmark)
            : nil
        let folderNeedingScope = audioFolderOverride
            ?? transcriptFolderScopeURL
            ?? exportFolderScopeURL(for: flow)
        let needsScoping = folderNeedingScope?.startAccessingSecurityScopedResource() ?? false
        defer { if needsScoping { folderNeedingScope?.stopAccessingSecurityScopedResource() } }

        if let previouslyExportedURL, isUsableFile(previouslyExportedURL) {
            return previouslyExportedURL
        }
        let transaction = deliveryTransactionDirectoryURL.map {
            ExternalFileDeliveryTransaction(directoryURL: $0)
        }
        if let transaction, let resumed = try transaction.resumeIfPrepared() {
            return resumed.url
        }

        let preferredDestination = uniquedURL(audioDestinationURL(
            for: transcriptFileURL,
            flow: flow,
            preferredExtension: "m4a",
            audioFolderOverride: audioFolderOverride
        ))
        do {
            if let transaction, let deliveryTransactionDirectoryURL {
                try FileManager.default.createDirectory(
                    at: deliveryTransactionDirectoryURL,
                    withIntermediateDirectories: true
                )
                let convertedURL = deliveryTransactionDirectoryURL
                    .appendingPathComponent("converted", isDirectory: false)
                    .appendingPathExtension("m4a")
                try? FileManager.default.removeItem(at: convertedURL)
                defer { try? FileManager.default.removeItem(at: convertedURL) }
                try await exportM4A(from: sourceAudioURL, to: convertedURL)
                let published = try transaction.prepareAndPublish(
                    data: Data(contentsOf: convertedURL),
                    to: preferredDestination,
                    expecting: .missing
                )
                return published.url
            }
            try await exportM4A(from: sourceAudioURL, to: preferredDestination)
            return preferredDestination
        } catch let error as ExternalFileDeliveryTransaction.TransactionError {
            throw error
        } catch {
            // Fallback: keep the original/working file extension, usually WAV.
            let fallbackExt = sourceAudioURL.pathExtension.isEmpty ? "wav" : sourceAudioURL.pathExtension
            let fallback = uniquedURL(audioDestinationURL(
                for: transcriptFileURL,
                flow: flow,
                preferredExtension: fallbackExt,
                audioFolderOverride: audioFolderOverride
            ))
            if let transaction {
                let published = try transaction.prepareAndPublish(
                    data: Data(contentsOf: sourceAudioURL),
                    to: fallback,
                    expecting: .missing
                )
                return published.url
            }
            try atomicCopy(from: sourceAudioURL, to: fallback)
            return fallback
        }
    }

    public static func relativePath(from transcriptFileURL: URL, to audioURL: URL) -> String {
        let transcriptFolder = transcriptFileURL.deletingLastPathComponent().standardizedFileURL
        let audio = audioURL.standardizedFileURL
        let transcriptComponents = transcriptFolder.pathComponents
        let audioComponents = audio.pathComponents

        var common = 0
        while common < transcriptComponents.count,
              common < audioComponents.count,
              transcriptComponents[common] == audioComponents[common] {
            common += 1
        }

        let up = Array(repeating: "..", count: transcriptComponents.count - common)
        let down = audioComponents.dropFirst(common)
        let components = up + down
        return components.isEmpty ? audioURL.lastPathComponent : components.joined(separator: "/")
    }

    public static func audioDestinationURL(
        for transcriptFileURL: URL,
        flow: CapturePreset,
        preferredExtension: String,
        audioFolderOverride: URL? = nil
    ) -> URL {
        let baseFolder = transcriptFileURL.deletingLastPathComponent()
        let destinationFolder: URL
        if flow.audioSaveMode == .attachmentsFolder, let audioFolderOverride {
            destinationFolder = audioFolderOverride
        } else {
            switch flow.audioSaveMode {
            case .off, .alongsideTranscript:
                destinationFolder = baseFolder
            case .attachmentsFolder:
                let folderName = sanitizedFolderName(flow.attachmentsFolderName)
                destinationFolder = baseFolder.appendingPathComponent(folderName.isEmpty ? "attachments" : folderName)
            }
        }
        let baseName = transcriptFileURL.deletingPathExtension().lastPathComponent
        return destinationFolder.appendingPathComponent(baseName).appendingPathExtension(preferredExtension)
    }

    private static func resolveBookmarkData(_ bookmarkData: Data?) -> URL? {
        guard let bookmarkData else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
    }

    private static func exportFolderScopeURL(for flow: CapturePreset) -> URL? {
        if flow.exportSettings.usesCustomExportSettings {
            return resolveBookmarkData(flow.exportSettings.folderBookmark)
        }
        return resolveBookmarkData(AppConstants.sharedDefaults?.data(forKey: AppConstants.fileExportBookmarkKey))
    }

    private static func exportM4A(from sourceURL: URL, to destinationURL: URL) async throws {
        let folderURL = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folderURL,
            withIntermediateDirectories: true
        )
        let temporaryURL = temporaryURL(for: destinationURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let asset = AVURLAsset(url: sourceURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExportError.couldNotCreateSession
        }
        session.outputURL = temporaryURL
        session.outputFileType = .m4a
        session.shouldOptimizeForNetworkUse = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: session.error ?? ExportError.exportFailed)
                default:
                    continuation.resume(throwing: ExportError.exportFailed)
                }
            }
        }
        try replaceAtomically(temporaryURL: temporaryURL, destinationURL: destinationURL)
    }

    private static func atomicCopy(from sourceURL: URL, to destinationURL: URL) throws {
        let folderURL = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let temporaryURL = temporaryURL(for: destinationURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
        try replaceAtomically(temporaryURL: temporaryURL, destinationURL: destinationURL)
    }

    private static func temporaryURL(for destinationURL: URL) -> URL {
        let baseName = destinationURL.deletingPathExtension().lastPathComponent
        return destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(baseName).\(UUID().uuidString).partial")
            .appendingPathExtension(destinationURL.pathExtension)
    }

    private static func replaceAtomically(temporaryURL: URL, destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    private static func isUsableFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0
    }

    private static func sanitizedFolderName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r\t")
        return raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "- ."))
    }

    private static func uniquedURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let candidate = directory.appendingPathComponent("\(base)-\(index)").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
#endif
