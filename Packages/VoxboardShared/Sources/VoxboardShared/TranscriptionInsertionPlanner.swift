import Foundation

/// Computes the portion of a completed transcript that has not already been
/// inserted from cumulative live Apple Speech updates.
public enum TranscriptionInsertionPlanner {
    public enum Plan: Equatable, Sendable {
        case insert(String)
        case alreadyComplete
        case unsafeMismatch
    }

    public static func plan(deliveredText: String, finalText: String) -> Plan {
        guard !finalText.isEmpty else { return .alreadyComplete }
        guard !deliveredText.isEmpty else { return .insert(finalText) }

        if finalText.hasPrefix(deliveredText) {
            let suffix = String(finalText.dropFirst(deliveredText.count))
            return suffix.isEmpty ? .alreadyComplete : .insert(suffix)
        }

        // A batch fallback can differ from live Apple output only in punctuation,
        // casing, or spacing. Reconcile by words while preserving the untouched
        // suffix from the final transcript. Never guess across a word mismatch.
        let deliveredWords = wordTokens(in: deliveredText)
        let finalWords = wordTokens(in: finalText)
        guard !deliveredWords.isEmpty,
              deliveredWords.count <= finalWords.count else {
            return .unsafeMismatch
        }

        for index in deliveredWords.indices {
            guard deliveredWords[index].word.compare(
                finalWords[index].word,
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ) == .orderedSame else {
                return .unsafeMismatch
            }
        }

        let deliveredTail = deliveredText[deliveredWords.last!.range.upperBound...]
        let deliveredAlreadyHasPunctuation = deliveredTail.unicodeScalars.contains { scalar in
            CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
        }

        let lastMatchedRange = finalWords[deliveredWords.count - 1].range
        if deliveredAlreadyHasPunctuation {
            guard deliveredWords.count < finalWords.count else {
                return .alreadyComplete
            }

            // Keep only whitespace between the matched final word and the next
            // word. The field already contains punctuation from the live result,
            // so carrying fallback punctuation too would produce strings like ".!".
            let nextWordRange = finalWords[deliveredWords.count].range
            let separator = finalText[lastMatchedRange.upperBound..<nextWordRange.lowerBound]
                .filter(\.isWhitespace)
            let suffix = separator + finalText[nextWordRange.lowerBound...]
            return suffix.isEmpty ? .alreadyComplete : .insert(String(suffix))
        }

        let suffix = String(finalText[lastMatchedRange.upperBound...])
        return suffix.isEmpty ? .alreadyComplete : .insert(suffix)
    }

    private static func wordTokens(in text: String) -> [(word: String, range: Range<String.Index>)] {
        var tokens: [(String, Range<String.Index>)] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .localized]
        ) { substring, range, _, _ in
            if let substring, !substring.isEmpty {
                tokens.append((substring, range))
            }
        }
        return tokens
    }
}
