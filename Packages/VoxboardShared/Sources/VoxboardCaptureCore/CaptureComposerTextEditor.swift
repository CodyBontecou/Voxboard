import Foundation

/// A UIKit-compatible selection measured in UTF-16 code units.
///
/// The editor clamps this value to the input text and expands non-empty ranges
/// to composed-character boundaries before applying a command.
public struct CaptureTextSelection: Equatable, Sendable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public init(_ range: NSRange) {
        self.init(location: range.location, length: range.length)
    }

    public var nsRange: NSRange {
        NSRange(location: location, length: length)
    }
}

public typealias CaptureComposerSelection = CaptureTextSelection

public struct CaptureTextEditResult: Equatable, Sendable {
    public var text: String
    public var selection: CaptureTextSelection

    public init(text: String, selection: CaptureTextSelection) {
        self.text = text
        self.selection = selection
    }
}

public typealias CaptureComposerEditResult = CaptureTextEditResult

/// Framework-independent commands for the Quick Capture Markdown composer.
public enum CaptureComposerCommand: Equatable, Sendable {
    case toggleBold
    case toggleItalic
    case insertHashtag
    case heading(level: Int)
    case taskCheckbox
    case bullet
    case markdownLink(destination: String? = nil)
    case wikiLink(target: String? = nil)
    case replaceSelection(with: String)
    case lowercase
    case uppercase
    case sentenceCase
    case capitalizeWords
    case slugify

    public static var bold: Self { .toggleBold }
    public static var italic: Self { .toggleItalic }
}

/// Applies selection-aware Markdown edits without depending on UIKit or SwiftUI.
///
/// Input and command-provided text use a documented LF policy: CRLF and lone CR
/// are normalized to LF. Input selections are translated from the original
/// UTF-16 offsets before the edit is applied.
public struct CaptureComposerTextEditor: Sendable {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    public init() {}

    public func applying(
        _ command: CaptureComposerCommand,
        to text: String,
        selection: CaptureTextSelection
    ) -> CaptureTextEditResult {
        let input = normalizedInput(text: text, selection: selection)

        switch command {
        case .toggleBold:
            return toggling(marker: "**", in: input.text, selection: input.selection)
        case .toggleItalic:
            return toggling(marker: "*", in: input.text, selection: input.selection)
        case .insertHashtag:
            return insertingHashtag(in: input.text, selection: input.selection)
        case .heading(let level):
            guard (1...6).contains(level) else {
                return CaptureTextEditResult(text: input.text, selection: input.selection)
            }
            return applyingLinePrefix(
                .heading(level: level),
                to: input.text,
                selection: input.selection
            )
        case .taskCheckbox:
            return applyingLinePrefix(.task, to: input.text, selection: input.selection)
        case .bullet:
            return applyingLinePrefix(.bullet, to: input.text, selection: input.selection)
        case .markdownLink(let destination):
            return insertingMarkdownLink(
                destination: destination,
                in: input.text,
                selection: input.selection
            )
        case .wikiLink(let target):
            return insertingWikiLink(target: target, in: input.text, selection: input.selection)
        case .replaceSelection(let replacement):
            let replacement = normalizeNewlines(replacement)
            return replacing(
                input.selection.nsRange,
                with: replacement,
                in: input.text,
                selection: CaptureTextSelection(
                    location: input.selection.location + utf16Length(replacement),
                    length: 0
                )
            )
        case .lowercase:
            return transformingSelection(in: input) {
                $0.lowercased(with: Self.posixLocale)
            }
        case .uppercase:
            return transformingSelection(in: input) {
                $0.uppercased(with: Self.posixLocale)
            }
        case .sentenceCase:
            return transformingSelection(in: input, transform: sentenceCased)
        case .capitalizeWords:
            return transformingSelection(in: input, transform: wordsCapitalized)
        case .slugify:
            return transformingSelection(in: input, transform: slugified)
        }
    }

    public func applying(
        _ command: CaptureComposerCommand,
        to text: String,
        selection: NSRange
    ) -> CaptureTextEditResult {
        applying(command, to: text, selection: CaptureTextSelection(selection))
    }

    // MARK: - Inline Markdown

    private func toggling(
        marker: String,
        in text: String,
        selection: CaptureTextSelection
    ) -> CaptureTextEditResult {
        let source = text as NSString
        let markerLength = utf16Length(marker)
        let selectedRange = selection.nsRange

        if selection.length == 0 {
            let prefixLocation = selection.location - markerLength
            let suffixLocation = selection.location
            if prefixLocation >= 0,
               suffixLocation + markerLength <= source.length,
               source.substring(with: NSRange(location: prefixLocation, length: markerLength)) == marker,
               source.substring(with: NSRange(location: suffixLocation, length: markerLength)) == marker,
               hasExactMarkerRun(
                    marker: marker,
                    prefixLocation: prefixLocation,
                    suffixEnd: suffixLocation + markerLength,
                    in: source
               ) {
                return replacing(
                    NSRange(location: prefixLocation, length: markerLength * 2),
                    with: "",
                    in: text,
                    selection: CaptureTextSelection(location: prefixLocation, length: 0)
                )
            }

            return replacing(
                selectedRange,
                with: marker + marker,
                in: text,
                selection: CaptureTextSelection(
                    location: selection.location + markerLength,
                    length: 0
                )
            )
        }

        let selected = source.substring(with: selectedRange)
        if selectedRange.length >= markerLength * 2,
           selected.hasPrefix(marker),
           selected.hasSuffix(marker),
           isExactFullWrapper(selected, marker: marker) {
            let innerLength = selectedRange.length - markerLength * 2
            let inner = (selected as NSString).substring(
                with: NSRange(location: markerLength, length: innerLength)
            )
            return replacing(
                selectedRange,
                with: inner,
                in: text,
                selection: CaptureTextSelection(location: selectedRange.location, length: innerLength)
            )
        }

        let prefixLocation = selectedRange.location - markerLength
        let suffixLocation = NSMaxRange(selectedRange)
        if prefixLocation >= 0,
           suffixLocation + markerLength <= source.length,
           source.substring(with: NSRange(location: prefixLocation, length: markerLength)) == marker,
           source.substring(with: NSRange(location: suffixLocation, length: markerLength)) == marker,
           hasExactMarkerRun(
                marker: marker,
                prefixLocation: prefixLocation,
                suffixEnd: suffixLocation + markerLength,
                in: source
           ) {
            return replacing(
                NSRange(
                    location: prefixLocation,
                    length: selectedRange.length + markerLength * 2
                ),
                with: selected,
                in: text,
                selection: CaptureTextSelection(
                    location: prefixLocation,
                    length: selectedRange.length
                )
            )
        }

        return replacing(
            selectedRange,
            with: marker + selected + marker,
            in: text,
            selection: CaptureTextSelection(
                location: selectedRange.location + markerLength,
                length: selectedRange.length
            )
        )
    }

    private func hasExactMarkerRun(
        marker: String,
        prefixLocation: Int,
        suffixEnd: Int,
        in source: NSString
    ) -> Bool {
        guard marker.first == "*" else { return true }
        if prefixLocation > 0,
           source.substring(with: NSRange(location: prefixLocation - 1, length: 1)) == "*" {
            return false
        }
        if suffixEnd < source.length,
           source.substring(with: NSRange(location: suffixEnd, length: 1)) == "*" {
            return false
        }
        return true
    }

    private func isExactFullWrapper(_ value: String, marker: String) -> Bool {
        guard marker == "*" else {
            if marker == "**" {
                return !value.hasPrefix("***") && !value.hasSuffix("***")
            }
            return true
        }
        return !value.hasPrefix("**") && !value.hasSuffix("**")
    }

    private func insertingHashtag(
        in text: String,
        selection: CaptureTextSelection
    ) -> CaptureTextEditResult {
        let selected = (text as NSString).substring(with: selection.nsRange)
        let replacement = "#" + selected
        let resultSelection = selection.length == 0
            ? CaptureTextSelection(location: selection.location + 1, length: 0)
            : CaptureTextSelection(location: selection.location + 1, length: selection.length)
        return replacing(
            selection.nsRange,
            with: replacement,
            in: text,
            selection: resultSelection
        )
    }

    private func insertingMarkdownLink(
        destination: String?,
        in text: String,
        selection: CaptureTextSelection
    ) -> CaptureTextEditResult {
        let selected = (text as NSString).substring(with: selection.nsRange)
        let hasSelectedLabel = selection.length > 0
        let label = hasSelectedLabel ? escapedMarkdownLabel(selected) : "link text"
        let normalizedDestination = destination.map(normalizeNewlines)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasProvidedDestination = !(normalizedDestination ?? "").isEmpty
        let linkDestination = hasProvidedDestination
            ? escapedMarkdownDestination(normalizedDestination!)
            : "url"
        let replacement = "[\(label)](\(linkDestination))"

        let resultSelection: CaptureTextSelection
        if hasSelectedLabel && !hasProvidedDestination {
            resultSelection = CaptureTextSelection(
                location: selection.location + 1 + utf16Length(label) + 2,
                length: utf16Length(linkDestination)
            )
        } else if !hasSelectedLabel {
            resultSelection = CaptureTextSelection(
                location: selection.location + 1,
                length: utf16Length(label)
            )
        } else {
            resultSelection = CaptureTextSelection(
                location: selection.location + utf16Length(replacement),
                length: 0
            )
        }

        return replacing(
            selection.nsRange,
            with: replacement,
            in: text,
            selection: resultSelection
        )
    }

    private func insertingWikiLink(
        target: String?,
        in text: String,
        selection: CaptureTextSelection
    ) -> CaptureTextEditResult {
        let selected = (text as NSString).substring(with: selection.nsRange)
        let normalizedTarget = target.map(normalizeNewlines)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasProvidedTarget = !(normalizedTarget ?? "").isEmpty
        let body: String
        if selection.length > 0 {
            body = selected
        } else if hasProvidedTarget {
            body = normalizedTarget!
        } else {
            body = "Note"
        }
        let replacement = "[[\(body)]]"

        let resultSelection: CaptureTextSelection
        if selection.length > 0 || !hasProvidedTarget {
            resultSelection = CaptureTextSelection(
                location: selection.location + 2,
                length: utf16Length(body)
            )
        } else {
            resultSelection = CaptureTextSelection(
                location: selection.location + utf16Length(replacement),
                length: 0
            )
        }
        return replacing(
            selection.nsRange,
            with: replacement,
            in: text,
            selection: resultSelection
        )
    }

    // MARK: - Line Markdown

    private enum LinePrefix {
        case heading(level: Int)
        case task
        case bullet
    }

    private struct TextEdit {
        let range: NSRange
        let replacement: String
    }

    private func applyingLinePrefix(
        _ prefix: LinePrefix,
        to text: String,
        selection: CaptureTextSelection
    ) -> CaptureTextEditResult {
        let source = text as NSString
        let lineRanges = selectedLineRanges(in: source, selection: selection)
        let edits = lineRanges.map { prefixEdit(prefix, for: $0, in: source) }
            .sorted { $0.range.location < $1.range.location }
        let mappedStart = mappedOffset(selection.location, through: edits)
        let mappedEnd = mappedOffset(selection.location + selection.length, through: edits)

        let mutable = NSMutableString(string: text)
        for edit in edits.reversed() {
            mutable.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return CaptureTextEditResult(
            text: mutable as String,
            selection: CaptureTextSelection(
                location: mappedStart,
                length: max(0, mappedEnd - mappedStart)
            )
        )
    }

    private func selectedLineRanges(
        in source: NSString,
        selection: CaptureTextSelection
    ) -> [NSRange] {
        let start = lineStart(at: selection.location, in: source)
        let lastSelectedOffset = selection.length > 0
            ? max(selection.location, selection.location + selection.length - 1)
            : selection.location
        let finalLineStart = lineStart(at: lastSelectedOffset, in: source)
        var ranges: [NSRange] = []
        var cursor = start

        while cursor <= finalLineStart {
            let end = lineEnd(at: cursor, in: source)
            ranges.append(NSRange(location: cursor, length: end - cursor))
            guard end < source.length else { break }
            cursor = end + 1
        }
        return ranges
    }

    private func lineStart(at offset: Int, in source: NSString) -> Int {
        guard offset > 0 else { return 0 }
        let searchEnd = min(offset, source.length)
        let range = source.range(
            of: "\n",
            options: .backwards,
            range: NSRange(location: 0, length: searchEnd)
        )
        return range.location == NSNotFound ? 0 : NSMaxRange(range)
    }

    private func lineEnd(at offset: Int, in source: NSString) -> Int {
        guard offset < source.length else { return source.length }
        let range = source.range(
            of: "\n",
            range: NSRange(location: offset, length: source.length - offset)
        )
        return range.location == NSNotFound ? source.length : range.location
    }

    private func prefixEdit(
        _ prefix: LinePrefix,
        for lineRange: NSRange,
        in source: NSString
    ) -> TextEdit {
        let line = source.substring(with: lineRange) as NSString
        let indentLength = leadingIndentLength(in: line)
        let existingLength: Int
        let replacement: String

        switch prefix {
        case .heading(let level):
            existingLength = existingHeadingPrefixLength(in: line, after: indentLength)
            replacement = String(repeating: "#", count: level) + " "
        case .task:
            existingLength = existingListPrefixLength(in: line, after: indentLength)
            replacement = "- [ ] "
        case .bullet:
            existingLength = existingListPrefixLength(in: line, after: indentLength)
            replacement = "- "
        }

        return TextEdit(
            range: NSRange(
                location: lineRange.location + indentLength,
                length: existingLength
            ),
            replacement: replacement
        )
    }

    private func leadingIndentLength(in line: NSString) -> Int {
        var cursor = 0
        while cursor < line.length {
            let character = line.character(at: cursor)
            guard character == 32 || character == 9 else { break }
            cursor += 1
        }
        return cursor
    }

    private func existingHeadingPrefixLength(in line: NSString, after indent: Int) -> Int {
        var cursor = indent
        while cursor < line.length, line.character(at: cursor) == 35 {
            cursor += 1
        }
        let hashCount = cursor - indent
        guard (1...6).contains(hashCount),
              cursor == line.length
                || line.character(at: cursor) == 32
                || line.character(at: cursor) == 9 else {
            return 0
        }
        while cursor < line.length {
            let character = line.character(at: cursor)
            guard character == 32 || character == 9 else { break }
            cursor += 1
        }
        return cursor - indent
    }

    private func existingListPrefixLength(in line: NSString, after indent: Int) -> Int {
        guard indent < line.length else { return 0 }
        let remainder = line.substring(from: indent)
        let pattern = #"^(?:[-+*][ \t]+(?:\[[ xX]\](?:[ \t]+|$))?|[0-9]+[.)][ \t]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: remainder,
                range: NSRange(location: 0, length: (remainder as NSString).length)
              ) else {
            return 0
        }
        return match.range.length
    }

    private func mappedOffset(_ offset: Int, through edits: [TextEdit]) -> Int {
        var delta = 0
        for edit in edits {
            let replacementLength = utf16Length(edit.replacement)
            let editEnd = NSMaxRange(edit.range)
            if offset < edit.range.location {
                break
            }
            if edit.range.length > 0, offset < editEnd {
                return edit.range.location + delta + replacementLength
            }
            delta += replacementLength - edit.range.length
        }
        return offset + delta
    }

    // MARK: - Text transforms

    private struct NormalizedInput {
        let text: String
        let selection: CaptureTextSelection
    }

    private func transformingSelection(
        in input: NormalizedInput,
        transform: (String) -> String
    ) -> CaptureTextEditResult {
        guard input.selection.length > 0 else {
            return CaptureTextEditResult(text: input.text, selection: input.selection)
        }
        let selected = (input.text as NSString).substring(with: input.selection.nsRange)
        let transformed = transform(selected)
        return replacing(
            input.selection.nsRange,
            with: transformed,
            in: input.text,
            selection: CaptureTextSelection(
                location: input.selection.location,
                length: utf16Length(transformed)
            )
        )
    }

    private func sentenceCased(_ value: String) -> String {
        let lowered = value.lowercased(with: Self.posixLocale)
        var result = ""
        var awaitsSentenceStart = true

        for character in lowered {
            if awaitsSentenceStart, characterContainsLetter(character) {
                result += String(character).uppercased(with: Self.posixLocale)
                awaitsSentenceStart = false
            } else {
                result.append(character)
                if characterContainsLetter(character) || characterContainsNumber(character) {
                    awaitsSentenceStart = false
                }
            }

            if character == "." || character == "!" || character == "?" || character == "\n" {
                awaitsSentenceStart = true
            }
        }
        return result
    }

    private func wordsCapitalized(_ value: String) -> String {
        let lowered = value.lowercased(with: Self.posixLocale)
        var result = ""
        var awaitsWordStart = true
        var isInsideWord = false

        for character in lowered {
            let isLetter = characterContainsLetter(character)
            let isNumber = characterContainsNumber(character)
            if awaitsWordStart, isLetter {
                result += String(character).uppercased(with: Self.posixLocale)
                awaitsWordStart = false
                isInsideWord = true
            } else {
                result.append(character)
                if isLetter || isNumber {
                    awaitsWordStart = false
                    isInsideWord = true
                } else if character == "'" || character == "’" {
                    awaitsWordStart = !isInsideWord
                } else {
                    awaitsWordStart = true
                    isInsideWord = false
                }
            }
        }
        return result
    }

    private func slugified(_ value: String) -> String {
        let folded = value
            .folding(
                options: [.diacriticInsensitive, .widthInsensitive],
                locale: Self.posixLocale
            )
            .lowercased(with: Self.posixLocale)
        var result = ""
        var needsSeparator = false

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if needsSeparator, !result.isEmpty {
                    result.append("-")
                }
                result.unicodeScalars.append(scalar)
                needsSeparator = false
            } else if !result.isEmpty {
                needsSeparator = true
            }
        }
        return result
    }

    private func characterContainsLetter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    private func characterContainsNumber(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
    }

    // MARK: - Selection and replacement

    private func normalizedInput(
        text: String,
        selection: CaptureTextSelection
    ) -> NormalizedInput {
        let original = text as NSString
        let originalLength = original.length
        let rawStart = clamped(selection.location, to: 0...originalLength)
        let rawEnd: Int
        if selection.length <= 0 {
            rawEnd = rawStart
        } else {
            let (sum, overflow) = selection.location.addingReportingOverflow(selection.length)
            let proposedEnd = overflow ? Int.max : sum
            rawEnd = max(rawStart, clamped(proposedEnd, to: 0...originalLength))
        }

        let normalizedText = normalizeNewlines(text)
        let normalizedStart = normalizedUTF16Offset(rawStart, in: original)
        let normalizedEnd = normalizedUTF16Offset(rawEnd, in: original)
        let bounded = CaptureTextSelection(
            location: normalizedStart,
            length: max(0, normalizedEnd - normalizedStart)
        )
        return NormalizedInput(
            text: normalizedText,
            selection: composedCharacterSafeSelection(bounded, in: normalizedText as NSString)
        )
    }

    private func composedCharacterSafeSelection(
        _ selection: CaptureTextSelection,
        in source: NSString
    ) -> CaptureTextSelection {
        guard source.length > 0 else {
            return CaptureTextSelection(location: 0, length: 0)
        }
        if selection.length > 0 {
            let range = source.rangeOfComposedCharacterSequences(for: selection.nsRange)
            return CaptureTextSelection(range)
        }
        guard selection.location < source.length else {
            return CaptureTextSelection(location: source.length, length: 0)
        }
        let sequence = source.rangeOfComposedCharacterSequence(at: selection.location)
        let location = sequence.location == selection.location
            ? selection.location
            : sequence.location
        return CaptureTextSelection(location: location, length: 0)
    }

    private func normalizedUTF16Offset(_ offset: Int, in source: NSString) -> Int {
        var sourceOffset = 0
        var normalizedOffset = 0
        while sourceOffset < offset {
            if source.character(at: sourceOffset) == 13 {
                let isCRLF = sourceOffset + 1 < source.length
                    && source.character(at: sourceOffset + 1) == 10
                if isCRLF {
                    if offset == sourceOffset + 1 {
                        return normalizedOffset + 1
                    }
                    sourceOffset += 2
                    normalizedOffset += 1
                    continue
                }
            }
            sourceOffset += 1
            normalizedOffset += 1
        }
        return normalizedOffset
    }

    private func replacing(
        _ range: NSRange,
        with replacement: String,
        in text: String,
        selection: CaptureTextSelection
    ) -> CaptureTextEditResult {
        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: range, with: replacement)
        return CaptureTextEditResult(text: mutable as String, selection: selection)
    }

    private func normalizeNewlines(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func escapedMarkdownLabel(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private func escapedMarkdownDestination(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ")", with: "\\)")
            .replacingOccurrences(of: "\n", with: "")
    }

    private func utf16Length(_ value: String) -> Int {
        (value as NSString).length
    }

    private func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
