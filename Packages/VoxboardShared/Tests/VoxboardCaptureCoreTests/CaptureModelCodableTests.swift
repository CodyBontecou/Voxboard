import XCTest
@testable import VoxboardCaptureCore

final class CaptureModelCodableTests: XCTestCase {
    func test_allPayloadKinds_roundTripWithoutPlatformFrameworkTypes() throws {
        let image = try CaptureAssetReference(
            relativePath: "staging/request/photo.heic",
            originalFilename: "photo.heic",
            contentTypeIdentifier: "public.heic",
            byteCount: 42
        )
        let audio = try CaptureAssetReference(
            relativePath: "staging/request/audio.m4a",
            originalFilename: "audio.m4a",
            contentTypeIdentifier: "public.mpeg-4-audio"
        )
        let documentPage = try CaptureAssetReference(
            relativePath: "staging/request/page-1.jpg",
            originalFilename: "page-1.jpg",
            contentTypeIdentifier: "public.jpeg"
        )
        let drawing = try CaptureAssetReference(
            relativePath: "staging/request/drawing.pkdrawing",
            originalFilename: "drawing.pkdrawing",
            contentTypeIdentifier: "com.apple.pencilkit.drawing"
        )
        let file = try CaptureAssetReference(
            relativePath: "staging/request/report.pdf",
            originalFilename: "report.pdf",
            contentTypeIdentifier: "com.adobe.pdf"
        )

        let payloads: [CapturePayload] = [
            .text("A thought"),
            .url(try XCTUnwrap(URL(string: "https://example.com/path?q=vox")), title: "Example"),
            .audio(audio, transcript: "Spoken thought"),
            .retainedAudio(audio, embedPlacement: .top),
            .image(image, altText: "A whiteboard"),
            .file(file),
            .scannedDocument(pages: [documentPage], pdf: file, extractedText: "Scanned text"),
            .sketch(drawing: drawing, preview: image, altText: "Architecture sketch"),
        ]
        let request = CaptureRequest(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .shortcut,
            deliveryKind: .meteredVoiceTranscript,
            destinationID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            payloads: payloads,
            attachmentsFolderNameOverride: "voice-audio"
        )

        let data = try JSONEncoder.captureCore.encode(request)
        let decoded = try JSONDecoder.captureCore.decode(CaptureRequest.self, from: data)

        XCTAssertEqual(decoded, request)
    }

    func test_legacyVoiceRequestWithoutDeliveryKindRemainsExempt() throws {
        let request = CaptureRequest(
            source: .voice,
            destinationID: UUID(),
            payloads: [.text("Legacy voice")]
        )
        let encoded = try JSONEncoder.captureCore.encode(request)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "deliveryKind")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder.captureCore.decode(CaptureRequest.self, from: legacyData)

        XCTAssertEqual(decoded.deliveryKind, .meteredVoiceTranscript)
    }

    func test_destinationV1Fixture_decodesDefaultPrefixSuffixAndPlacement() throws {
        let fixture = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "name": "Inbox",
          "rootBookmark": "AQID",
          "rootName": "My Vault",
          "noteTarget": {
            "kind": "existingNote",
            "relativePath": "Inbox.md"
          }
        }
        """.data(using: .utf8)!

        let destination = try JSONDecoder.captureCore.decode(CaptureDestination.self, from: fixture)

        XCTAssertEqual(destination.entryPrefix, "")
        XCTAssertEqual(destination.entrySuffix, "")
        XCTAssertEqual(destination.placement, .append)
        XCTAssertEqual(destination.attachmentsFolderName, "attachments")
        XCTAssertNil(destination.entryTemplateID)
        XCTAssertFalse(destination.retryProtectionEnabled)
    }

    func test_destinationRetryProtectionOptInRoundTrips() throws {
        let destination = CaptureDestination(
            name: "Inbox",
            rootBookmark: Data([1, 2, 3]),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md"),
            retryProtectionEnabled: true
        )

        let data = try JSONEncoder.captureCore.encode(destination)
        let decoded = try JSONDecoder.captureCore.decode(CaptureDestination.self, from: data)

        XCTAssertTrue(decoded.retryProtectionEnabled)
        XCTAssertEqual(decoded, destination)
    }

    func test_destinationTemplateBindingResolvesLatestReusableTemplateContent() throws {
        let templateID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let destination = CaptureDestination(
            name: "Inbox",
            rootBookmark: Data(),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md"),
            entryPrefix: "old snapshot",
            entrySuffix: "old suffix",
            entryTemplateID: templateID
        )
        let currentTemplate = CaptureEntryTemplate(
            id: templateID,
            name: "Task",
            entryPrefix: "- [ ] ",
            entrySuffix: " #task"
        )
        let library = CaptureLibraryEnvelope(
            destinations: [destination],
            entryTemplates: [currentTemplate]
        )

        let resolved = library.resolvedDestination(destination)

        XCTAssertEqual(resolved.entryTemplateID, templateID)
        XCTAssertEqual(resolved.entryPrefix, "- [ ] ")
        XCTAssertEqual(resolved.entrySuffix, " #task")
    }

    func test_entryTemplatesRoundTripAndLegacyLibraryDefaultsToEmpty() throws {
        let template = CaptureEntryTemplate(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            name: "Task",
            entryPrefix: "---\ntags: [task]\n---\n- [ ] ",
            entrySuffix: " #inbox"
        )
        let envelope = CaptureLibraryEnvelope(entryTemplates: [template])

        let decoded = try JSONDecoder().decode(
            CaptureLibraryEnvelope.self,
            from: JSONEncoder().encode(envelope)
        )
        let legacy = try JSONDecoder().decode(
            CaptureLibraryEnvelope.self,
            from: Data("{\"schemaVersion\":1,\"destinations\":[],\"flowBindings\":{}}".utf8)
        )

        XCTAssertEqual(decoded.entryTemplates, [template])
        XCTAssertEqual(legacy.entryTemplates, [])
    }

    func test_unknownLibraryVersion_isRejectedWithoutReplacement() throws {
        let fixture = """
        {"schemaVersion":99,"destinations":[],"flowBindings":{}}
        """.data(using: .utf8)!

        XCTAssertThrowsError(try CaptureLibraryEnvelope.decodeValidated(from: fixture)) { error in
            XCTAssertEqual(error as? CaptureModelError, .unsupportedSchemaVersion(99))
        }
    }

    func test_assetReference_rejectsAbsoluteAndTraversalPaths() {
        XCTAssertThrowsError(
            try CaptureAssetReference(
                relativePath: "/private/tmp/secret.txt",
                originalFilename: "secret.txt",
                contentTypeIdentifier: "public.text"
            )
        )
        XCTAssertThrowsError(
            try CaptureAssetReference(
                relativePath: "staging/../secret.txt",
                originalFilename: "secret.txt",
                contentTypeIdentifier: "public.text"
            )
        )
    }
}

private extension JSONEncoder {
    static var captureCore: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var captureCore: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
