import Foundation

struct CaptureDateTokenValues: Sendable {
    let year: String
    let shortYear: String
    let month: String
    let day: String
    let hour: String
    let minute: String
    let second: String
    let weekYear: String
    let week: String

    init(date: Date, calendar: Calendar) {
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekOfYear, .yearForWeekOfYear],
            from: date
        )
        year = Self.padded(components.year, width: 4)
        shortYear = String(year.suffix(2))
        month = Self.padded(components.month, width: 2)
        day = Self.padded(components.day, width: 2)
        hour = Self.padded(components.hour, width: 2)
        minute = Self.padded(components.minute, width: 2)
        second = Self.padded(components.second, width: 2)
        weekYear = Self.padded(components.yearForWeekOfYear ?? components.year, width: 4)
        week = Self.padded(components.weekOfYear, width: 2)
    }

    var timestamp: String { "\(year)-\(month)-\(day)-\(hour)\(minute)\(second)" }
    var date: String { "\(year)-\(month)-\(day)" }
    var time: String { "\(hour)\(minute)\(second)" }
    var weekToken: String { "\(weekYear)-W\(week)" }

    private static func padded(_ value: Int?, width: Int) -> String {
        String(format: "%0*d", width, value ?? 0)
    }
}
