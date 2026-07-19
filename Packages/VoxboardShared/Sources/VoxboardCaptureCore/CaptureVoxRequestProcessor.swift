import Foundation

public struct CapturePresetTextProcessingResult: Equatable, Sendable {
    public var text: String
    public var title: String?
    public var tags: [String]
    public var category: String?

    public init(
        text: String,
        title: String? = nil,
        tags: [String] = [],
        category: String? = nil
    ) {
        self.text = text
        self.title = title
        self.tags = tags
        self.category = category
    }
}

public protocol CapturePresetTextProcessing: Sendable {
    func process(
        text: String,
        profile: CapturePresetProfile
    ) async throws -> CapturePresetTextProcessingResult
}

/// Applies a snapshotted Capture Preset to every text-bearing payload while
/// preserving payload associations (for example, an audio transcript remains attached to
/// its audio asset). Backend failures use deterministic/raw fallbacks so local
/// capture delivery never depends on AI availability.
public struct CapturePresetRequestProcessor: Sendable {
    private let textProcessor: (any CapturePresetTextProcessing)?

    public init(textProcessor: (any CapturePresetTextProcessing)? = nil) {
        self.textProcessor = textProcessor
    }

    public func process(_ request: CaptureRequest) async -> CaptureRequest {
        guard request.voxProcessingState == .pending,
              let profile = request.voxProfile else {
            return request
        }

        var resolved = request
        var generatedTitle: String?
        var generatedCategory: String?
        var generatedTags: [String] = []

        for index in resolved.payloads.indices {
            switch resolved.payloads[index] {
            case .text(let text):
                let result = await processText(text, profile: profile)
                resolved.payloads[index] = .text(result.text)
                mergeMetadata(
                    result,
                    title: &generatedTitle,
                    category: &generatedCategory,
                    tags: &generatedTags
                )

            case .audio(let asset, let transcript):
                guard let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                let result = await processText(transcript, profile: profile)
                resolved.payloads[index] = .audio(asset, transcript: result.text)
                mergeMetadata(
                    result,
                    title: &generatedTitle,
                    category: &generatedCategory,
                    tags: &generatedTags
                )

            case .scannedDocument(let pages, let pdf, let extractedText):
                guard let extractedText,
                      !extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                let result = await processText(extractedText, profile: profile)
                resolved.payloads[index] = .scannedDocument(
                    pages: pages,
                    pdf: pdf,
                    extractedText: result.text
                )
                mergeMetadata(
                    result,
                    title: &generatedTitle,
                    category: &generatedCategory,
                    tags: &generatedTags
                )

            case .url, .retainedAudio, .image, .file, .sketch:
                continue
            }
        }

        if resolved.frontmatter["title"] == nil, let generatedTitle = nonEmpty(generatedTitle) {
            resolved.frontmatter["title"] = generatedTitle
        }
        if resolved.frontmatter["category"] == nil,
           resolved.frontmatter["type"] == nil,
           let generatedCategory = nonEmpty(generatedCategory) {
            resolved.frontmatter["category"] = generatedCategory
        }
        let combinedTags = unique(profile.staticTags + generatedTags)
        if !combinedTags.isEmpty {
            resolved.frontmatter["tags"] = "[" + combinedTags.joined(separator: ", ") + "]"
        }
        resolved.voxProcessingState = .applied
        return resolved
    }

    private func processText(
        _ text: String,
        profile: CapturePresetProfile
    ) async -> CapturePresetTextProcessingResult {
        if let textProcessor,
           let result = try? await textProcessor.process(text: text, profile: profile),
           !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return result
        }
        return CapturePresetTextProcessingResult(
            text: Self.deterministicText(text, mode: profile.postProcessingMode),
            tags: profile.staticTags,
            category: profile.staticCategory
        )
    }

    public static func deterministicText(
        _ text: String,
        mode: CapturePresetProcessingMode
    ) -> String {
        switch mode {
        case .todoList:
            return formatTodoList(text)
        case .none, .clean, .meetingNotes, .custom:
            return text
        }
    }

    private static func formatTodoList(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .flatMap { line -> [String] in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return [] }
                if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") {
                    return [trimmed]
                }
                let withoutBullet: String
                if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    withoutBullet = String(trimmed.dropFirst(2))
                } else {
                    withoutBullet = trimmed
                }
                return withoutBullet
                    .split(separator: ".", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { "- [ ] " + uppercaseFirst($0) }
            }
        return lines.isEmpty ? text : lines.joined(separator: "\n")
    }

    private static func uppercaseFirst(_ value: String) -> String {
        guard let first = value.first else { return value }
        return String(first).uppercased() + value.dropFirst()
    }

    private func mergeMetadata(
        _ result: CapturePresetTextProcessingResult,
        title: inout String?,
        category: inout String?,
        tags: inout [String]
    ) {
        if title == nil { title = nonEmpty(result.title) }
        if category == nil { category = nonEmpty(result.category) }
        tags = unique(tags + result.tags)
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !normalized.isEmpty && seen.insert(normalized).inserted
        }
    }
}

// Legacy source compatibility.
public typealias CaptureVoxTextProcessingResult = CapturePresetTextProcessingResult
public typealias CaptureVoxTextProcessing = CapturePresetTextProcessing
public typealias CaptureVoxRequestProcessor = CapturePresetRequestProcessor
