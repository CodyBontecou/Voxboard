import Foundation

/// Lightweight, deterministic flow formatter used as a private fallback when
/// Apple Intelligence is unavailable or skipped by the selected Capture Preset. It
/// deliberately avoids adding new information; it only reshapes the recognized text.
public enum TranscriptFlowFormatter {

    public static func apply(flow: CapturePreset?, to transcript: Transcript) -> Transcript {
        guard let flow else { return transcript }

        let baseText = transcript.cleanedText?.isEmpty == false ? transcript.cleanedText! : transcript.text
        let formattedText: String?
        switch flow.postProcessingMode {
        case .none:
            formattedText = nil
        case .clean, .custom:
            formattedText = nil
        case .todoList:
            formattedText = formatTodoList(baseText)
        case .meetingNotes:
            formattedText = formatMeetingNotes(baseText)
        }

        let mergedTags = mergeTags(transcript.tags ?? [], flow.staticTags)
        let category = transcript.category ?? flow.staticCategory

        guard formattedText != nil || !mergedTags.isEmpty || category != nil else {
            return transcript
        }

        return transcript.withEnrichment(
            title: transcript.title,
            tags: mergedTags.isEmpty ? transcript.tags : mergedTags,
            category: category,
            cleanedText: formattedText ?? transcript.cleanedText
        )
    }

    public static func mergeTags(_ first: [String], _ second: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in first + second {
            let tag = raw
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: " #\t\n\r"))
            guard !tag.isEmpty, seen.insert(tag).inserted else { continue }
            out.append(tag)
        }
        return out
    }

    public static func formatTodoList(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed
            .components(separatedBy: .newlines)
            .map(cleanTodoItem)
            .filter { !$0.isEmpty }

        if lines.count > 1 || startsWithListMarker(trimmed) {
            return lines.map { "- [ ] \($0)" }.joined(separator: "\n")
        }

        let items = splitIntoItems(text)
            .map(cleanTodoItem)
            .filter { !$0.isEmpty }
        guard !items.isEmpty else { return text }
        return items.map { "- [ ] \($0)" }.joined(separator: "\n")
    }

    public static func formatMeetingNotes(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let items = splitIntoItems(trimmed)
        let actionItems = items
            .filter { looksActionable($0) }
            .map(cleanTodoItem)
            .filter { !$0.isEmpty }

        var sections: [String] = ["## Notes\n\n\(trimmed)"]
        if !actionItems.isEmpty {
            sections.append("## Action Items\n\n" + actionItems.map { "- [ ] \($0)" }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func splitIntoItems(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: ";", with: ".")
            .replacingOccurrences(of: " and then ", with: ". ", options: [.caseInsensitive])
            .replacingOccurrences(of: " then ", with: ". ", options: [.caseInsensitive])

        return normalized
            .components(separatedBy: CharacterSet(charactersIn: "\n.?!"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func cleanTodoItem(_ raw: String) -> String {
        var item = stripListMarker(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let prefixes = [
            "i need to ", "i have to ", "i should ", "we need to ", "we have to ",
            "todo ", "to do ", "task ", "remember to ", "remind me to ", "please "
        ]
        let lower = item.lowercased()
        for prefix in prefixes where lower.hasPrefix(prefix) {
            item.removeFirst(prefix.count)
            break
        }
        item = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !item.isEmpty else { return "" }
        return item.prefix(1).uppercased() + String(item.dropFirst())
    }

    private static func startsWithListMarker(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return stripListMarker(trimmed) != trimmed
    }

    private static func stripListMarker(_ raw: String) -> String {
        var item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let markers = [
            "- [ ] ", "- [x] ", "- [X] ",
            "* [ ] ", "* [x] ", "* [X] ",
            "• [ ] ", "• [x] ", "• [X] ",
            "☐ ", "□ ", "- ", "* ", "• "
        ]

        var stripped = true
        while stripped {
            stripped = false
            for marker in markers where item.hasPrefix(marker) {
                item.removeFirst(marker.count)
                item = item.trimmingCharacters(in: .whitespacesAndNewlines)
                stripped = true
                break
            }
            if !stripped, let numbered = stripNumberedListMarker(item) {
                item = numbered
                stripped = true
            }
        }
        return item
    }

    private static func stripNumberedListMarker(_ raw: String) -> String? {
        var digitCount = 0
        for character in raw {
            guard character.isNumber else { break }
            digitCount += 1
        }
        guard digitCount > 0, raw.count > digitCount else { return nil }
        let separatorIndex = raw.index(raw.startIndex, offsetBy: digitCount)
        guard raw[separatorIndex] == "." || raw[separatorIndex] == ")" else { return nil }
        let afterSeparator = raw.index(after: separatorIndex)
        guard afterSeparator < raw.endIndex, raw[afterSeparator].isWhitespace else { return nil }
        return String(raw[afterSeparator...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksActionable(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        let markers = [
            "action item", "todo", "to do", "follow up", "need to", "needs to",
            "should", "assign", "send", "schedule", "call", "email", "finish"
        ]
        return markers.contains { lower.contains($0) }
    }
}
