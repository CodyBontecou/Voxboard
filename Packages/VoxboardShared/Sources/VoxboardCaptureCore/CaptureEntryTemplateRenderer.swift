import Foundation

/// Renders metadata tokens only inside destination entry formatting. Capture
/// payload text is never interpolated, so a user's literal `{date}` stays intact.
public struct CaptureEntryTemplateRenderer: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func render(_ template: String, for request: CaptureRequest) -> String {
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekOfYear, .yearForWeekOfYear],
            from: request.createdAt
        )
        let year = padded(components.year, width: 4)
        let month = padded(components.month, width: 2)
        let day = padded(components.day, width: 2)
        let hour = padded(components.hour, width: 2)
        let minute = padded(components.minute, width: 2)
        let second = padded(components.second, width: 2)
        let weekYear = padded(components.yearForWeekOfYear ?? components.year, width: 4)
        let week = padded(components.weekOfYear, width: 2)
        let id = request.id.uuidString.lowercased()
        let replacements = [
            "{timestamp}": "\(year)-\(month)-\(day)-\(hour)\(minute)\(second)",
            "{date}": "\(year)-\(month)-\(day)",
            "{time}": "\(hour)\(minute)\(second)",
            "{year}": year,
            "{month}": month,
            "{day}": day,
            "{week}": "\(weekYear)-W\(week)",
            "{source}": request.source.rawValue,
            "{id}": id,
            "{id8}": String(id.prefix(8)),
        ]
        return replacements.reduce(template) { rendered, replacement in
            rendered.replacingOccurrences(of: replacement.key, with: replacement.value)
        }
    }

    private func padded(_ value: Int?, width: Int) -> String {
        String(format: "%0*d", width, value ?? 0)
    }
}
