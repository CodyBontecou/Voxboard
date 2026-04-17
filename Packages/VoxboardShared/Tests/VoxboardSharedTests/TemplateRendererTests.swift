import XCTest
@testable import VoxboardShared

final class TemplateRendererTests: XCTestCase {

    private func makeTranscript(
        text: String = "Raw transcript text.",
        title: String? = nil,
        tags: [String]? = nil,
        category: String? = nil,
        cleanedText: String? = nil
    ) -> Transcript {
        Transcript(text: text, duration: 5.0, modelUsed: "Parakeet v3", language: "auto")
            .withEnrichment(title: title, tags: tags, category: category, cleanedText: cleanedText)
    }

    private func fixedDate() -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 17
        comps.hour = 12; comps.minute = 34; comps.second = 56
        comps.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    // MARK: - Expression resolution

    func test_render_resolvesTpDateNowWithYYYYMMDD() {
        let template = """
        ---
        date: <% tp.date.now("YYYY-MM-DD") %>
        ---
        """
        let ctx = TemplateRenderer.Context(transcript: makeTranscript(), now: fixedDate())
        let out = TemplateRenderer.render(template: template, context: ctx)
        XCTAssertTrue(out.contains("date: 2026-04-17"), "Output:\n\(out)")
    }

    func test_render_resolvesCryptoRandomUUID() {
        let template = """
        ---
        id: <% crypto.randomUUID() %>
        ---
        """
        let ctx = TemplateRenderer.Context(transcript: makeTranscript(), now: fixedDate())
        let out = TemplateRenderer.render(template: template, context: ctx)
        let pattern = #"id: [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#
        let regex = try! NSRegularExpression(pattern: pattern)
        XCTAssertFalse(regex.matches(in: out, range: NSRange(out.startIndex..., in: out)).isEmpty,
                       "Output:\n\(out)")
    }

    func test_render_leavesUnknownExpressionsIntact() {
        let template = """
        ---
        thing: <% tp.unknown.func() %>
        ---
        """
        let ctx = TemplateRenderer.Context(transcript: makeTranscript(), now: fixedDate())
        let out = TemplateRenderer.render(template: template, context: ctx)
        XCTAssertTrue(out.contains("<% tp.unknown.func() %>"), "Output:\n\(out)")
    }

    // MARK: - Frontmatter enrichment fill

    func test_render_fillsEmptyTagsFromEnrichment() {
        let template = """
        ---
        tags: []
        ---
        """
        let ctx = TemplateRenderer.Context(
            transcript: makeTranscript(tags: ["video", "idea"]),
            now: fixedDate()
        )
        let out = TemplateRenderer.render(template: template, context: ctx)
        XCTAssertTrue(out.contains("tags: [\"video\", \"idea\"]"), "Output:\n\(out)")
    }

    func test_render_leavesPrefilledTagsAlone() {
        let template = """
        ---
        tags: [preset]
        ---
        """
        let ctx = TemplateRenderer.Context(
            transcript: makeTranscript(tags: ["other"]),
            now: fixedDate()
        )
        let out = TemplateRenderer.render(template: template, context: ctx)
        XCTAssertTrue(out.contains("tags: [preset]"), "Output:\n\(out)")
        XCTAssertFalse(out.contains("\"other\""), "Output:\n\(out)")
    }

    func test_render_fillsEmptyTitleFromEnrichment() {
        let template = """
        ---
        title:
        ---
        """
        let ctx = TemplateRenderer.Context(
            transcript: makeTranscript(title: "My Great Idea"),
            now: fixedDate()
        )
        let out = TemplateRenderer.render(template: template, context: ctx)
        XCTAssertTrue(out.contains("title: My Great Idea"), "Output:\n\(out)")
    }

    func test_render_preservesUnknownEmptyFields() {
        let template = """
        ---
        made:
        video_url:
        ---
        """
        let ctx = TemplateRenderer.Context(transcript: makeTranscript(), now: fixedDate())
        let out = TemplateRenderer.render(template: template, context: ctx)
        XCTAssertTrue(out.contains("made:"), "Output:\n\(out)")
        XCTAssertTrue(out.contains("video_url:"), "Output:\n\(out)")
    }

    // MARK: - Body composition

    func test_render_appendsTranscriptAfterFrontmatter() {
        let template = """
        ---
        date: <% tp.date.now("YYYY-MM-DD") %>
        ---
        """
        let transcript = makeTranscript(text: "Hello world.")
        let ctx = TemplateRenderer.Context(transcript: transcript, now: fixedDate())
        let out = TemplateRenderer.render(template: template, context: ctx)
        XCTAssertTrue(out.contains("Hello world."), "Output:\n\(out)")
        XCTAssertTrue(out.contains("date: 2026-04-17"), "Output:\n\(out)")

        if let fmEndRange = out.range(of: "---", options: .backwards),
           let transcriptRange = out.range(of: "Hello world.") {
            XCTAssertLessThan(fmEndRange.lowerBound, transcriptRange.lowerBound)
        } else {
            XCTFail("Missing frontmatter end or transcript body")
        }
    }

    func test_render_usesCleanedTextWhenPresent() {
        let template = """
        ---
        date: 2026-04-17
        ---
        """
        let ctx = TemplateRenderer.Context(
            transcript: makeTranscript(text: "raw", cleanedText: "Clean."),
            now: fixedDate()
        )
        let out = TemplateRenderer.render(template: template, context: ctx)
        XCTAssertTrue(out.contains("Clean."), "Output:\n\(out)")
        XCTAssertFalse(out.contains("raw"), "Output:\n\(out)")
    }

    func test_render_preservesTemplateBodyBetweenFrontmatterAndTranscript() {
        let template = """
        ---
        date: 2026-04-17
        ---
        ## Notes

        Template scaffold.
        """
        let ctx = TemplateRenderer.Context(
            transcript: makeTranscript(text: "Transcript."),
            now: fixedDate()
        )
        let out = TemplateRenderer.render(template: template, context: ctx)
        XCTAssertTrue(out.contains("## Notes"), "Output:\n\(out)")
        XCTAssertTrue(out.contains("Template scaffold."), "Output:\n\(out)")
        XCTAssertTrue(out.contains("Transcript."), "Output:\n\(out)")
    }

    // MARK: - Integration: the actual user template

    func test_render_userVideoIdeaTemplate() {
        let template = """
        ---
        id: <% crypto.randomUUID() %>
        tags: []
        date: <% tp.date.now("YYYY-MM-DD") %>
        made:
        video_url:
        ---
        """
        let ctx = TemplateRenderer.Context(
            transcript: makeTranscript(
                text: "Voice note content.",
                tags: ["video", "idea"]
            ),
            now: fixedDate()
        )
        let out = TemplateRenderer.render(template: template, context: ctx)

        XCTAssertTrue(out.contains("date: 2026-04-17"), "Output:\n\(out)")
        XCTAssertTrue(out.contains("tags: [\"video\", \"idea\"]"), "Output:\n\(out)")
        XCTAssertTrue(out.contains("made:"), "Output:\n\(out)")
        XCTAssertTrue(out.contains("video_url:"), "Output:\n\(out)")
        XCTAssertTrue(out.contains("Voice note content."), "Output:\n\(out)")

        // No unresolved templater expressions in final output
        XCTAssertFalse(out.contains("<% tp.date.now"), "Output:\n\(out)")
        XCTAssertFalse(out.contains("<% crypto.randomUUID"), "Output:\n\(out)")

        // Only one frontmatter block
        let occurrences = out.components(separatedBy: "---").count - 1
        XCTAssertEqual(occurrences, 2, "Expected exactly one frontmatter fence pair. Output:\n\(out)")
    }
}
