import XCTest
@testable import VoxboardCaptureCore

final class CaptureDeepLinkParserTests: XCTestCase {
    func test_validTextAndURLLinksPopulateDraftWithoutAutoSubmitting() throws {
        let destination = "11111111-2222-3333-4444-555555555555"
        let url = try XCTUnwrap(URL(string: "voxboard://capture?text=Hello%20world&url=https%3A%2F%2Fexample.com&destination=\(destination)"))

        let action = try CaptureDeepLinkParser().parse(url)

        XCTAssertEqual(
            action,
            .openComposer(
                CaptureDeepLinkDraft(
                    text: "Hello world",
                    url: URL(string: "https://example.com"),
                    destinationID: UUID(uuidString: destination)
                )
            )
        )
    }

    func test_widgetActionCanRequestAComposerInputWithoutSubmitting() throws {
        for input in CaptureRequestedInput.allCases {
            let url = try XCTUnwrap(URL(string: "voxboard://capture?action=\(input.rawValue)&source=widget"))

            XCTAssertEqual(
                try CaptureDeepLinkParser().parse(url),
                .openComposer(CaptureDeepLinkDraft(requestedInput: input, source: .widget))
            )
        }
        let invalid = try XCTUnwrap(URL(string: "voxboard://capture?action=erase-vault"))
        XCTAssertThrowsError(try CaptureDeepLinkParser().parse(invalid))
        let forbiddenSource = try XCTUnwrap(URL(string: "voxboard://capture?source=shareExtension"))
        XCTAssertThrowsError(try CaptureDeepLinkParser().parse(forbiddenSource))
    }

    func test_requestIDLinkClaimsInboxItemRatherThanEmbeddingContent() throws {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let url = try XCTUnwrap(URL(string: "voxboard://capture-request?id=\(id.uuidString)"))

        XCTAssertEqual(try CaptureDeepLinkParser().parse(url), .processInboxRequest(id))
    }

    func test_malformedUnknownAndExcessivePayloadsAreRejected() throws {
        for value in [
            "https://example.com/capture",
            "voxboard://unknown",
            "voxboard://capture?url=javascript%3Aalert(1)",
            "voxboard://capture?destination=not-a-uuid",
        ] {
            XCTAssertThrowsError(try CaptureDeepLinkParser().parse(try XCTUnwrap(URL(string: value))))
        }

        var components = URLComponents()
        components.scheme = "voxboard"
        components.host = "capture"
        components.queryItems = [URLQueryItem(name: "text", value: String(repeating: "x", count: 100_001))]
        XCTAssertThrowsError(try CaptureDeepLinkParser().parse(try XCTUnwrap(components.url)))
    }

    func test_arbitraryFilePathsBookmarksAndAutoSubmitAreRejected() throws {
        for forbiddenName in ["file", "path", "bookmark", "autoSubmit"] {
            var components = URLComponents()
            components.scheme = "voxboard"
            components.host = "capture"
            components.queryItems = [URLQueryItem(name: forbiddenName, value: "/private/secret")]

            XCTAssertThrowsError(try CaptureDeepLinkParser().parse(try XCTUnwrap(components.url)))
        }
    }
}
