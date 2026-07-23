import XCTest
@testable import VoxboardCaptureCore

final class CaptureMarkdownRendererTests: XCTestCase {
    func test_everyPayloadKindProducesExpectedMarkdown() throws {
        let image = try asset("photo.jpg", type: "public.jpeg")
        let audio = try asset("voice.m4a", type: "public.mpeg-4-audio")
        let file = try asset("report.pdf", type: "com.adobe.pdf")
        let page = try asset("scan-1.jpg", type: "public.jpeg")
        let drawing = try asset("sketch.pkdrawing", type: "com.apple.pencilkit.drawing")
        let preview = try asset("sketch.png", type: "public.png")
        let destination = CaptureDestination(
            name: "Inbox",
            rootBookmark: Data([1]),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md"),
            attachmentsFolderName: "Assets"
        )
        let request = CaptureRequest(
            source: .app,
            destinationID: destination.id,
            payloads: [
                .text("A thought"),
                .url(URL(string: "https://example.com/a%20path")!, title: "Example"),
                .audio(audio, transcript: "Spoken words"),
                .image(image, altText: "Whiteboard"),
                .file(file),
                .scannedDocument(pages: [page], pdf: file, extractedText: "Scanned words"),
                .sketch(drawing: drawing, preview: preview, altText: "Plan"),
            ]
        )

        let markdown = try CaptureMarkdownRenderer().render(request, for: destination)

        XCTAssertTrue(markdown.contains("A thought"))
        XCTAssertTrue(markdown.contains("[Example](https://example.com/a%20path)"))
        XCTAssertTrue(markdown.contains("Spoken words"))
        XCTAssertTrue(markdown.contains("![[Assets/voice.m4a]]"))
        XCTAssertTrue(markdown.contains("![[Assets/photo.jpg|Whiteboard]]"))
        XCTAssertTrue(markdown.contains("[[Assets/report.pdf|report.pdf]]"))
        XCTAssertTrue(markdown.contains("Scanned words"))
        XCTAssertTrue(markdown.contains("![[Assets/report.pdf]]"))
        XCTAssertTrue(markdown.contains("![[Assets/sketch.png|Plan]]"))
        XCTAssertTrue(markdown.contains("[[Assets/sketch.pkdrawing|Editable drawing]]"))
    }

    func test_nonEmbeddedRetainedAudioAloneRendersPlainAttachmentLink() throws {
        let audio = try asset("voice.m4a", type: "public.mpeg-4-audio")
        let destination = CaptureDestination(
            name: "Inbox",
            rootBookmark: Data([1]),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md"),
            attachmentsFolderName: "Assets"
        )
        let request = CaptureRequest(
            source: .app,
            destinationID: destination.id,
            payloads: [.retainedAudio(audio, embedPlacement: .none)]
        )

        let markdown = try CaptureMarkdownRenderer().render(request, for: destination)

        XCTAssertEqual(markdown, "[[Assets/voice.m4a|voice.m4a]]")
    }

    func test_nonEmbeddedRetainedAudioStaysOutOfNoteWhenTextExists() throws {
        let audio = try asset("voice.m4a", type: "public.mpeg-4-audio")
        let destination = CaptureDestination(
            name: "Inbox",
            rootBookmark: Data([1]),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md"),
            attachmentsFolderName: "Assets"
        )
        let request = CaptureRequest(
            source: .app,
            destinationID: destination.id,
            payloads: [
                .text("Spoken note"),
                .retainedAudio(audio, embedPlacement: .none),
            ]
        )

        let markdown = try CaptureMarkdownRenderer().render(request, for: destination)

        XCTAssertEqual(markdown, "Spoken note")
    }

    func test_textPayloadPreservesMarkdownBoundarySpaces() throws {
        let destination = CaptureDestination(
            name: "Inbox",
            rootBookmark: Data([1]),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md")
        )
        let request = CaptureRequest(
            source: .app,
            destinationID: destination.id,
            payloads: [.text("    code block\nline  ")]
        )

        let markdown = try CaptureMarkdownRenderer().render(request, for: destination)

        XCTAssertEqual(markdown, "    code block\nline  ")
    }

    func test_emptyRequestFailsInsteadOfWritingMarkerOnly() {
        let destination = CaptureDestination(
            name: "Inbox",
            rootBookmark: Data([1]),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md")
        )
        let request = CaptureRequest(source: .app, destinationID: destination.id, payloads: [])

        XCTAssertThrowsError(try CaptureMarkdownRenderer().render(request, for: destination)) { error in
            XCTAssertEqual(error as? CaptureRenderingError, .emptyRequest)
        }
    }

    func test_urlPayloadRejectsNonHTTPProtocols() throws {
        let destination = CaptureDestination(
            name: "Inbox",
            rootBookmark: Data([1]),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md")
        )
        for value in ["file:///private/secret", "javascript:alert(1)"] {
            let request = CaptureRequest(
                source: .shareExtension,
                destinationID: destination.id,
                payloads: [.url(try XCTUnwrap(URL(string: value)), title: nil)]
            )

            XCTAssertThrowsError(try CaptureMarkdownRenderer().render(request, for: destination)) { error in
                XCTAssertEqual(error as? CaptureRenderingError, .unsafeURL(value))
            }
        }
    }

    func test_assetOverrideUsesFinalUniquedAttachmentPath() throws {
        let image = try asset("photo.jpg", type: "public.jpeg")
        let destination = CaptureDestination(
            name: "Inbox",
            rootBookmark: Data([1]),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md")
        )
        let request = CaptureRequest(
            source: .app,
            destinationID: destination.id,
            payloads: [.image(image, altText: nil)]
        )

        let markdown = try CaptureMarkdownRenderer().render(
            request,
            for: destination,
            attachmentPaths: [image.relativePath: "attachments/photo-2.jpg"]
        )

        XCTAssertEqual(markdown, "![[attachments/photo-2.jpg]]")
    }

    private func asset(_ filename: String, type: String) throws -> CaptureAssetReference {
        try CaptureAssetReference(
            relativePath: "staging/request/\(filename)",
            originalFilename: filename,
            contentTypeIdentifier: type
        )
    }
}
