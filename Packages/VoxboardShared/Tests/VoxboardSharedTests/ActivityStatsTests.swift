import Foundation
import Testing
@testable import VoxboardShared

struct ActivityStatsTests {
    private let destinationID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!

    @Test func summarizesCompletedActivityAndIgnoresFailures() throws {
        let calendar = utcCalendar()
        let now = date(2026, 7, 29, hour: 12, calendar: calendar)
        let firstRecordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondRecordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let deliveredCaptureID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let failedCaptureID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

        let transcripts = [
            transcript(id: firstRecordingID, date: date(2026, 7, 29, calendar: calendar), duration: 30),
            transcript(id: secondRecordingID, date: date(2026, 7, 24, calendar: calendar), duration: 90),
            // A repeated cross-process record must not inflate the count or duration.
            transcript(id: firstRecordingID, date: date(2026, 7, 29, calendar: calendar), duration: 30),
        ]
        let records = [
            try capture(
                id: deliveredCaptureID,
                createdAt: date(2026, 7, 28, calendar: calendar),
                deliveredAt: date(2026, 7, 29, calendar: calendar),
                source: .shareExtension,
                outcome: .delivered,
                attachments: 2
            ),
            try capture(
                id: failedCaptureID,
                createdAt: date(2026, 7, 29, calendar: calendar),
                deliveredAt: date(2026, 7, 29, calendar: calendar),
                source: .app,
                outcome: .failed,
                attachments: 4
            ),
        ]

        let stats = ActivityStats(
            transcripts: transcripts,
            captureRecords: records,
            now: now,
            calendar: calendar
        )

        #expect(stats.recordingCount == 2)
        #expect(stats.captureCount == 1)
        #expect(stats.totalRecordingDuration == 120)
        #expect(stats.averageRecordingDuration == 60)
        #expect(stats.attachmentCount == 2)
        #expect(stats.recentDays.count == 7)
        #expect(stats.recentRecordingCount == 2)
        #expect(stats.recentCaptureCount == 1)
        #expect(stats.recentDays.last?.recordingCount == 1)
        #expect(stats.recentDays.last?.captureCount == 1)
        #expect(stats.captureSources == [
            ActivityStats.CaptureSourceTotal(source: .shareExtension, count: 1)
        ])
    }

    @Test func deduplicatesCaptureRetriesAndUsesDeliveryDate() throws {
        let calendar = utcCalendar()
        let now = date(2026, 7, 29, hour: 12, calendar: calendar)
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let oldDelivery = try capture(
            id: requestID,
            createdAt: date(2026, 7, 20, calendar: calendar),
            deliveredAt: date(2026, 7, 27, calendar: calendar),
            source: .widget,
            outcome: .delivered,
            attachments: 1
        )
        let latestDelivery = try capture(
            id: requestID,
            createdAt: date(2026, 7, 20, calendar: calendar),
            deliveredAt: date(2026, 7, 29, calendar: calendar),
            source: .shortcut,
            outcome: .delivered,
            attachments: 3
        )

        let stats = ActivityStats(
            transcripts: [],
            captureRecords: [oldDelivery, latestDelivery],
            now: now,
            calendar: calendar
        )

        #expect(stats.captureCount == 1)
        #expect(stats.attachmentCount == 3)
        #expect(stats.recentCaptureCount == 1)
        #expect(stats.recentDays.last?.captureCount == 1)
        #expect(stats.captureSources == [
            ActivityStats.CaptureSourceTotal(source: .shortcut, count: 1)
        ])
    }

    @Test func transcriptStoreTracksCompletedRecordingAfterHistoryIsCleared() throws {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStatsTranscriptTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let coordinator = ProcessLocalCaptureFileCoordinator()
        let statsStore = ActivityStatsStore(
            fileURL: folderURL.appendingPathComponent(ActivityStatsStore.defaultFilename),
            coordinator: coordinator
        )
        let transcriptStore = TranscriptStore(
            fileURL: folderURL.appendingPathComponent("transcripts.json"),
            coordinator: coordinator,
            activityStatsStore: statsStore
        )
        let recordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
        let recording = transcript(id: recordingID, date: Date(timeIntervalSince1970: 100), duration: 75)

        transcriptStore.add(recording)
        transcriptStore.add(recording)
        transcriptStore.clear()

        #expect(transcriptStore.transcripts.isEmpty)
        #expect(try statsStore.load().recordings == [
            RecordingActivityEvent(id: recordingID, date: recording.date, duration: 75)
        ])
    }

    @Test func emitsZeroFilledDaysAndExcludesFutureActivity() {
        let calendar = utcCalendar()
        let now = date(2026, 7, 29, hour: 12, calendar: calendar)
        let future = transcript(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
            date: date(2026, 7, 30, calendar: calendar),
            duration: 10
        )

        let stats = ActivityStats(
            transcripts: [future],
            captureRecords: [],
            now: now,
            calendar: calendar,
            recentDayCount: 3
        )

        #expect(stats.recordingCount == 1)
        #expect(stats.recentDays.count == 3)
        #expect(stats.recentDays.map(\.recordingCount) == [0, 0, 0])
        #expect(stats.recentDays.map(\.captureCount) == [0, 0, 0])
    }

    private func transcript(id: UUID, date: Date, duration: TimeInterval) -> Transcript {
        Transcript(
            id: id,
            text: "Transcript",
            date: date,
            duration: duration,
            modelUsed: "test",
            language: "en"
        )
    }

    private func capture(
        id: UUID,
        createdAt: Date,
        deliveredAt: Date?,
        source: CaptureSource,
        outcome: CaptureHistoryOutcome,
        attachments: Int
    ) throws -> CaptureHistoryRecord {
        try CaptureHistoryRecord(
            requestID: id,
            createdAt: createdAt,
            deliveredAt: deliveredAt,
            source: source,
            outcome: outcome,
            destinationID: destinationID,
            destinationName: "Notes",
            relativeNotePath: "Notes/capture.md",
            attachmentCount: attachments,
            failureCategory: outcome == .failed ? .fileWrite : nil
        )
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 0,
        calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
    }
}
