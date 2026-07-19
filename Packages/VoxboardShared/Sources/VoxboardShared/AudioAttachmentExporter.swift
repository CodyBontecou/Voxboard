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
        transcriptFolderScopeURL: URL? = nil
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

        let destination = uniquedURL(audioDestinationURL(
            for: transcriptFileURL,
            flow: flow,
            preferredExtension: "m4a",
            audioFolderOverride: audioFolderOverride
        ))

        do {
            try await exportM4A(from: sourceAudioURL, to: destination)
            return destination
        } catch {
            // Fallback: keep the original/working file extension, usually WAV.
            let fallbackExt = sourceAudioURL.pathExtension.isEmpty ? "wav" : sourceAudioURL.pathExtension
            let fallback = uniquedURL(audioDestinationURL(
                for: transcriptFileURL,
                flow: flow,
                preferredExtension: fallbackExt,
                audioFolderOverride: audioFolderOverride
            ))
            try FileManager.default.createDirectory(
                at: fallback.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: sourceAudioURL, to: fallback)
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
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destinationURL)

        let asset = AVURLAsset(url: sourceURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExportError.couldNotCreateSession
        }
        session.outputURL = destinationURL
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
