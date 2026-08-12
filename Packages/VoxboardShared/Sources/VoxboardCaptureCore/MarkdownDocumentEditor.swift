import Foundation

public enum MarkdownDocumentEditorError: Error, Equatable, LocalizedError, Sendable {
    case headingNotFound(CaptureHeadingSelector)
    case invalidHeadingLevel(Int)

    public var errorDescription: String? {
        switch self {
        case .headingNotFound(let selector):
            return "The Markdown heading \"\(selector.title)\" was not found."
        case .invalidHeadingLevel(let level):
            return "Markdown heading level \(level) is invalid."
        }
    }
}

public struct MarkdownCaptureMutation: Equatable, Sendable {
    public var requestID: UUID
    public var entry: String
    public var placement: CapturePlacement
    public var entryPrefix: String
    public var entrySuffix: String
    public var frontmatter: [String: String]
    /// A typed location item appended to its request-ID keyed frontmatter
    /// collection. Nil preserves all legacy mutation behavior.
    public var locationMetadata: CaptureLocationRenderedMetadata?
    public var retryProtectionEnabled: Bool
    /// Production pipeline writes include an authorized root and relative path
    /// so the writer can use descriptor-relative, no-symlink I/O.
    public var destinationRootURL: URL?
    public var relativeNotePath: String?

    public init(
        requestID: UUID,
        entry: String,
        placement: CapturePlacement,
        entryPrefix: String = "",
        entrySuffix: String = "",
        frontmatter: [String: String] = [:],
        locationMetadata: CaptureLocationRenderedMetadata? = nil,
        retryProtectionEnabled: Bool = false,
        destinationRootURL: URL? = nil,
        relativeNotePath: String? = nil
    ) {
        self.requestID = requestID
        self.entry = entry
        self.placement = placement
        self.entryPrefix = entryPrefix
        self.entrySuffix = entrySuffix
        self.frontmatter = frontmatter
        self.locationMetadata = locationMetadata
        self.retryProtectionEnabled = retryProtectionEnabled
        self.destinationRootURL = destinationRootURL
        self.relativeNotePath = relativeNotePath
    }
}

public struct MarkdownDocumentEditor: Sendable {
    public init() {}

    public func applying(_ mutation: MarkdownCaptureMutation, to document: String) throws -> String {
        let normalizedDocument = normalizeNewlines(document)
        let marker = CaptureRequestMarker.text(for: mutation.requestID)
        if CaptureRequestMarker.isPresent(in: normalizedDocument, requestID: mutation.requestID) {
            return normalizedDocument
        }

        var documentParts = splitLeadingFrontmatter(normalizedDocument)
        if let location = mutation.locationMetadata,
           try validatedLocationCollectionContains(location, in: documentParts.frontmatter) {
            return normalizedDocument
        }
        let entryParts = splitLeadingFrontmatter(normalizeNewlines(mutation.entry))
        let wrappedParts = splitLeadingFrontmatter(
            normalizeNewlines(mutation.entryPrefix)
                + trimBoundaryNewlines(entryParts.body)
                + normalizeNewlines(mutation.entrySuffix)
        )
        let voxFrontmatter = try structuredFrontmatterLines(mutation.frontmatter)
        documentParts.frontmatter = mergeFrontmatter(
            existing: mergeFrontmatter(
                existing: mergeFrontmatter(
                    existing: documentParts.frontmatter,
                    incoming: entryParts.frontmatter
                ),
                incoming: voxFrontmatter
            ),
            incoming: wrappedParts.frontmatter
        )
        if let location = mutation.locationMetadata {
            documentParts.frontmatter = try appendingLocation(
                location,
                to: documentParts.frontmatter
            )
        }

        let wrappedEntry = trimBoundaryNewlines(wrappedParts.body)
        let captureBlock: String
        if mutation.retryProtectionEnabled {
            captureBlock = wrappedEntry.isEmpty ? marker : wrappedEntry + "\n\n" + marker
        } else {
            captureBlock = wrappedEntry
        }

        let editedBody: String
        switch mutation.placement {
        case .append:
            editedBody = joinBlocks([documentParts.body, captureBlock])
        case .prepend:
            editedBody = joinBlocks([captureBlock, documentParts.body])
        case .beneathHeading(let selector, let missingHeadingBehavior):
            editedBody = try inserting(
                captureBlock,
                beneath: selector,
                missingBehavior: missingHeadingBehavior,
                in: documentParts.body
            )
        }

        return assemble(frontmatter: documentParts.frontmatter, body: editedBody)
    }

    private func inserting(
        _ captureBlock: String,
        beneath selector: CaptureHeadingSelector,
        missingBehavior: CaptureMissingHeadingBehavior,
        in body: String
    ) throws -> String {
        if let level = selector.level, !(1...6).contains(level) {
            throw MarkdownDocumentEditorError.invalidHeadingLevel(level)
        }

        let lines = body.components(separatedBy: "\n")
        if let headingIndex = firstHeadingIndex(matching: selector, in: lines) {
            let before = lines[...headingIndex].joined(separator: "\n")
            let after = headingIndex + 1 < lines.count
                ? lines[(headingIndex + 1)...].joined(separator: "\n")
                : ""
            return joinBlocks([before, captureBlock, after])
        }

        switch missingBehavior {
        case .fail:
            throw MarkdownDocumentEditorError.headingNotFound(selector)
        case .create:
            let level = selector.level ?? 2
            guard (1...6).contains(level) else {
                throw MarkdownDocumentEditorError.invalidHeadingLevel(level)
            }
            return joinBlocks([body, "\(String(repeating: "#", count: level)) \(selector.title)", captureBlock])
        }
    }

    private func firstHeadingIndex(matching selector: CaptureHeadingSelector, in lines: [String]) -> Int? {
        var fence: Fence?
        for (index, line) in lines.enumerated() {
            if let delimiter = fenceDelimiter(in: line) {
                if let current = fence {
                    if delimiter.character == current.character && delimiter.count >= current.count {
                        fence = nil
                    }
                } else {
                    fence = delimiter
                }
                continue
            }
            guard fence == nil, let heading = atxHeading(in: line) else { continue }
            if heading.title == selector.title,
               selector.level == nil || selector.level == heading.level {
                return index
            }
        }
        return nil
    }

    private func atxHeading(in line: String) -> (level: Int, title: String)? {
        let leadingTrimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let level = leadingTrimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let afterHashes = leadingTrimmed.dropFirst(level)
        guard afterHashes.first == " " || afterHashes.first == "\t" else { return nil }

        var title = afterHashes.trimmingCharacters(in: .whitespacesAndNewlines)
        while title.last == "#" {
            title.removeLast()
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (level, title)
    }

    private struct Fence: Equatable {
        let character: Character
        let count: Int
    }

    private func fenceDelimiter(in line: String) -> Fence? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        guard leadingSpaces <= 3 else { return nil }
        let trimmed = line.dropFirst(leadingSpaces)
        guard let character = trimmed.first, character == "`" || character == "~" else { return nil }
        let count = trimmed.prefix(while: { $0 == character }).count
        return count >= 3 ? Fence(character: character, count: count) : nil
    }

    private struct MarkdownParts {
        var frontmatter: [String]?
        var body: String
    }

    private func splitLeadingFrontmatter(_ markdown: String) -> MarkdownParts {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first == "---",
              let closingIndex = lines.indices.dropFirst().first(where: { lines[$0] == "---" }) else {
            return MarkdownParts(frontmatter: nil, body: markdown)
        }

        let frontmatter = closingIndex > 1 ? Array(lines[1..<closingIndex]) : []
        // Vox.md treats frontmatter as a key/value mapping. Requiring at least
        // one top-level key prevents an ordinary leading horizontal-rule block
        // from being silently moved into a destination's YAML header.
        guard frontmatter.contains(where: { frontmatterEntry($0) != nil }) else {
            return MarkdownParts(frontmatter: nil, body: markdown)
        }
        let body = closingIndex + 1 < lines.count
            ? lines[(closingIndex + 1)...].joined(separator: "\n")
            : ""
        return MarkdownParts(frontmatter: frontmatter, body: body)
    }

    private func mergeFrontmatter(existing: [String]?, incoming: [String]?) -> [String]? {
        guard let incoming else { return existing }
        guard var merged = existing else { return incoming }

        var incomingIndex = 0
        while incomingIndex < incoming.count {
            guard let incomingEntry = frontmatterEntry(incoming[incomingIndex]) else {
                if !merged.contains(incoming[incomingIndex]) {
                    merged.append(incoming[incomingIndex])
                }
                incomingIndex += 1
                continue
            }

            let incomingEnd = sectionEnd(startingAt: incomingIndex, in: incoming)
            let incomingSection = Array(incoming[incomingIndex..<incomingEnd])
            guard let existingIndex = merged.indices.first(where: {
                frontmatterEntry(merged[$0])?.key == incomingEntry.key
            }) else {
                merged.append(contentsOf: incomingSection)
                incomingIndex = incomingEnd
                continue
            }

            if Self.additiveFrontmatterKeys.contains(incomingEntry.key) {
                let existingEnd = sectionEnd(startingAt: existingIndex, in: merged)
                let existingValues = frontmatterValues(
                    in: Array(merged[existingIndex..<existingEnd])
                )
                let incomingValues = frontmatterValues(in: incomingSection)
                let values = unique(existingValues + incomingValues)
                merged.replaceSubrange(
                    existingIndex..<existingEnd,
                    with: ["\(incomingEntry.key): [\(values.joined(separator: ", "))]"]
                )
            }
            // Existing non-additive values are user-owned and intentionally win.
            incomingIndex = incomingEnd
        }
        return merged
    }

    private static let additiveFrontmatterKeys: Set<String> = ["tags", "tag", "audio"]

    private func validatedLocationCollectionContains(
        _ location: CaptureLocationRenderedMetadata,
        in frontmatter: [String]?
    ) throws -> Bool {
        guard let frontmatter,
              let start = frontmatter.indices.first(where: {
                  guard let key = frontmatterEntry(frontmatter[$0])?.key else { return false }
                  return unquotedYAMLKey(key) == location.collectionKey
              }) else { return false }
        let end = sectionEnd(startingAt: start, in: frontmatter)
        guard let entry = frontmatterEntry(frontmatter[start]) else {
            throw CaptureLocationMetadataError.frontmatterCollision(location.collectionKey)
        }
        let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "[]" {
            let hasContent = frontmatter[(start + 1)..<end].contains {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
            }
            guard !hasContent else {
                throw CaptureLocationMetadataError.frontmatterCollision(location.collectionKey)
            }
            return false
        }
        guard value.isEmpty else {
            throw CaptureLocationMetadataError.frontmatterCollision(location.collectionKey)
        }

        let continuation = frontmatter[(start + 1)..<end].compactMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
            return raw
        }
        if continuation.isEmpty { return false }
        guard continuation.allSatisfy({ line in
            !line.contains("\t") && line.prefix(while: { $0 == " " }).count >= 2
        }) else {
            throw CaptureLocationMetadataError.frontmatterCollision(location.collectionKey)
        }
        let source = continuation.map { String($0.dropFirst(2)) }.joined(separator: "\n")
        let parsed: CaptureLocationYAMLValue
        do {
            var parser = try CaptureLocationConstrainedYAMLParser(source: source, maximumDepth: 32)
            parsed = try parser.parse()
        } catch {
            throw CaptureLocationMetadataError.frontmatterCollision(location.collectionKey)
        }
        guard case .sequence(let items) = parsed else {
            throw CaptureLocationMetadataError.frontmatterCollision(location.collectionKey)
        }

        var ids = Set<UUID>()
        for item in items {
            guard case .mapping(let pairs) = item,
                  let idPair = pairs.first(where: { $0.key == "id" }),
                  case .string(let rawID) = idPair.value,
                  let id = UUID(uuidString: rawID),
                  ids.insert(id).inserted else {
                throw CaptureLocationMetadataError.frontmatterCollision(location.collectionKey)
            }
        }
        return ids.contains(location.requestID)
    }

    private func appendingLocation(
        _ location: CaptureLocationRenderedMetadata,
        to frontmatter: [String]?
    ) throws -> [String] {
        var lines = frontmatter ?? []
        let item = location.itemLines.enumerated().map { index, line in
            index == 0 ? "  - \(line)" : "    \(line)"
        }
        guard let start = lines.indices.first(where: {
            guard let key = frontmatterEntry(lines[$0])?.key else { return false }
            return unquotedYAMLKey(key) == location.collectionKey
        }) else {
            lines.append("\(location.collectionKey):")
            lines.append(contentsOf: item)
            return lines
        }

        if try validatedLocationCollectionContains(location, in: lines) {
            return lines
        }
        let entry = frontmatterEntry(lines[start])
        if entry?.value == "[]" {
            lines[start] = "\(location.collectionKey):"
        }
        let end = sectionEnd(startingAt: start, in: lines)
        lines.insert(contentsOf: item, at: end)
        return lines
    }

    private func unquotedYAMLKey(_ key: String) -> String {
        guard key.count >= 2 else { return key }
        if (key.hasPrefix("\"") && key.hasSuffix("\""))
            || (key.hasPrefix("'") && key.hasSuffix("'")) {
            return String(key.dropFirst().dropLast())
        }
        return key
    }

    private func structuredFrontmatterLines(_ values: [String: String]) throws -> [String]? {
        guard !values.isEmpty else { return nil }
        return values.keys.sorted().map { key in
            "\(yamlKey(key)): \(yamlScalar(values[key] ?? ""))"
        }
    }

    private func yamlKey(_ key: String) -> String {
        let isPlain = !key.isEmpty && key.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
        }
        return isPlain ? key : yamlScalar(key)
    }

    private func yamlScalar(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
            || (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
            || ["true", "false", "null", "~"].contains(trimmed.lowercased())
            || Double(trimmed) != nil {
            return trimmed
        }
        return "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            + "\""
    }

    private func frontmatterEntry(_ line: String) -> (key: String, value: String)? {
        guard line.first != " ", line.first != "\t", !line.hasPrefix("#"),
              let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private func frontmatterValues(in section: [String]) -> [String] {
        guard let first = section.first, let entry = frontmatterEntry(first) else { return [] }
        var rawValues = frontmatterValues(entry.value)
        for continuation in section.dropFirst() {
            let trimmed = continuation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("-") else { continue }
            rawValues.append(
                String(trimmed.dropFirst())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            )
        }
        return rawValues.filter { !$0.isEmpty }
    }

    private func frontmatterValues(_ raw: String) -> [String] {
        let unwrapped = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return unwrapped
            .split(separator: ",", omittingEmptySubsequences: true)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            .filter { !$0.isEmpty }
    }

    private func sectionEnd(startingAt index: Int, in lines: [String]) -> Int {
        var cursor = index + 1
        while cursor < lines.count, frontmatterEntry(lines[cursor]) == nil {
            cursor += 1
        }
        return cursor
    }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private func assemble(frontmatter: [String]?, body: String) -> String {
        let trimmedBody = trimBoundaryNewlines(body)
        guard let frontmatter else { return trimmedBody }
        let block = "---\n" + frontmatter.joined(separator: "\n") + "\n---"
        return trimmedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? block
            : block + "\n\n" + trimmedBody
    }

    private func joinBlocks(_ blocks: [String]) -> String {
        blocks
            .map(trimBoundaryNewlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    private func trimBoundaryNewlines(_ value: String) -> String {
        value.trimmingCharacters(in: .newlines)
    }

    private func normalizeNewlines(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
