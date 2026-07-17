import Foundation

public enum TranscriptSearch {
    public static func matches(_ transcript: Transcript, query: String) -> Bool {
        let tokens = normalized(query)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return true }

        let searchable = normalized([
            transcript.text,
            transcript.cleanedText,
            transcript.title,
            transcript.tags?.joined(separator: " "),
            transcript.category,
            transcript.modelUsed,
            transcript.language,
        ]
        .compactMap { $0 }
        .joined(separator: " "))

        return tokens.allSatisfy(searchable.contains)
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }
}
