import Foundation

public enum CaptureVaultMarkdownTemplateError: Error, Equatable, LocalizedError, Sendable {
    case invalidPath(String)
    case markdownFileRequired(String)
    case templateMatchesDestination(String)
    case templateMissing(String)
    case invalidUTF8(String)
    case templateTooLarge(path: String, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            return "The Markdown template path is invalid: \(path)"
        case .markdownFileRequired(let path):
            return "The capture template must be a Markdown (.md) file: \(path)"
        case .templateMatchesDestination(let path):
            return "The capture destination cannot also be its Markdown template: \(path)"
        case .templateMissing(let path):
            return "The Markdown template could not be found in the destination vault: \(path)"
        case .invalidUTF8(let path):
            return "The Markdown template is not a UTF-8 text file: \(path)"
        case .templateTooLarge(let path, let limit):
            return "The Markdown template \(path) is larger than the \(limit.formatted())-character safety limit."
        }
    }
}

/// Reads a live Markdown template through the destination root's directory
/// descriptor. The root's security scope is owned by the delivery caller.
enum CaptureVaultMarkdownTemplateLoader {
    static func load(
        relativePath: String?,
        destinationNotePath: String,
        rootURL: URL
    ) throws -> String? {
        guard let relativePath else { return nil }
        do {
            try CapturePathValidation.validateRelativePath(relativePath)
        } catch {
            throw CaptureVaultMarkdownTemplateError.invalidPath(relativePath)
        }
        guard URL(fileURLWithPath: relativePath).pathExtension.lowercased() == "md" else {
            throw CaptureVaultMarkdownTemplateError.markdownFileRequired(relativePath)
        }
        guard relativePath != destinationNotePath else {
            throw CaptureVaultMarkdownTemplateError.templateMatchesDestination(relativePath)
        }
        guard let data = try SecureCaptureFileIO.read(relativePath: relativePath, rootURL: rootURL) else {
            throw CaptureVaultMarkdownTemplateError.templateMissing(relativePath)
        }
        // UTF-8 uses at most four bytes per Unicode scalar. Bound the data
        // before decoding, then enforce the user-visible character limit too.
        let characterLimit = CaptureInputLimits.maximumTextCharacters
        guard data.count <= characterLimit * 4 else {
            throw CaptureVaultMarkdownTemplateError.templateTooLarge(
                path: relativePath,
                limit: characterLimit
            )
        }
        guard let template = String(data: data, encoding: .utf8) else {
            throw CaptureVaultMarkdownTemplateError.invalidUTF8(relativePath)
        }
        guard template.count <= characterLimit else {
            throw CaptureVaultMarkdownTemplateError.templateTooLarge(
                path: relativePath,
                limit: characterLimit
            )
        }
        return template
    }
}

/// Renders the same vault-file syntax supported by the legacy voice exporter,
/// plus unified Capture entry tokens. Payload text is appended later and is
/// therefore never interpolated.
public struct CaptureVaultMarkdownTemplateRenderer: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func render(_ template: String, for request: CaptureRequest) -> String {
        let normalized = template
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let tokenRendered = CaptureEntryTemplateRenderer(calendar: calendar)
            .render(normalized, for: request)
        let expressionRendered = resolveExpressions(in: tokenRendered, for: request)
        let noteMetadata = request.voxProfile?.metadataScope == .entry ? [:] : request.frontmatter
        return fillEmptyFrontmatter(in: expressionRendered, from: noteMetadata)
    }

    private func fillEmptyFrontmatter(
        in template: String,
        from metadata: [String: String]
    ) -> String {
        guard template.hasPrefix("---\n") else { return template }
        var lines = template.components(separatedBy: "\n")
        guard let closingIndex = lines.indices.dropFirst().first(where: { lines[$0] == "---" }) else {
            return template
        }
        let metadataByLowercaseKey = Dictionary(
            metadata.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        let supportedKeys: Set<String> = ["tags", "title", "category", "summary", "description"]

        for index in 1..<closingIndex {
            guard let colon = lines[index].firstIndex(of: ":") else { continue }
            let keySlice = lines[index][..<colon]
            let key = keySlice.trimmingCharacters(in: .whitespaces).lowercased()
            guard supportedKeys.contains(key),
                  let value = metadataByLowercaseKey[key],
                  !value.isEmpty else { continue }
            let current = lines[index][lines[index].index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard current.isEmpty || (key == "tags" && current == "[]") else { continue }
            lines[index] = "\(keySlice): \(value)"
        }
        return lines.joined(separator: "\n")
    }

    private static let expressionRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "<%\\s*(.+?)\\s*%>", options: [])
    }()

    private func resolveExpressions(in text: String, for request: CaptureRequest) -> String {
        let source = text as NSString
        let matches = Self.expressionRegex.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: source.length)
        )
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            let expressionRange = match.range(at: 1)
            guard expressionRange.location != NSNotFound,
                  let fullRange = Range(match.range, in: result) else { continue }
            let expression = source.substring(with: expressionRange)
            guard let replacement = evaluate(expression, for: request) else { continue }
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }

    private func evaluate(_ expression: String, for request: CaptureRequest) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("tp.date.now") {
            return format(
                request.createdAt,
                momentPattern: extractStringArgument(from: trimmed) ?? "YYYY-MM-DD"
            )
        }
        if trimmed.hasPrefix("tp.file.creation_date") {
            return format(
                request.createdAt,
                momentPattern: extractStringArgument(from: trimmed) ?? "YYYY-MM-DD HH:mm:ss"
            )
        }
        if trimmed.hasPrefix("crypto.randomUUID") {
            return UUID().uuidString.lowercased()
        }
        return nil
    }

    private func extractStringArgument(from expression: String) -> String? {
        guard let opening = expression.firstIndex(of: "("),
              let closing = expression.lastIndex(of: ")"),
              opening < closing else { return nil }
        let argument = expression[expression.index(after: opening)..<closing]
            .trimmingCharacters(in: .whitespaces)
        guard argument.count >= 2,
              let first = argument.first,
              let last = argument.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else {
            return nil
        }
        return String(argument.dropFirst().dropLast())
    }

    private func format(_ date: Date, momentPattern: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = momentPattern
            .replacingOccurrences(of: "YYYY", with: "yyyy")
            .replacingOccurrences(of: "DD", with: "dd")
        return formatter.string(from: date)
    }
}
