import Foundation

public enum CaptureRenderingError: Error, Equatable, LocalizedError, Sendable {
    case emptyRequest
    case unsafeAttachmentPath(String)
    case unsafeURL(String)

    public var errorDescription: String? {
        switch self {
        case .emptyRequest:
            return "The capture has no content."
        case .unsafeAttachmentPath(let path):
            return "The rendered attachment path is unsafe: \(path)"
        case .unsafeURL(let value):
            return "Only HTTP and HTTPS links can be rendered: \(value)"
        }
    }
}

public struct CaptureMarkdownRenderer: Sendable {
    public init() {}

    public func render(
        _ request: CaptureRequest,
        for destination: CaptureDestination,
        attachmentPaths: [String: String] = [:]
    ) throws -> String {
        guard !request.payloads.isEmpty else {
            throw CaptureRenderingError.emptyRequest
        }

        var blocks: [String] = []
        var topAudioBlocks: [String] = []
        for payload in request.payloads {
            switch payload {
            case .text(let text):
                append(text, to: &blocks)

            case .url(let url, let title):
                guard let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else {
                    throw CaptureRenderingError.unsafeURL(url.absoluteString)
                }
                let label = nonEmpty(title) ?? url.absoluteString
                blocks.append("[\(escapeMarkdownLabel(label))](\(escapeMarkdownURL(url.absoluteString)))")

            case .audio(let asset, let transcript):
                append(transcript, to: &blocks)
                let path = try attachmentPath(for: asset, destination: destination, overrides: attachmentPaths)
                blocks.append(obsidianEmbed(path: path))

            case .retainedAudio(let asset, let embedPlacement):
                let path = try attachmentPath(for: asset, destination: destination, overrides: attachmentPaths)
                switch embedPlacement {
                case .none: break
                case .top: topAudioBlocks.append(obsidianEmbed(path: path))
                case .bottom: blocks.append(obsidianEmbed(path: path))
                }

            case .image(let asset, let altText):
                let path = try attachmentPath(for: asset, destination: destination, overrides: attachmentPaths)
                blocks.append(obsidianEmbed(path: path, alias: nonEmpty(altText)))

            case .file(let asset):
                let path = try attachmentPath(for: asset, destination: destination, overrides: attachmentPaths)
                blocks.append(obsidianLink(path: path, alias: asset.originalFilename))

            case .scannedDocument(let pages, let pdf, let extractedText):
                append(extractedText, to: &blocks)
                if let pdf {
                    let path = try attachmentPath(for: pdf, destination: destination, overrides: attachmentPaths)
                    blocks.append(obsidianEmbed(path: path))
                } else {
                    for page in pages {
                        let path = try attachmentPath(for: page, destination: destination, overrides: attachmentPaths)
                        blocks.append(obsidianEmbed(path: path))
                    }
                }

            case .sketch(let drawing, let preview, let altText):
                let previewPath = try attachmentPath(for: preview, destination: destination, overrides: attachmentPaths)
                let drawingPath = try attachmentPath(for: drawing, destination: destination, overrides: attachmentPaths)
                blocks.append(obsidianEmbed(path: previewPath, alias: nonEmpty(altText)))
                blocks.append(obsidianLink(path: drawingPath, alias: "Editable drawing"))
            }
        }

        var rendered = blocks
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        if !topAudioBlocks.isEmpty {
            rendered = insertingAfterLeadingFrontmatter(
                topAudioBlocks.joined(separator: "\n\n"),
                in: rendered
            )
        }
        if request.voxProfile?.metadataScope == .entry,
           !request.frontmatter.isEmpty {
            let metadata = inlineMetadata(request.frontmatter)
            if !metadata.isEmpty {
                rendered = insertingAfterLeadingFrontmatter(metadata, in: rendered)
            }
        }
        guard !rendered.isEmpty else { throw CaptureRenderingError.emptyRequest }
        return rendered
    }

    private func inlineMetadata(_ metadata: [String: String]) -> String {
        metadata.keys.sorted().compactMap { key in
            let safeKey = key
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !safeKey.isEmpty else { return nil }
            let safeValue = metadata[key, default: ""]
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(safeKey):: \(safeValue)"
        }.joined(separator: "\n")
    }

    private func insertingAfterLeadingFrontmatter(_ insertion: String, in markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        if lines.first == "---",
           let closing = lines.indices.dropFirst().first(where: { lines[$0] == "---" }) {
            let frontmatter = lines[...closing].joined(separator: "\n")
            let body = closing + 1 < lines.count
                ? lines[(closing + 1)...].joined(separator: "\n")
                    .trimmingCharacters(in: .newlines)
                : ""
            return body.isEmpty
                ? frontmatter + "\n\n" + insertion
                : frontmatter + "\n\n" + insertion + "\n\n" + body
        }
        return markdown.isEmpty ? insertion : insertion + "\n\n" + markdown
    }

    private func attachmentPath(
        for asset: CaptureAssetReference,
        destination: CaptureDestination,
        overrides: [String: String]
    ) throws -> String {
        let defaultPath: String
        let folder = destination.attachmentsFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if folder.isEmpty {
            defaultPath = asset.originalFilename
        } else {
            defaultPath = folder + "/" + asset.originalFilename
        }
        let path = overrides[asset.relativePath] ?? defaultPath
        do {
            try CapturePathValidation.validateRelativePath(path)
        } catch {
            throw CaptureRenderingError.unsafeAttachmentPath(path)
        }
        return path.replacingOccurrences(of: "]", with: "\\]")
    }

    private func append(_ value: String?, to blocks: inout [String]) {
        guard let value else { return }
        let boundaryTrimmed = value.trimmingCharacters(in: .newlines)
        guard !boundaryTrimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        blocks.append(boundaryTrimmed)
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func obsidianEmbed(path: String, alias: String? = nil) -> String {
        if let alias {
            return "![[\(path)|\(escapeObsidianAlias(alias))]]"
        }
        return "![[\(path)]]"
    }

    private func obsidianLink(path: String, alias: String) -> String {
        "[[\(path)|\(escapeObsidianAlias(alias))]]"
    }

    private func escapeObsidianAlias(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func escapeMarkdownLabel(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func escapeMarkdownURL(_ value: String) -> String {
        value
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }
}
