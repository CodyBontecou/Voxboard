import Foundation
import XCTest
@testable import VoxboardCaptureCore

final class CaptureInsertionFormatterTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "America/Los_Angeles")!
    private lazy var formatter = makeFormatter()

    func test_dueDateTokensAndCurrentTimestampUseInjectedClockDependencies() throws {
        let date = try localDate(2026, 1, 2, 15, 4)

        XCTAssertEqual(formatter.dueDateToken(for: date), "(@2026-01-02)")
        XCTAssertEqual(formatter.dueDateToken(for: date, includeTime: true), "(@2026-01-02 03:04 PM)")
        XCTAssertEqual(formatter.currentTimestamp(at: date), "3:04 PM 2026-01-02")
    }

    func test_dateFormattingUsesInjectedLocaleAndTimeZoneRatherThanProcessDefaults() throws {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let utcFormatter = CaptureInsertionFormatter(
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let instant = try localDate(2026, 1, 2, 23, 30)

        XCTAssertEqual(formatter.dueDateToken(for: instant), "(@2026-01-02)")
        XCTAssertEqual(utcFormatter.dueDateToken(for: instant), "(@2026-01-03)")
    }

    func test_wikiLinkStripsMarkdownExtensionAndNormalizesSeparators() throws {
        XCTAssertEqual(
            try formatter.wikiLink(for: " Projects\\Vox.md "),
            "[[Projects/Vox]]"
        )
        XCTAssertEqual(
            try formatter.wikiLink(for: "Projects//Ideas/Note.MD"),
            "[[Projects/Ideas/Note]]"
        )
    }

    func test_wikiLinkRejectsTraversalAbsoluteEmptyAndControlCharacterInputs() {
        let invalid = [
            "../Secrets.md",
            "Folder/../Secrets.md",
            "/Absolute.md",
            "\\Absolute.md",
            "C:\\Absolute.md",
            "~/.hidden.md",
            "Folder/Bad\nName.md",
            "Folder/Bad|Alias.md",
            "Folder/Bad]]Name.md",
            ".md",
        ]

        for value in invalid {
            XCTAssertThrowsError(try formatter.wikiLink(for: value), value) { error in
                XCTAssertEqual(error as? CaptureInsertionFormatterError, .invalidWikiLink)
            }
        }
    }

    func test_googleMapsLinkUsesPOSIXCoordinatesAndEscapesMarkdownLabel() throws {
        let result = try formatter.googleMapsLink(
            latitude: 21.3069,
            longitude: -157.8583,
            label: #"A [quiet] \\ place"#
        )

        XCTAssertEqual(
            result,
            #"[A \[quiet\] \\\\ place](https://www.google.com/maps?q=21.306900,-157.858300)"#
        )
    }

    func test_googleMapsLinkNeutralizesControlCharactersInLabel() throws {
        let result = try formatter.googleMapsLink(
            latitude: 0,
            longitude: 0,
            label: "First\u{0}Second\nThird"
        )

        XCTAssertEqual(
            result,
            "[First Second Third](https://www.google.com/maps?q=0.000000,0.000000)"
        )
    }

    func test_googleMapsLinkRejectsNonFiniteAndOutOfRangeCoordinates() {
        let invalid: [(Double, Double)] = [
            (.nan, 0),
            (0, .infinity),
            (90.0001, 0),
            (0, -180.0001),
        ]

        for (latitude, longitude) in invalid {
            XCTAssertThrowsError(
                try formatter.googleMapsLink(latitude: latitude, longitude: longitude, label: "Here")
            ) { error in
                XCTAssertEqual(error as? CaptureInsertionFormatterError, .invalidCoordinates)
            }
        }
    }

    func test_dueDateShortcutsUseCalendarAndPreserveLocalTime() throws {
        let wednesday = try localDate(2026, 7, 15, 9, 20)

        XCTAssertEqual(formatter.applying(.today, to: wednesday), wednesday)
        assertLocalComponents(
            formatter.applying(.tomorrow, to: wednesday),
            year: 2026,
            month: 7,
            day: 16,
            hour: 9,
            minute: 20
        )
        assertLocalComponents(
            formatter.applying(.thisWeekend, to: wednesday),
            year: 2026,
            month: 7,
            day: 18,
            hour: 9,
            minute: 20
        )

        let sunday = try localDate(2026, 7, 19, 9, 20)
        XCTAssertEqual(formatter.applying(.thisWeekend, to: sunday), sunday)
    }

    func test_minuteAdjustmentCrossesMidnightUsingCalendar() throws {
        let late = try localDate(2026, 1, 2, 23, 50)
        let adjusted = formatter.adjusting(late, by: 20, unit: .minute)

        assertLocalComponents(
            adjusted,
            year: 2026,
            month: 1,
            day: 3,
            hour: 0,
            minute: 10
        )
    }

    func test_hourAndDayMathHonorDaylightSavingTransitions() throws {
        let beforeSpringForward = try localDate(2026, 3, 8, 1, 30)
        assertLocalComponents(
            formatter.adjusting(beforeSpringForward, by: 1, unit: .hour),
            year: 2026,
            month: 3,
            day: 8,
            hour: 3,
            minute: 30
        )

        let dayBeforeSpringForward = try localDate(2026, 3, 7, 10, 15)
        assertLocalComponents(
            formatter.applying(.tomorrow, to: dayBeforeSpringForward),
            year: 2026,
            month: 3,
            day: 8,
            hour: 10,
            minute: 15
        )
    }

    private func makeFormatter() -> CaptureInsertionFormatter {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return CaptureInsertionFormatter(
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: timeZone
        )
    }

    private func localDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int
    ) throws -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return try XCTUnwrap(formatter.calendar.date(from: components))
    }

    private func assertLocalComponents(
        _ date: Date,
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let components = formatter.calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        XCTAssertEqual(components.year, year, file: file, line: line)
        XCTAssertEqual(components.month, month, file: file, line: line)
        XCTAssertEqual(components.day, day, file: file, line: line)
        XCTAssertEqual(components.hour, hour, file: file, line: line)
        XCTAssertEqual(components.minute, minute, file: file, line: line)
    }
}
