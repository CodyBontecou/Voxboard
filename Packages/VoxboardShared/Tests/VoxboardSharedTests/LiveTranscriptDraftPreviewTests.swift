import XCTest
@testable import VoxboardShared

final class LiveTranscriptDraftPreviewTests: XCTestCase {
    func testRenderPlacesLiveSpeechInsideEmptyDraft() {
        var preview = LiveTranscriptDraftPreview()

        let draft = preview.render(
            finalizedText: "Hello",
            volatileText: "world",
            in: ""
        )

        XCTAssertEqual(draft, "Hello world")
    }

    func testRenderAppendsToExistingDraftWithParagraphBreak() {
        var preview = LiveTranscriptDraftPreview()

        let draft = preview.render(
            finalizedText: "Spoken text",
            volatileText: nil,
            in: "Typed note"
        )

        XCTAssertEqual(draft, "Typed note\n\nSpoken text")
    }

    func testLaterVolatileResultReplacesEarlierPreview() {
        var preview = LiveTranscriptDraftPreview()
        let first = preview.render(
            finalizedText: "",
            volatileText: "A rough phrase",
            in: "Typed note"
        )

        let revised = preview.render(
            finalizedText: "A corrected",
            volatileText: "phrase",
            in: first
        )

        XCTAssertEqual(revised, "Typed note\n\nA corrected phrase")
    }

    func testRenderPreservesTypingAddedBeforePreview() {
        var preview = LiveTranscriptDraftPreview()
        let first = preview.render(
            finalizedText: "Live words",
            volatileText: nil,
            in: "Typed"
        )
        let edited = first.replacingOccurrences(of: "Typed", with: "Typed more")

        let revised = preview.render(
            finalizedText: "Live words continue",
            volatileText: nil,
            in: edited
        )

        XCTAssertEqual(revised, "Typed more\n\nLive words continue")
    }

    func testCommitReplacesPreviewWithoutDuplicatingTranscript() {
        var preview = LiveTranscriptDraftPreview()
        let liveDraft = preview.render(
            finalizedText: "Hello",
            volatileText: "world",
            in: "Typed note"
        )

        let committed = preview.commit("Hello world.", in: liveDraft)

        XCTAssertEqual(committed, "Typed note\n\nHello world.")
        XCTAssertFalse(preview.isRendering)
    }

    func testCancelRemovesOnlyLivePreview() {
        var preview = LiveTranscriptDraftPreview()
        let liveDraft = preview.render(
            finalizedText: "Temporary speech",
            volatileText: nil,
            in: "Keep this"
        )

        let cancelled = preview.cancel(in: liveDraft)

        XCTAssertEqual(cancelled, "Keep this")
        XCTAssertFalse(preview.isRendering)
    }
}
