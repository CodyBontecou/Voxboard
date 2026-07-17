import XCTest
@testable import VoxboardCaptureCore

final class CapturePipelineTests: XCTestCase {
    func test_textCaptureWritesExistingNoteAtHeading() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("Inbox.md")
        try "# Inbox\n\n## Ideas\n\nOlder".write(to: note, atomically: true, encoding: .utf8)
        let destination = destination(
            target: .existingNote(relativePath: "Inbox.md"),
            placement: .beneathHeading(
                CaptureHeadingSelector(title: "Ideas", level: 2),
                missingHeadingBehavior: .fail
            )
        )
        let request = CaptureRequest(
            source: .app,
            destinationID: destination.id,
            payloads: [.text("New idea")]
        )

        let receipt = try await CapturePipeline().capture(
            request,
            destination: destination,
            rootURL: root
        )

        XCTAssertEqual(receipt.noteURL.standardizedFileURL, note.standardizedFileURL)
        let content = try String(contentsOf: note, encoding: .utf8)
        XCTAssertLessThan(try index(of: "New idea", in: content), try index(of: "Older", in: content))
        XCTAssertFalse(content.contains("vox-capture"))
    }

    func test_destinationEntryTemplateTokensRenderWithoutChangingPayloadText() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var destination = destination(target: .existingNote(relativePath: "Inbox.md"))
        destination.entryPrefix = "---\ncaptured: {date}\nsource: {source}\n---\n"
        let request = CaptureRequest(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            createdAt: Date(timeIntervalSince1970: 1_704_164_645),
            source: .shareExtension,
            destinationID: destination.id,
            payloads: [.text("Keep {date} literal")]
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")

        _ = try await CapturePipeline(
            pathPlanner: CapturePathPlanner(calendar: calendar)
        ).capture(request, destination: destination, rootURL: root)

        let markdown = try String(contentsOf: root.appendingPathComponent("Inbox.md"), encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix("---\ncaptured: 2024-01-02\nsource: shareExtension\n---"))
        XCTAssertTrue(markdown.contains("Keep {date} literal"))
    }

    func test_newNoteIsUniquedAgainstFilesCreatedOnDisk() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Inbox"), withIntermediateDirectories: true)
        try "Existing".write(
            to: root.appendingPathComponent("Inbox/capture.md"),
            atomically: true,
            encoding: .utf8
        )
        let destination = destination(target: .newNote(pathTemplate: "Inbox/capture.md"))
        let request = CaptureRequest(
            source: .app,
            destinationID: destination.id,
            payloads: [.text("New capture")]
        )

        let receipt = try await CapturePipeline().capture(request, destination: destination, rootURL: root)

        XCTAssertEqual(receipt.noteURL.lastPathComponent, "capture-2.md")
        XCTAssertEqual(try String(contentsOf: receipt.noteURL, encoding: .utf8).contains("New capture"), true)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Inbox/capture.md"), encoding: .utf8), "Existing")
    }

    func test_retryOfAppliedNewNoteRequestReusesOriginalNote() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = destination(
            target: .newNote(pathTemplate: "Inbox/capture.md"),
            retryProtectionEnabled: true
        )
        let request = CaptureRequest(
            source: .shareExtension,
            destinationID: destination.id,
            payloads: [.text("Only once")]
        )
        let pipeline = CapturePipeline()

        let first = try await pipeline.capture(request, destination: destination, rootURL: root)
        let retry = try await pipeline.capture(request, destination: destination, rootURL: root)

        XCTAssertEqual(first.noteURL, retry.noteURL)
        XCTAssertTrue(retry.writeReceipt.wasAlreadyApplied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Inbox/capture-2.md").path))
        XCTAssertEqual(
            try String(contentsOf: first.noteURL, encoding: .utf8).components(separatedBy: "Only once").count - 1,
            1
        )
    }

    func test_sharedPipelineSerializesConcurrentNewNoteAllocation() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = destination(target: .newNote(pathTemplate: "Inbox/capture.md"))
        let first = CaptureRequest(
            source: .app,
            destinationID: destination.id,
            payloads: [.text("First")]
        )
        let second = CaptureRequest(
            source: .voice,
            destinationID: destination.id,
            payloads: [.text("Second")]
        )

        async let firstReceipt = CapturePipeline.shared.capture(
            first,
            destination: destination,
            rootURL: root
        )
        async let secondReceipt = CapturePipeline.shared.capture(
            second,
            destination: destination,
            rootURL: root
        )
        let receipts = try await [firstReceipt, secondReceipt]

        XCTAssertEqual(Set(receipts.map { $0.noteURL.lastPathComponent }), Set(["capture.md", "capture-2.md"]))
    }

    func test_notePathCannotEscapeVaultThroughSymlinkedParent() async throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        let destination = destination(target: .existingNote(relativePath: "escape/stolen.md"))
        let request = CaptureRequest(
            source: .app,
            destinationID: destination.id,
            payloads: [.text("must stay contained")]
        )

        await XCTAssertThrowsErrorAsync(
            try await CapturePipeline().capture(request, destination: destination, rootURL: root)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("stolen.md").path))
    }

    func test_attachmentPathsCannotEscapeThroughSymlinkedSourceOrDestination() async throws {
        let root = try temporaryFolder()
        let staging = try temporaryFolder()
        let outside = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("private".utf8).write(to: outside.appendingPathComponent("photo.jpg"))
        try FileManager.default.createSymbolicLink(
            at: staging.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("attachments"),
            withDestinationURL: outside
        )
        let asset = try CaptureAssetReference(
            relativePath: "escape/photo.jpg",
            originalFilename: "copied.jpg",
            contentTypeIdentifier: "public.jpeg"
        )
        let destination = destination(target: .existingNote(relativePath: "Inbox.md"))
        let request = CaptureRequest(
            source: .shareExtension,
            destinationID: destination.id,
            payloads: [.image(asset, altText: nil)]
        )

        await XCTAssertThrowsErrorAsync(
            try await CapturePipeline().capture(
                request,
                destination: destination,
                rootURL: root,
                assetRootURL: staging
            )
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("copied.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Inbox.md").path))
    }

    func test_attachmentDestinationCannotEscapeThroughSymlinkedFolder() async throws {
        let root = try temporaryFolder()
        let staging = try temporaryFolder()
        let outside = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("image".utf8).write(to: staging.appendingPathComponent("photo.jpg"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("attachments"),
            withDestinationURL: outside
        )
        let asset = try CaptureAssetReference(
            relativePath: "photo.jpg",
            originalFilename: "copied.jpg",
            contentTypeIdentifier: "public.jpeg"
        )
        let destination = destination(target: .existingNote(relativePath: "Inbox.md"))
        let request = CaptureRequest(
            source: .app,
            destinationID: destination.id,
            payloads: [.image(asset, altText: nil)]
        )

        await XCTAssertThrowsErrorAsync(
            try await CapturePipeline().capture(
                request,
                destination: destination,
                rootURL: root,
                assetRootURL: staging
            )
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("copied.jpg").path))
    }

    func test_requestAttachmentFolderOverrideSurvivesDeferredInboxDelivery() async throws {
        let root = try temporaryFolder()
        let staging = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: staging)
        }
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("request"), withIntermediateDirectories: true)
        try Data("voice".utf8).write(to: staging.appendingPathComponent("request/voice.wav"))
        let asset = try CaptureAssetReference(
            relativePath: "request/voice.wav",
            originalFilename: "voice.wav",
            contentTypeIdentifier: "com.microsoft.waveform-audio",
            byteCount: 5
        )
        let destination = CaptureDestination(
            name: "Voice",
            rootBookmark: Data(),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md"),
            attachmentsFolderName: "destination-default"
        )
        let request = CaptureRequest(
            source: .voice,
            destinationID: destination.id,
            payloads: [.retainedAudio(asset, embedPlacement: .bottom)],
            attachmentsFolderNameOverride: "flow-audio"
        )

        _ = try await CapturePipeline().capture(
            request,
            destination: destination,
            rootURL: root,
            assetRootURL: staging
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("flow-audio/voice.wav").path))
        let markdown = try String(contentsOf: root.appendingPathComponent("Inbox.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("![[flow-audio/voice.wav]]"))
    }

    func test_attachmentCopiesAndRendererUsesFinalUniquedPath() async throws {
        let root = try temporaryFolder()
        let staging = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: staging)
        }
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("request"), withIntermediateDirectories: true)
        let source = staging.appendingPathComponent("request/photo.jpg")
        try Data("image".utf8).write(to: source)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("attachments"), withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: root.appendingPathComponent("attachments/photo.jpg"))
        let asset = try CaptureAssetReference(
            relativePath: "request/photo.jpg",
            originalFilename: "photo.jpg",
            contentTypeIdentifier: "public.jpeg"
        )
        let destination = destination(target: .existingNote(relativePath: "Inbox.md"))
        let request = CaptureRequest(
            source: .shareExtension,
            destinationID: destination.id,
            payloads: [.image(asset, altText: "Photo")]
        )

        let receipt = try await CapturePipeline().capture(
            request,
            destination: destination,
            rootURL: root,
            assetRootURL: staging
        )

        XCTAssertEqual(receipt.attachmentURLs.map(\.lastPathComponent), ["photo-2.jpg"])
        let content = try String(contentsOf: receipt.noteURL, encoding: .utf8)
        XCTAssertTrue(content.contains("![[attachments/photo-2.jpg|Photo]]"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("attachments/photo.jpg")), Data("existing".utf8))
    }

    func test_retryOfAppliedRequestReusesIdenticalAttachmentWithoutCreatingDuplicate() async throws {
        let root = try temporaryFolder()
        let staging = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: staging)
        }
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("request"), withIntermediateDirectories: true)
        try Data("same-image".utf8).write(to: staging.appendingPathComponent("request/photo.jpg"))
        let asset = try CaptureAssetReference(
            relativePath: "request/photo.jpg",
            originalFilename: "photo.jpg",
            contentTypeIdentifier: "public.jpeg"
        )
        let destination = destination(
            target: .existingNote(relativePath: "Inbox.md"),
            retryProtectionEnabled: true
        )
        let request = CaptureRequest(
            source: .shareExtension,
            destinationID: destination.id,
            payloads: [.image(asset, altText: nil)]
        )
        let pipeline = CapturePipeline()

        let first = try await pipeline.capture(
            request,
            destination: destination,
            rootURL: root,
            assetRootURL: staging
        )
        let retry = try await pipeline.capture(
            request,
            destination: destination,
            rootURL: root,
            assetRootURL: staging
        )

        XCTAssertEqual(first.attachmentURLs, retry.attachmentURLs)
        XCTAssertTrue(retry.writeReceipt.wasAlreadyApplied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("attachments/photo-2.jpg").path))
    }

    func test_newNoteRetryReusesPreviouslyUniquedAttachmentAfterCollision() async throws {
        let root = try temporaryFolder()
        let staging = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: staging)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("attachments"), withIntermediateDirectories: true)
        try Data("unrelated".utf8).write(to: root.appendingPathComponent("attachments/photo.jpg"))
        try Data("captured".utf8).write(to: staging.appendingPathComponent("photo.jpg"))
        let asset = try CaptureAssetReference(
            relativePath: "photo.jpg",
            originalFilename: "photo.jpg",
            contentTypeIdentifier: "public.jpeg"
        )
        let destination = destination(
            target: .newNote(pathTemplate: "Inbox/capture.md"),
            retryProtectionEnabled: true
        )
        let request = CaptureRequest(
            source: .shareExtension,
            destinationID: destination.id,
            payloads: [.image(asset, altText: nil)]
        )
        let pipeline = CapturePipeline()

        let first = try await pipeline.capture(
            request,
            destination: destination,
            rootURL: root,
            assetRootURL: staging
        )
        let retry = try await pipeline.capture(
            request,
            destination: destination,
            rootURL: root,
            assetRootURL: staging
        )

        XCTAssertEqual(first.noteURL, retry.noteURL)
        XCTAssertEqual(first.attachmentURLs, retry.attachmentURLs)
        XCTAssertEqual(first.attachmentURLs.map(\.lastPathComponent), ["photo-2.jpg"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("attachments/photo-3.jpg").path))
    }

    func test_scannedPDFDoesNotCopyUnusedPageImages() async throws {
        let root = try temporaryFolder()
        let staging = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: staging)
        }
        try Data("page".utf8).write(to: staging.appendingPathComponent("page.jpg"))
        try Data("pdf".utf8).write(to: staging.appendingPathComponent("scan.pdf"))
        let page = try CaptureAssetReference(
            relativePath: "page.jpg",
            originalFilename: "page.jpg",
            contentTypeIdentifier: "public.jpeg"
        )
        let pdf = try CaptureAssetReference(
            relativePath: "scan.pdf",
            originalFilename: "scan.pdf",
            contentTypeIdentifier: "com.adobe.pdf"
        )
        let destination = destination(target: .existingNote(relativePath: "Inbox.md"))
        let request = CaptureRequest(
            source: .app,
            destinationID: destination.id,
            payloads: [.scannedDocument(pages: [page], pdf: pdf, extractedText: "OCR")]
        )

        let receipt = try await CapturePipeline().capture(
            request,
            destination: destination,
            rootURL: root,
            assetRootURL: staging
        )

        XCTAssertEqual(receipt.attachmentURLs.map(\.lastPathComponent), ["scan.pdf"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("attachments/page.jpg").path))
    }

    func test_noteFailureRollsBackOnlyNewAttachments() async throws {
        let root = try temporaryFolder()
        let staging = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: staging)
        }
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("request"), withIntermediateDirectories: true)
        try Data("image".utf8).write(to: staging.appendingPathComponent("request/photo.jpg"))
        let asset = try CaptureAssetReference(
            relativePath: "request/photo.jpg",
            originalFilename: "photo.jpg",
            contentTypeIdentifier: "public.jpeg"
        )
        let destination = destination(target: .existingNote(relativePath: "Inbox.md"))
        let request = CaptureRequest(
            source: .shareExtension,
            destinationID: destination.id,
            payloads: [.image(asset, altText: nil)]
        )
        let pipeline = CapturePipeline(writer: AlwaysFailingMutationWriter())

        await XCTAssertThrowsErrorAsync(
            try await pipeline.capture(
                request,
                destination: destination,
                rootURL: root,
                assetRootURL: staging
            )
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("attachments/photo.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("request/photo.jpg").path))
    }

    private func destination(
        target: CaptureNoteTarget,
        placement: CapturePlacement = .append,
        retryProtectionEnabled: Bool = false
    ) -> CaptureDestination {
        CaptureDestination(
            name: "Inbox",
            rootBookmark: Data([1]),
            rootName: "Vault",
            noteTarget: target,
            placement: placement,
            retryProtectionEnabled: retryProtectionEnabled
        )
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapturePipelineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func index(of needle: String, in haystack: String) throws -> String.Index {
        try XCTUnwrap(haystack.range(of: needle)?.lowerBound)
    }
}

private struct AlwaysFailingMutationWriter: CaptureMutationWriting {
    func write(_ mutation: MarkdownCaptureMutation, to fileURL: URL) async throws -> CaptureWriteReceipt {
        throw TestCaptureError.expected
    }
}

private enum TestCaptureError: Error {
    case expected
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
