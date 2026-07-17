import XCTest
@testable import VoxboardCaptureCore

final class CapturePathPlannerTests: XCTestCase {
    private let destinationID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let requestID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let date = Date(timeIntervalSince1970: 1_704_164_645) // 2024-01-02T03:04:05Z

    func test_newNote_generatesUniqueMarkdownPath() throws {
        let destination = makeDestination(target: .newNote(pathTemplate: "Inbox/{date}-{id8}.md"))
        let request = makeRequest()
        let existing = Set(["Inbox/2024-01-02-aaaaaaaa.md"])

        let path = try planner().relativePath(
            for: request,
            destination: destination,
            existingRelativePaths: existing
        )

        XCTAssertEqual(path, "Inbox/2024-01-02-aaaaaaaa-2.md")
    }

    func test_rollingDailyNote_isStableWithinDay() throws {
        let destination = makeDestination(target: .rollingNote(pathTemplate: "Daily/{date}.md", period: .daily))
        let morning = makeRequest(date: date)
        let evening = makeRequest(date: date.addingTimeInterval(60 * 60 * 18))

        XCTAssertEqual(
            try planner().relativePath(for: morning, destination: destination),
            try planner().relativePath(for: evening, destination: destination)
        )
        XCTAssertEqual(
            try planner().relativePath(for: morning, destination: destination),
            "Daily/2024-01-02.md"
        )
    }

    func test_rollingPeriodTokenUsesSelectedDailyWeeklyMonthlyQuarterlyAndYearlyBuckets() throws {
        let request = makeRequest()
        let expectations: [(CaptureRollingPeriod, String)] = [
            (.daily, "Rolling/2024-01-02.md"),
            (.weekly, "Rolling/2024-W01.md"),
            (.monthly, "Rolling/2024-01.md"),
            (.quarterly, "Rolling/2024-Q1.md"),
            (.yearly, "Rolling/2024.md"),
        ]

        for (period, expected) in expectations {
            let destination = makeDestination(
                target: .rollingNote(pathTemplate: "Rolling/{period}.md", period: period)
            )
            XCTAssertEqual(
                try planner().relativePath(for: request, destination: destination),
                expected
            )
        }
    }

    func test_rollingNote_respectsInjectedCalendarAndTimeZone() throws {
        let destination = makeDestination(
            target: .rollingNote(pathTemplate: "Journal/{year}/{month}/{date}.md", period: .daily)
        )
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.locale = Locale(identifier: "en_US_POSIX")
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let path = try CapturePathPlanner(calendar: losAngeles).relativePath(
            for: makeRequest(date: Date(timeIntervalSince1970: 1_704_074_645)), // 2024-01-01T02:04:05Z
            destination: destination
        )

        XCTAssertEqual(path, "Journal/2023/12/2023-12-31.md")
    }

    func test_existingNote_usesResolvedFileReference() throws {
        let destination = makeDestination(target: .existingNote(relativePath: "Projects/Vox.md"))

        XCTAssertEqual(
            try planner().relativePath(for: makeRequest(), destination: destination),
            "Projects/Vox.md"
        )
    }

    func test_plannerRejectsAbsoluteAndTraversalTemplates() {
        for template in ["/private/{date}.md", "Daily/../Secrets.md", "~/Notes.md"] {
            let destination = makeDestination(target: .newNote(pathTemplate: template))

            XCTAssertThrowsError(try planner().relativePath(for: makeRequest(), destination: destination))
        }
    }

    private func planner() -> CapturePathPlanner {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return CapturePathPlanner(calendar: calendar)
    }

    private func makeRequest(date: Date? = nil) -> CaptureRequest {
        CaptureRequest(
            id: requestID,
            createdAt: date ?? self.date,
            source: .app,
            destinationID: destinationID,
            payloads: [.text("hello")]
        )
    }

    private func makeDestination(target: CaptureNoteTarget) -> CaptureDestination {
        CaptureDestination(
            id: destinationID,
            name: "Test",
            rootBookmark: Data([1, 2, 3]),
            rootName: "Vault",
            noteTarget: target
        )
    }
}
