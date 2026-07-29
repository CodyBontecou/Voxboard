import Foundation

/// A privacy-safe summary of completed recordings and Captures.
public struct ActivityStats: Equatable, Sendable {
    public struct Day: Identifiable, Equatable, Sendable {
        public let date: Date
        public let recordingCount: Int
        public let captureCount: Int

        public var id: Date { date }
        public var totalCount: Int { recordingCount + captureCount }

        public init(date: Date, recordingCount: Int, captureCount: Int) {
            self.date = date
            self.recordingCount = recordingCount
            self.captureCount = captureCount
        }
    }

    public struct CaptureSourceTotal: Identifiable, Equatable, Sendable {
        public let source: CaptureSource
        public let count: Int

        public var id: String { source.rawValue }

        public init(source: CaptureSource, count: Int) {
            self.source = source
            self.count = count
        }
    }

    public let recordingCount: Int
    public let captureCount: Int
    public let totalRecordingDuration: TimeInterval
    public let attachmentCount: Int
    public let recentDays: [Day]
    public let captureSources: [CaptureSourceTotal]

    public var averageRecordingDuration: TimeInterval {
        guard recordingCount > 0 else { return 0 }
        return totalRecordingDuration / Double(recordingCount)
    }

    public var recentRecordingCount: Int {
        recentDays.reduce(0) { $0 + $1.recordingCount }
    }

    public var recentCaptureCount: Int {
        recentDays.reduce(0) { $0 + $1.captureCount }
    }

    /// Builds lifetime statistics from the durable, content-free activity ledger.
    public init(
        ledger: ActivityStatsLedger,
        now: Date = Date(),
        calendar: Calendar = .current,
        recentDayCount: Int = 7
    ) {
        self.init(
            recordings: ledger.recordings,
            captures: ledger.captures,
            now: now,
            calendar: calendar,
            recentDayCount: recentDayCount
        )
    }

    /// Builds a snapshot directly from visible history. This is used to backfill
    /// older installs and as a fallback when App Group storage is unavailable.
    public init(
        transcripts: [Transcript],
        captureRecords: [CaptureHistoryRecord],
        now: Date = Date(),
        calendar: Calendar = .current,
        recentDayCount: Int = 7
    ) {
        self.init(
            recordings: transcripts.map {
                RecordingActivityEvent(id: $0.id, date: $0.date, duration: $0.duration)
            },
            captures: captureRecords.compactMap { record in
                guard record.outcome == .delivered else { return nil }
                return CaptureActivityEvent(
                    id: record.requestID,
                    date: record.deliveredAt ?? record.createdAt,
                    source: record.source,
                    attachmentCount: record.attachmentCount
                )
            },
            now: now,
            calendar: calendar,
            recentDayCount: recentDayCount
        )
    }

    public init(
        recordings: [RecordingActivityEvent],
        captures: [CaptureActivityEvent],
        now: Date = Date(),
        calendar: Calendar = .current,
        recentDayCount: Int = 7
    ) {
        var recordingsByID: [UUID: RecordingActivityEvent] = [:]
        for event in recordings {
            if let existing = recordingsByID[event.id], existing.date > event.date { continue }
            recordingsByID[event.id] = event
        }

        var capturesByID: [UUID: CaptureActivityEvent] = [:]
        for event in captures {
            if let existing = capturesByID[event.id], existing.date > event.date { continue }
            capturesByID[event.id] = event
        }

        let uniqueRecordings = Array(recordingsByID.values)
        let uniqueCaptures = Array(capturesByID.values)
        recordingCount = uniqueRecordings.count
        captureCount = uniqueCaptures.count
        totalRecordingDuration = uniqueRecordings.reduce(0) { $0 + max(0, $1.duration) }
        attachmentCount = uniqueCaptures.reduce(0) { $0 + max(0, $1.attachmentCount) }

        let dayCount = max(1, recentDayCount)
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) ?? today

        var recordingsByDay: [Date: Int] = [:]
        for event in uniqueRecordings {
            let day = calendar.startOfDay(for: event.date)
            guard day >= firstDay, day <= today else { continue }
            recordingsByDay[day, default: 0] += 1
        }

        var capturesByDay: [Date: Int] = [:]
        for event in uniqueCaptures {
            let day = calendar.startOfDay(for: event.date)
            guard day >= firstDay, day <= today else { continue }
            capturesByDay[day, default: 0] += 1
        }

        recentDays = (0..<dayCount).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: firstDay) else {
                return nil
            }
            return Day(
                date: date,
                recordingCount: recordingsByDay[date, default: 0],
                captureCount: capturesByDay[date, default: 0]
            )
        }

        var sourceCounts: [String: (source: CaptureSource, count: Int)] = [:]
        for event in uniqueCaptures {
            let key = event.source.rawValue
            let current = sourceCounts[key]?.count ?? 0
            sourceCounts[key] = (event.source, current + 1)
        }
        captureSources = sourceCounts.values
            .map { CaptureSourceTotal(source: $0.source, count: $0.count) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.source.rawValue < $1.source.rawValue
            }
    }
}
