import Foundation

/// Reconciles a replaceable live-transcription tail with an editable Capture draft.
///
/// Apple Speech volatile results may revise earlier words, so the preview block is
/// replaced as recognition progresses. Finalization swaps that same block for the
/// committed transcript instead of appending a duplicate.
public struct LiveTranscriptDraftPreview: Equatable, Sendable {
    private var renderedBlock = ""

    public init() {}

    public var isRendering: Bool { !renderedBlock.isEmpty }

    public mutating func render(
        finalizedText: String,
        volatileText: String?,
        in currentDraft: String
    ) -> String {
        let base = removingRenderedBlock(from: currentDraft)
        let transcript = Self.merged(finalizedText: finalizedText, volatileText: volatileText)
        renderedBlock = Self.block(for: transcript, appendedTo: base)
        return base + renderedBlock
    }

    public mutating func commit(_ transcript: String, in currentDraft: String) -> String {
        let base = removingRenderedBlock(from: currentDraft)
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        renderedBlock = ""
        return base + Self.block(for: normalized, appendedTo: base)
    }

    public mutating func cancel(in currentDraft: String) -> String {
        let base = removingRenderedBlock(from: currentDraft)
        renderedBlock = ""
        return base
    }

    private mutating func removingRenderedBlock(from draft: String) -> String {
        guard !renderedBlock.isEmpty else { return draft }
        if draft.hasSuffix(renderedBlock) {
            return String(draft.dropLast(renderedBlock.count))
        }
        guard let range = draft.range(of: renderedBlock, options: .backwards) else {
            // Preserve user edits if the preview itself was manually changed.
            return draft
        }
        var updated = draft
        updated.removeSubrange(range)
        return updated
    }

    private static func merged(finalizedText: String, volatileText: String?) -> String {
        let finalized = finalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let volatile = (volatileText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch (finalized.isEmpty, volatile.isEmpty) {
        case (true, true): return ""
        case (false, true): return finalized
        case (true, false): return volatile
        case (false, false): return finalized + " " + volatile
        }
    }

    private static func block(for transcript: String, appendedTo base: String) -> String {
        guard !transcript.isEmpty else { return "" }
        let separator = base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n"
        return separator + transcript
    }
}
