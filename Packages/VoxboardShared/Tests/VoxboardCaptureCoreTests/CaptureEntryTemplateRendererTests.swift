import XCTest
@testable import VoxboardCaptureCore

final class CaptureEntryTemplateRendererTests: XCTestCase {
    func test_rendersLocalDateTimeSourceAndRequestTokens() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let request = CaptureRequest(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            createdAt: Date(timeIntervalSince1970: 1_704_164_645),
            source: .shareExtension,
            destinationID: UUID(),
            payloads: [.text("Keep {date} literal in user content")]
        )

        let rendered = CaptureEntryTemplateRenderer(calendar: calendar).render(
            "captured: {date} ({YR}) {time}\nsource: {source}\nrequest: {id8}",
            for: request
        )

        XCTAssertEqual(
            rendered,
            "captured: 2024-01-02 (24) 030405\nsource: shareExtension\nrequest: aaaaaaaa"
        )
        guard case .text(let text) = request.payloads[0] else {
            return XCTFail("Expected text")
        }
        XCTAssertEqual(text, "Keep {date} literal in user content")
    }

    func test_rendersComposableHourMinuteAndSecondTokens() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let request = CaptureRequest(
            createdAt: Date(timeIntervalSince1970: 1_704_164_645),
            source: .app,
            destinationID: UUID(),
            payloads: [.text("Literal {hour}:{minute}:{second} stays untouched")]
        )

        let rendered = CaptureEntryTemplateRenderer(calendar: calendar).render(
            "{hour}:{minute}:{second} {date}",
            for: request
        )

        XCTAssertEqual(rendered, "03:04:05 2024-01-02")
        XCTAssertEqual(request.payloads, [.text("Literal {hour}:{minute}:{second} stays untouched")])
    }

    func test_unknownTokensArePreservedForForwardCompatibility() {
        let request = CaptureRequest(source: .app, destinationID: UUID(), payloads: [.text("Hi")])

        XCTAssertEqual(
            CaptureEntryTemplateRenderer().render("before {unknown} after", for: request),
            "before {unknown} after"
        )
    }
}
