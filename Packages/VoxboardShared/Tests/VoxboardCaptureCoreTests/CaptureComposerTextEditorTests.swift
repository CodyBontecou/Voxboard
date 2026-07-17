import Foundation
import XCTest
@testable import VoxboardCaptureCore

final class CaptureComposerTextEditorTests: XCTestCase {
    private let editor = CaptureComposerTextEditor()

    func test_boldWrapsSelectionAndTogglesBothContentAndFullyMarkedSelections() {
        let wrapped = apply(.toggleBold, to: "hello world", location: 6, length: 5)
        XCTAssertEqual(wrapped.text, "hello **world**")
        XCTAssertEqual(wrapped.selection, CaptureTextSelection(location: 8, length: 5))

        let toggledFromContent = editor.applying(
            .toggleBold,
            to: wrapped.text,
            selection: wrapped.selection
        )
        XCTAssertEqual(toggledFromContent.text, "hello world")
        XCTAssertEqual(toggledFromContent.selection, CaptureTextSelection(location: 6, length: 5))

        let toggledFromMarkers = apply(.toggleBold, to: "**world**", location: 0, length: 9)
        XCTAssertEqual(toggledFromMarkers.text, "world")
        XCTAssertEqual(toggledFromMarkers.selection, CaptureTextSelection(location: 0, length: 5))
    }

    func test_italicWrapsAndTogglesSelectedText() {
        let wrapped = apply(.toggleItalic, to: "hello", location: 0, length: 5)
        XCTAssertEqual(wrapped.text, "*hello*")
        XCTAssertEqual(wrapped.selection, CaptureTextSelection(location: 1, length: 5))

        let toggled = editor.applying(
            .toggleItalic,
            to: wrapped.text,
            selection: wrapped.selection
        )
        XCTAssertEqual(toggled.text, "hello")
        XCTAssertEqual(toggled.selection, CaptureTextSelection(location: 0, length: 5))
    }

    func test_caretOnlyBoldAndItalicInsertPairedMarkersWithCaretInside() {
        XCTAssertEqual(
            apply(.toggleBold, to: "ab", location: 1, length: 0),
            CaptureTextEditResult(
                text: "a****b",
                selection: CaptureTextSelection(location: 3, length: 0)
            )
        )
        XCTAssertEqual(
            apply(.toggleItalic, to: "ab", location: 1, length: 0),
            CaptureTextEditResult(
                text: "a**b",
                selection: CaptureTextSelection(location: 2, length: 0)
            )
        )
    }

    func test_hashtagPrefixesSelectedTextOrInsertsAtCaret() {
        let selected = apply(.insertHashtag, to: "project", location: 0, length: 7)
        XCTAssertEqual(selected.text, "#project")
        XCTAssertEqual(selected.selection, CaptureTextSelection(location: 1, length: 7))

        let caret = apply(.insertHashtag, to: "idea", location: 4, length: 0)
        XCTAssertEqual(caret.text, "idea#")
        XCTAssertEqual(caret.selection, CaptureTextSelection(location: 5, length: 0))
    }

    func test_headingAppliesToEveryTouchedLineButNotLineAtSelectionEndBoundary() {
        let multiline = apply(.heading(level: 3), to: "one\ntwo\nthree", location: 1, length: 6)
        XCTAssertEqual(multiline.text, "### one\n### two\nthree")
        XCTAssertEqual(multiline.selection, CaptureTextSelection(location: 5, length: 10))

        let boundary = apply(.heading(level: 2), to: "one\ntwo", location: 0, length: 4)
        XCTAssertEqual(boundary.text, "## one\ntwo")
        XCTAssertEqual(boundary.selection, CaptureTextSelection(location: 3, length: 4))
    }

    func test_headingReplacesExistingHeadingAndInvalidLevelIsSafeNoOp() {
        let applied = apply(.heading(level: 2), to: "# One\n#### Two", location: 0, length: 14)
        XCTAssertEqual(applied.text, "## One\n## Two")

        let invalid = apply(.heading(level: 7), to: "Title", location: 2, length: 0)
        XCTAssertEqual(invalid, CaptureTextEditResult(
            text: "Title",
            selection: CaptureTextSelection(location: 2, length: 0)
        ))
    }

    func test_headingAndTaskReplaceValidEmptyMarkdownPrefixes() {
        let heading = apply(.heading(level: 2), to: "#", location: 0, length: 0)
        XCTAssertEqual(heading.text, "## ")
        XCTAssertEqual(heading.selection, CaptureTextSelection(location: 3, length: 0))

        let task = apply(.taskCheckbox, to: "- [ ]", location: 5, length: 0)
        XCTAssertEqual(task.text, "- [ ] ")
        XCTAssertEqual(task.selection, CaptureTextSelection(location: 6, length: 0))
    }

    func test_taskAndBulletApplyPrefixesToSelectedLinesAndReplaceExistingListMarkers() {
        let tasks = apply(.taskCheckbox, to: "buy milk\n  + call Sam", location: 0, length: 21)
        XCTAssertEqual(tasks.text, "- [ ] buy milk\n  - [ ] call Sam")

        let bullets = editor.applying(
            .bullet,
            to: tasks.text,
            selection: CaptureTextSelection(location: 0, length: 31)
        )
        XCTAssertEqual(bullets.text, "- buy milk\n  - call Sam")
    }

    func test_markdownLinkUsesSelectionAsLabelAndSelectsURLPlaceholder() {
        let result = apply(.markdownLink(), to: "Read Docs", location: 5, length: 4)
        XCTAssertEqual(result.text, "Read [Docs](url)")
        XCTAssertEqual(result.selection, CaptureTextSelection(location: 12, length: 3))
    }

    func test_markdownLinkAtCaretSelectsLabelPlaceholderAndEscapesSelectedLabel() {
        let placeholder = apply(.markdownLink(destination: "https://example.com"), to: "", location: 0, length: 0)
        XCTAssertEqual(placeholder.text, "[link text](https://example.com)")
        XCTAssertEqual(placeholder.selection, CaptureTextSelection(location: 1, length: 9))

        let escaped = apply(.markdownLink(), to: "A [label]", location: 0, length: 9)
        XCTAssertEqual(escaped.text, "[A \\[label\\]](url)")
        XCTAssertEqual(
            escaped.selection,
            CaptureTextSelection(location: ("[A \\[label\\]](" as NSString).length, length: 3)
        )
    }

    func test_wikiLinkWrapsSelectionOrSelectsPlaceholder() {
        let selected = apply(.wikiLink(), to: "Daily Note", location: 0, length: 10)
        XCTAssertEqual(selected.text, "[[Daily Note]]")
        XCTAssertEqual(selected.selection, CaptureTextSelection(location: 2, length: 10))

        let placeholder = apply(.wikiLink(), to: "", location: 0, length: 0)
        XCTAssertEqual(placeholder.text, "[[Note]]")
        XCTAssertEqual(placeholder.selection, CaptureTextSelection(location: 2, length: 4))
    }

    func test_replaceSelectionNormalizesReplacementAndLeavesCaretAfterIt() {
        let result = apply(.replaceSelection(with: "new\r\nline"), to: "old value", location: 0, length: 3)
        XCTAssertEqual(result.text, "new\nline value")
        XCTAssertEqual(result.selection, CaptureTextSelection(location: 8, length: 0))
    }

    func test_caseAndSlugCommandsReplaceSelectionAndKeepReplacementSelected() {
        XCTAssertEqual(transform(.lowercase, "MIXED Case"), "mixed case")
        XCTAssertEqual(transform(.uppercase, "Mixed case"), "MIXED CASE")
        XCTAssertEqual(transform(.sentenceCase, "hELLO world. nEXT line! yes"), "Hello world. Next line! Yes")
        XCTAssertEqual(transform(.capitalizeWords, "hELLO-world and O'BRIEN"), "Hello-World And O'brien")
        XCTAssertEqual(transform(.slugify, "  Crème brûlée & Notes  "), "creme-brulee-notes")
    }

    func test_caseCommandWithCaretOnlyDoesNotInventARange() {
        let result = apply(.uppercase, to: "hello", location: 2, length: 0)
        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(result.selection, CaptureTextSelection(location: 2, length: 0))
    }

    func test_crlfIsNormalizedAndOriginalUTF16SelectionIsTranslated() {
        let result = apply(.heading(level: 2), to: "one\r\ntwo\rthree", location: 5, length: 3)
        XCTAssertEqual(result.text, "one\n## two\nthree")
        XCTAssertEqual(result.selection, CaptureTextSelection(location: 7, length: 3))
        XCTAssertFalse(result.text.contains("\r"))
    }

    func test_emojiSelectionUsesUTF16AndNeverSplitsGraphemeClusters() {
        let text = "A👩🏽‍💻B"
        let emojiRange = (text as NSString).range(of: "👩🏽‍💻")
        let wrapped = editor.applying(
            .toggleBold,
            to: text,
            selection: CaptureTextSelection(emojiRange)
        )
        XCTAssertEqual(wrapped.text, "A**👩🏽‍💻**B")
        XCTAssertEqual(wrapped.selection.location, 3)
        XCTAssertEqual(wrapped.selection.length, emojiRange.length)

        let splitSurrogate = apply(.replaceSelection(with: "X"), to: text, location: 2, length: 1)
        XCTAssertEqual(splitSurrogate.text, "AXB")
        XCTAssertEqual(splitSurrogate.selection, CaptureTextSelection(location: 2, length: 0))
    }

    func test_invalidAndOutOfBoundsSelectionsAreClamped() {
        let entireText = apply(.replaceSelection(with: "x"), to: "hello", location: -20, length: 999)
        XCTAssertEqual(entireText, CaptureTextEditResult(
            text: "x",
            selection: CaptureTextSelection(location: 1, length: 0)
        ))

        let pastEnd = apply(.insertHashtag, to: "hi", location: 99, length: 40)
        XCTAssertEqual(pastEnd.text, "hi#")
        XCTAssertEqual(pastEnd.selection, CaptureTextSelection(location: 3, length: 0))

        let negativeLength = apply(.insertHashtag, to: "hi", location: 1, length: -4)
        XCTAssertEqual(negativeLength.text, "h#i")
        XCTAssertEqual(negativeLength.selection, CaptureTextSelection(location: 2, length: 0))
    }

    private func apply(
        _ command: CaptureComposerCommand,
        to text: String,
        location: Int,
        length: Int
    ) -> CaptureTextEditResult {
        editor.applying(
            command,
            to: text,
            selection: CaptureTextSelection(location: location, length: length)
        )
    }

    private func transform(_ command: CaptureComposerCommand, _ text: String) -> String {
        let result = apply(command, to: text, location: 0, length: (text as NSString).length)
        XCTAssertEqual(result.selection, CaptureTextSelection(
            location: 0,
            length: (result.text as NSString).length
        ))
        return result.text
    }
}
