import Foundation

public enum CaptureAttachmentError: Error, Equatable, LocalizedError, Sendable {
    case assetRootRequired
    case sourceMissing(String)
    case unsafeResolvedPath(String)

    public var errorDescription: String? {
        switch self {
        case .assetRootRequired:
            return "This capture contains attachments but no staging directory was provided."
        case .sourceMissing(let path):
            return "A staged capture attachment is missing: \(path)"
        case .unsafeResolvedPath(let path):
            return "A capture attachment resolved outside its allowed directory: \(path)"
        }
    }
}

private struct CreatedCaptureAttachment: Sendable {
    var sourceRootURL: URL
    var sourceRelativePath: String
    var destinationRootURL: URL
    var destinationRelativePath: String
}

public struct CaptureAttachmentTransaction: Sendable {
    public var attachmentPaths: [String: String]
    public var attachmentURLs: [URL]
    fileprivate var createdAttachments: [CreatedCaptureAttachment]

    public init(
        attachmentPaths: [String: String],
        attachmentURLs: [URL],
        createdURLs: [URL]
    ) {
        self.attachmentPaths = attachmentPaths
        self.attachmentURLs = attachmentURLs
        self.createdAttachments = createdURLs.map {
            CreatedCaptureAttachment(
                sourceRootURL: $0.deletingLastPathComponent(),
                sourceRelativePath: $0.lastPathComponent,
                destinationRootURL: $0.deletingLastPathComponent(),
                destinationRelativePath: $0.lastPathComponent
            )
        }
    }

    fileprivate init(
        attachmentPaths: [String: String],
        attachmentURLs: [URL],
        createdAttachments: [CreatedCaptureAttachment]
    ) {
        self.attachmentPaths = attachmentPaths
        self.attachmentURLs = attachmentURLs
        self.createdAttachments = createdAttachments
    }

    public func rollback(fileManager: FileManager = .default) {
        _ = fileManager // Source-compatible injection; secure I/O is descriptor based.
        for attachment in createdAttachments.reversed() {
            try? SecureCaptureFileIO.removeIfContentsEqual(
                sourceRelativePath: attachment.sourceRelativePath,
                sourceRootURL: attachment.sourceRootURL,
                destinationRelativePath: attachment.destinationRelativePath,
                destinationRootURL: attachment.destinationRootURL
            )
        }
    }
}

public struct CaptureAttachmentWriter: Sendable {
    public init(fileManager: FileManager = .default) {
        _ = fileManager // Source-compatible injection; secure I/O is descriptor based.
    }

    public func copyAttachments(
        for request: CaptureRequest,
        destination: CaptureDestination,
        destinationRootURL: URL,
        assetRootURL: URL?
    ) throws -> CaptureAttachmentTransaction {
        let assets = request.payloads.flatMap(\.captureAssets)
        guard !assets.isEmpty else {
            return CaptureAttachmentTransaction(attachmentPaths: [:], attachmentURLs: [], createdURLs: [])
        }
        guard let assetRootURL else { throw CaptureAttachmentError.assetRootRequired }

        var mapping: [String: String] = [:]
        var attachmentURLs: [URL] = []
        var createdAttachments: [CreatedCaptureAttachment] = []
        do {
            for asset in assets where mapping[asset.relativePath] == nil {
                _ = try containedURL(relativePath: asset.relativePath, root: assetRootURL)
                guard try SecureCaptureFileIO.exists(
                    relativePath: asset.relativePath,
                    rootURL: assetRootURL
                ) else {
                    throw CaptureAttachmentError.sourceMissing(asset.relativePath)
                }

                let folder = destination.attachmentsFolderName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let initialRelativePath = folder.isEmpty
                    ? asset.originalFilename
                    : folder + "/" + asset.originalFilename
                try CapturePathValidation.validateRelativePath(initialRelativePath)
                let resolution = try reusableOrAvailablePath(
                    initialRelativePath,
                    sourceRelativePath: asset.relativePath,
                    sourceRootURL: assetRootURL,
                    destinationRootURL: destinationRootURL
                )
                let relativePath = resolution.relativePath
                let destinationURL = try containedURL(relativePath: relativePath, root: destinationRootURL)
                if resolution.reusesExistingFile {
                    // Search every uniqued collision candidate, not only the
                    // base filename. A crash-retry that previously created
                    // `photo-2.jpg` must not leak `photo-3.jpg`.
                    mapping[asset.relativePath] = relativePath
                    attachmentURLs.append(destinationURL)
                    continue
                }
                try SecureCaptureFileIO.copy(
                    sourceRelativePath: asset.relativePath,
                    sourceRootURL: assetRootURL,
                    destinationRelativePath: relativePath,
                    destinationRootURL: destinationRootURL
                )
                mapping[asset.relativePath] = relativePath
                attachmentURLs.append(destinationURL)
                createdAttachments.append(CreatedCaptureAttachment(
                    sourceRootURL: assetRootURL,
                    sourceRelativePath: asset.relativePath,
                    destinationRootURL: destinationRootURL,
                    destinationRelativePath: relativePath
                ))
            }
        } catch {
            for attachment in createdAttachments.reversed() {
                try? SecureCaptureFileIO.removeIfContentsEqual(
                    sourceRelativePath: attachment.sourceRelativePath,
                    sourceRootURL: attachment.sourceRootURL,
                    destinationRelativePath: attachment.destinationRelativePath,
                    destinationRootURL: attachment.destinationRootURL
                )
            }
            throw error
        }

        return CaptureAttachmentTransaction(
            attachmentPaths: mapping,
            attachmentURLs: attachmentURLs,
            createdAttachments: createdAttachments
        )
    }

    private func reusableOrAvailablePath(
        _ initialPath: String,
        sourceRelativePath: String,
        sourceRootURL: URL,
        destinationRootURL: URL
    ) throws -> (relativePath: String, reusesExistingFile: Bool) {
        let nsPath = initialPath as NSString
        let directory = nsPath.deletingLastPathComponent
        let ext = nsPath.pathExtension
        let base = (nsPath.lastPathComponent as NSString).deletingPathExtension
        var index = 1

        while true {
            let filename: String
            if index == 1 {
                filename = nsPath.lastPathComponent
            } else {
                filename = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            }
            let candidate = directory.isEmpty || directory == "."
                ? filename
                : (directory as NSString).appendingPathComponent(filename)
            _ = try containedURL(relativePath: candidate, root: destinationRootURL)
            guard try SecureCaptureFileIO.exists(
                relativePath: candidate,
                rootURL: destinationRootURL
            ) else {
                return (candidate, false)
            }
            if try SecureCaptureFileIO.contentsEqual(
                firstRelativePath: sourceRelativePath,
                firstRootURL: sourceRootURL,
                secondRelativePath: candidate,
                secondRootURL: destinationRootURL
            ) {
                return (candidate, true)
            }
            index += 1
        }
    }

    private func containedURL(relativePath: String, root: URL) throws -> URL {
        do {
            return try CapturePathValidation.containedFileURL(
                relativePath: relativePath,
                rootURL: root
            )
        } catch {
            throw CaptureAttachmentError.unsafeResolvedPath(relativePath)
        }
    }
}

private extension CapturePayload {
    var captureAssets: [CaptureAssetReference] {
        switch self {
        case .text, .url:
            return []
        case .audio(let asset, _), .retainedAudio(let asset, _), .image(let asset, _), .file(let asset):
            return [asset]
        case .scannedDocument(let pages, let pdf, _):
            return pdf.map { [$0] } ?? pages
        case .sketch(let drawing, let preview, _):
            return [drawing, preview]
        }
    }
}
