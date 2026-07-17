import XCTest
@testable import VoxboardCaptureCore

final class MarkdownDocumentEditorTests: XCTestCase {
    private let requestID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    func test_prepend_insertsAfterLeadingFrontmatter() throws {
        let document = """
        ---
        title: Inbox
        tags: [manual]
        ---

        Existing note.
        """

        let result = try edit(document, entry: "Newest thought", placement: .prepend)

        XCTAssertTrue(result.hasPrefix("---\ntitle: Inbox\ntags: [manual]\n---\n\nNewest thought"))
        XCTAssertLessThan(try index(of: "Newest thought", in: result), try index(of: "Existing note.", in: result))
    }

    func test_append_preservesExactlyOneFrontmatterBlock() throws {
        let document = """
        ---
        title: Manual title
        tags: [manual]
        ---

        Existing note.
        """
        let entry = """
        ---
        title: Generated title
        category: idea
        tags: [voice, manual]
        ---

        Captured thought.
        """

        let result = try edit(document, entry: entry, placement: .append)

        XCTAssertEqual(result.components(separatedBy: "---").count - 1, 2)
        XCTAssertTrue(result.contains("title: Manual title"))
        XCTAssertFalse(result.contains("title: Generated title"))
        XCTAssertTrue(result.contains("category: idea"))
        XCTAssertTrue(result.contains("tags: [manual, voice]"))
        XCTAssertTrue(result.contains("Captured thought."))
    }

    func test_horizontalRuleEntryIsNotReinterpretedAsFrontmatter() throws {
        let document = "---\ntitle: Inbox\n---\n\nExisting"
        let entry = "---\nA visual divider\n---\nMore text"

        let result = try edit(document, entry: entry, placement: .append)

        XCTAssertTrue(result.hasPrefix("---\ntitle: Inbox\n---"))
        XCTAssertTrue(result.contains("---\nA visual divider\n---\nMore text"))
    }

    func test_prefixTemplateFrontmatterMergesIntoDocumentHeader() throws {
        let document = "---\ntags: [manual]\ntitle: Inbox\n---\n\nExisting"
        let prefix = "---\ntags: [quick]\nsource: widget\n---\n"

        let result = try edit(
            document,
            entry: "Captured",
            placement: .append,
            prefix: prefix
        )

        XCTAssertTrue(result.hasPrefix("---\ntags: [manual, quick]\ntitle: Inbox\nsource: widget\n---"))
        XCTAssertEqual(result.components(separatedBy: "\n---\n").count - 1, 1)
        XCTAssertTrue(result.contains("Existing\n\nCaptured"))
    }

    func test_blockStyleTagFrontmatterMergesWithoutLeavingOrphanListItems() throws {
        let document = "---\ntags:\n  - manual\ntitle: Inbox\n---\n\nExisting"
        let entry = "---\ntags: [voice]\n---\n\nCaptured"

        let result = try edit(document, entry: entry, placement: .append)

        XCTAssertTrue(result.contains("tags: [manual, voice]"))
        XCTAssertFalse(result.contains("  - manual"))
        XCTAssertTrue(result.contains("title: Inbox"))
    }

    func test_appendPreservesExistingMarkdownHardBreakSpaces() throws {
        let result = try edit("Existing line  \n", entry: "Captured", placement: .append)

        XCTAssertTrue(result.contains("Existing line  \n\nCaptured"))
    }

    func test_beneathHeading_insertsImmediatelyBelowExactHeading() throws {
        let document = """
        # Inbox

        Intro.

        ## Ideas

        Older idea.
        """
        let placement = CapturePlacement.beneathHeading(
            CaptureHeadingSelector(title: "Ideas", level: 2),
            missingHeadingBehavior: .fail
        )

        let result = try edit(document, entry: "New idea.", placement: placement)

        XCTAssertLessThan(try index(of: "## Ideas", in: result), try index(of: "New idea.", in: result))
        XCTAssertLessThan(try index(of: "New idea.", in: result), try index(of: "Older idea.", in: result))
    }

    func test_beneathHeading_ignoresCodeFenceHeadings() throws {
        let document = """
        ```markdown
        ## Ideas
        ```

        ## Ideas

        Real section.
        """
        let placement = CapturePlacement.beneathHeading(
            CaptureHeadingSelector(title: "Ideas", level: 2),
            missingHeadingBehavior: .fail
        )

        let result = try edit(document, entry: "Captured.", placement: placement)

        XCTAssertGreaterThan(try index(of: "Captured.", in: result), try index(of: "```\n\n## Ideas", in: result))
        XCTAssertLessThan(try index(of: "Captured.", in: result), try index(of: "Real section.", in: result))
    }

    func test_missingHeading_failsWhenPolicyIsFail() {
        let placement = CapturePlacement.beneathHeading(
            CaptureHeadingSelector(title: "Missing", level: 2),
            missingHeadingBehavior: .fail
        )

        XCTAssertThrowsError(try edit("# Inbox", entry: "Thought", placement: placement)) { error in
            XCTAssertEqual(
                error as? MarkdownDocumentEditorError,
                .headingNotFound(CaptureHeadingSelector(title: "Missing", level: 2))
            )
        }
    }

    func test_missingHeading_createsSectionWhenConfigured() throws {
        let placement = CapturePlacement.beneathHeading(
            CaptureHeadingSelector(title: "Ideas", level: 2),
            missingHeadingBehavior: .create
        )

        let result = try edit("# Inbox\n", entry: "Thought", placement: placement)

        XCTAssertTrue(result.contains("## Ideas\n\nThought"))
    }

    func test_prefixAndSuffix_wrapOnlyTheNewEntry() throws {
        let result = try edit(
            "Existing note.",
            entry: "Buy milk",
            placement: .append,
            prefix: "- [ ] ",
            suffix: " #inbox"
        )

        XCTAssertTrue(result.contains("Existing note.\n\n- [ ] Buy milk #inbox"))
        XCTAssertFalse(result.contains("- [ ] Existing note."))
    }

    func test_retryProtectionWithSameRequestID_isIdempotent() throws {
        let once = try edit(
            "# Inbox",
            entry: "Only once",
            placement: .append,
            retryProtectionEnabled: true
        )
        let twice = try edit(
            once,
            entry: "Only once",
            placement: .append,
            retryProtectionEnabled: true
        )

        XCTAssertEqual(twice, once)
        XCTAssertEqual(twice.components(separatedBy: "Only once").count - 1, 1)
        XCTAssertTrue(twice.contains("<!-- vox-capture:"))
    }

    func test_defaultWriteDoesNotAddCaptureMetadata() throws {
        let result = try edit("# Inbox", entry: "Clean note", placement: .append)

        XCTAssertEqual(result, "# Inbox\n\nClean note")
        XCTAssertFalse(result.contains("vox-capture"))
    }

    func test_crlfInput_isNormalizedWithoutCorruptingContent() throws {
        let result = try edit("---\r\ntitle: Inbox\r\n---\r\n\r\nExisting\r\n", entry: "New", placement: .prepend)

        XCTAssertFalse(result.contains("\r"))
        XCTAssertTrue(result.contains("title: Inbox"))
        XCTAssertTrue(result.contains("New"))
        XCTAssertTrue(result.contains("Existing"))
        XCTAssertFalse(result.contains("vox-capture"))
    }

    private func edit(
        _ document: String,
        entry: String,
        placement: CapturePlacement,
        prefix: String = "",
        suffix: String = "",
        retryProtectionEnabled: Bool = false
    ) throws -> String {
        try MarkdownDocumentEditor().applying(
            MarkdownCaptureMutation(
                requestID: requestID,
                entry: entry,
                placement: placement,
                entryPrefix: prefix,
                entrySuffix: suffix,
                retryProtectionEnabled: retryProtectionEnabled
            ),
            to: document
        )
    }

    private func index(of needle: String, in haystack: String) throws -> String.Index {
        try XCTUnwrap(haystack.range(of: needle)?.lowerBound)
    }
}
