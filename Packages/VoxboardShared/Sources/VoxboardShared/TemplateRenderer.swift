import Foundation

/// Renders an Obsidian-style markdown template by resolving Templater-compatible
/// expressions and filling empty frontmatter fields from transcript enrichment.
///
/// Supported expressions inside `<% ... %>`:
/// - `tp.date.now("YYYY-MM-DD")` — the context's `now`, formatted via moment-style tokens
/// - `tp.file.creation_date("YYYY-MM-DD HH:mm:ss")` — same as `tp.date.now`
/// - `crypto.randomUUID()` — a new lowercase UUID
///
/// Empty frontmatter values (or `[]` for `tags`) are auto-filled when the key
/// matches a known enrichment field (`tags`, `title`, `category`, `summary`).
/// Unknown empty fields are left empty for the user to fill later.
public enum TemplateRenderer {

    public struct Context: Sendable {
        public let transcript: Transcript
        public let now: Date

        public init(transcript: Transcript, now: Date = Date()) {
            self.transcript = transcript
            self.now = now
        }
    }

    public static func render(template: String, context: Context) -> String {
        let normalized = template.replacingOccurrences(of: "\r\n", with: "\n")
        let split = splitFrontmatter(normalized)

        let renderedFM: String
        let renderedBody: String

        switch split {
        case .none:
            renderedFM = ""
            renderedBody = resolveExpressions(in: normalized, context: context)
        case .some(let fmLines, let body):
            let resolvedFMLines = fmLines.map { resolveFrontmatterLine($0, context: context) }
            renderedFM = "---\n" + resolvedFMLines.joined(separator: "\n") + "\n---"
            renderedBody = resolveExpressions(in: body, context: context)
        }

        return assemble(frontmatter: renderedFM, body: renderedBody, context: context)
    }

    // MARK: - Frontmatter split

    private enum FrontmatterSplit {
        case none
        case some(lines: [String], body: String)
    }

    private static func splitFrontmatter(_ template: String) -> FrontmatterSplit {
        guard template.hasPrefix("---\n") else { return .none }

        let afterOpening = String(template.dropFirst(4))
        let lines = afterOpening.components(separatedBy: "\n")
        var fmLines: [String] = []
        var closingIndex: Int?

        for (i, line) in lines.enumerated() {
            if line == "---" {
                closingIndex = i
                break
            }
            fmLines.append(line)
        }

        guard let ci = closingIndex else { return .none }

        let bodyLines = lines.suffix(from: ci + 1)
        var body = bodyLines.joined(separator: "\n")
        while body.hasPrefix("\n") { body.removeFirst() }
        return .some(lines: fmLines, body: body)
    }

    // MARK: - Frontmatter line resolution

    private static func resolveFrontmatterLine(_ line: String, context: Context) -> String {
        guard let colonIdx = line.firstIndex(of: ":") else {
            return resolveExpressions(in: line, context: context)
        }

        let key = String(line[..<colonIdx])
        let trimmedKey = key.trimmingCharacters(in: .whitespaces)
        let valuePart = String(line[line.index(after: colonIdx)...])
        let trimmedValue = valuePart.trimmingCharacters(in: .whitespaces)

        let resolvedValue = resolveExpressions(in: trimmedValue, context: context)

        let expressionsResolved = resolvedValue != trimmedValue
        if expressionsResolved, !resolvedValue.isEmpty {
            return "\(key): \(resolvedValue)"
        }

        if let filled = fillValueFromEnrichment(
            key: trimmedKey,
            originalValue: resolvedValue,
            context: context
        ) {
            return "\(key): \(filled)"
        }

        return line
    }

    private static func fillValueFromEnrichment(
        key: String,
        originalValue: String,
        context: Context
    ) -> String? {
        let lowerKey = key.lowercased()
        let t = context.transcript

        switch lowerKey {
        case "tags":
            guard originalValue == "[]" || originalValue.isEmpty else { return nil }
            guard let tags = t.tags, !tags.isEmpty else { return nil }
            let joined = tags.map { "\"\(escapeYAMLString($0))\"" }.joined(separator: ", ")
            return "[\(joined)]"
        case "title":
            guard originalValue.isEmpty, let title = t.title, !title.isEmpty else { return nil }
            return yamlScalar(title)
        case "category":
            guard originalValue.isEmpty, let category = t.category, !category.isEmpty else { return nil }
            return yamlScalar(category)
        case "summary", "description":
            guard originalValue.isEmpty else { return nil }
            let body = (t.cleanedText?.isEmpty == false ? t.cleanedText : t.text) ?? ""
            guard !body.isEmpty else { return nil }
            return yamlScalar(body)
        default:
            return nil
        }
    }

    private static func yamlScalar(_ value: String) -> String {
        let needsQuoting = value.contains(":") || value.contains("#") || value.contains("\"")
        if needsQuoting {
            return "\"\(escapeYAMLString(value))\""
        }
        return value
    }

    private static func escapeYAMLString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Expression resolution

    private static let expressionRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "<%\\s*(.+?)\\s*%>", options: [])
    }()

    private static func resolveExpressions(in text: String, context: Context) -> String {
        let ns = text as NSString
        let matches = expressionRegex.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        )
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            let exprNSRange = match.range(at: 1)
            guard exprNSRange.location != NSNotFound else { continue }
            let expr = ns.substring(with: exprNSRange)
            let replacement = evaluateExpression(expr, context: context)
            if let fullRange = Range(match.range, in: result) {
                result.replaceSubrange(fullRange, with: replacement)
            }
        }
        return result
    }

    private static func evaluateExpression(_ expr: String, context: Context) -> String {
        let trimmed = expr.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("tp.date.now") {
            let arg = extractStringArg(from: trimmed) ?? "YYYY-MM-DD"
            return formatDate(context.now, moment: arg)
        }

        if trimmed.hasPrefix("tp.file.creation_date") {
            let arg = extractStringArg(from: trimmed) ?? "YYYY-MM-DD HH:mm:ss"
            return formatDate(context.now, moment: arg)
        }

        if trimmed.hasPrefix("crypto.randomUUID") {
            return UUID().uuidString.lowercased()
        }

        return "<% \(expr) %>"
    }

    private static func extractStringArg(from expr: String) -> String? {
        guard let openParen = expr.firstIndex(of: "("),
              let closeParen = expr.lastIndex(of: ")"),
              openParen < closeParen else { return nil }
        let inside = expr[expr.index(after: openParen)..<closeParen]
            .trimmingCharacters(in: .whitespaces)
        guard inside.count >= 2 else { return nil }
        let first = inside.first!
        let last = inside.last!
        guard (first == "\"" && last == "\"") || (first == "'" && last == "'") else { return nil }
        return String(inside.dropFirst().dropLast())
    }

    // MARK: - Date formatting

    private static func formatDate(_ date: Date, moment format: String) -> String {
        let df = DateFormatter()
        df.dateFormat = convertMomentTokens(format)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        return df.string(from: date)
    }

    /// Moment.js tokens used by Templater → Foundation `DateFormatter` patterns.
    /// Only the tokens that differ need mapping; upper/lower case matters.
    private static func convertMomentTokens(_ format: String) -> String {
        format
            .replacingOccurrences(of: "YYYY", with: "yyyy")
            .replacingOccurrences(of: "DD", with: "dd")
    }

    // MARK: - Assembly

    private static func assemble(frontmatter: String, body: String, context: Context) -> String {
        let transcriptBody = context.transcript.cleanedText?.isEmpty == false
            ? context.transcript.cleanedText!
            : context.transcript.text

        var parts: [String] = []
        if !frontmatter.isEmpty { parts.append(frontmatter) }
        if !body.isEmpty { parts.append(body) }
        if !transcriptBody.isEmpty { parts.append(transcriptBody) }

        return parts.joined(separator: "\n\n")
    }
}
