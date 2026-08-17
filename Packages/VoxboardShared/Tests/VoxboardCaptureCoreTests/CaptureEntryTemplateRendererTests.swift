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

    func test_rendersPrivacyAdjustedLocationMapLinkWithoutChangingPayloadText() {
        let request = CaptureRequest(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            source: .app,
            destinationID: UUID(),
            payloads: [.text("Keep {location} literal in user content")],
            voxProfile: locationProfile(precision: .exact),
            locationOutcome: .available(locationSnapshot(precision: .exact))
        )

        XCTAssertEqual(
            CaptureEntryTemplateRenderer().render("📍 {location}", for: request),
            "📍 [Location](https://www.google.com/maps/search/?api=1&query=45.501235%2C-73.567890)"
        )
        XCTAssertEqual(request.payloads, [.text("Keep {location} literal in user content")])
    }

    func test_locationTokenUsesMorePrivateCityPrecisionWhenPolicyAndSnapshotDiffer() {
        let request = CaptureRequest(
            source: .app,
            destinationID: UUID(),
            payloads: [.text("City capture")],
            voxProfile: locationProfile(precision: .city),
            locationOutcome: .available(locationSnapshot(precision: .exact))
        )

        XCTAssertEqual(
            CaptureEntryTemplateRenderer().render("{location}", for: request),
            "[Location](https://www.google.com/maps/search/?api=1&query=45.50%2C-73.57)"
        )
    }

    func test_locationTokenIsEmptyWithoutUsableOptedInLocation() {
        let unavailable = CaptureRequest(
            source: .app,
            destinationID: UUID(),
            payloads: [.text("Unavailable")],
            voxProfile: locationProfile(precision: .exact),
            locationOutcome: .unavailable(.permissionDenied, attemptedAt: Date())
        )
        let disabled = CaptureRequest(
            source: .app,
            destinationID: UUID(),
            payloads: [.text("Disabled")],
            voxProfile: CapturePresetProfile(id: "disabled", name: "Disabled", symbolName: "location"),
            locationOutcome: .available(locationSnapshot(precision: .exact))
        )
        let malformed = CaptureRequest(
            source: .app,
            destinationID: UUID(),
            payloads: [.text("Malformed")],
            voxProfile: locationProfile(precision: .exact),
            locationOutcome: .available(CaptureLocationSnapshot(
                latitude: .infinity,
                longitude: 0,
                timestamp: Date(),
                source: .app,
                precision: .exact
            ))
        )

        for request in [unavailable, disabled, malformed] {
            XCTAssertEqual(
                CaptureEntryTemplateRenderer().render("before{location}after", for: request),
                "beforeafter"
            )
        }
    }

    func test_unknownTokensArePreservedForForwardCompatibility() {
        let request = CaptureRequest(source: .app, destinationID: UUID(), payloads: [.text("Hi")])

        XCTAssertEqual(
            CaptureEntryTemplateRenderer().render("before {unknown} after", for: request),
            "before {unknown} after"
        )
    }

    private func locationProfile(precision: CaptureLocationPrecision) -> CapturePresetProfile {
        CapturePresetProfile(
            id: "location",
            name: "Location",
            symbolName: "location",
            locationPolicy: CapturePresetLocationPolicy(isEnabled: true, precision: precision)
        )
    }

    private func locationSnapshot(precision: CaptureLocationPrecision) -> CaptureLocationSnapshot {
        CaptureLocationSnapshot(
            latitude: 45.50123456,
            longitude: -73.56789,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            source: .app,
            precision: precision
        )
    }
}
