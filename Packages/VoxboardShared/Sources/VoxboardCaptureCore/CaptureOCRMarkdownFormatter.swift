import Foundation

/// Converts ordered OCR page output into plain Markdown suitable for the capture editor.
/// Empty pages are omitted while recognized page order and line breaks are preserved.
public struct CaptureOCRMarkdownFormatter: Sendable {
    public init() {}

    public func render(pageTexts: [String]) -> String {
        pageTexts
            .map(normalizePageText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func normalizePageText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
