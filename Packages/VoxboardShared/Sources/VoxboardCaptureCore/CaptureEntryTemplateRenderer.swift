import Foundation

/// Renders metadata tokens only inside destination entry formatting. Capture
/// payload text is never interpolated, so a user's literal `{date}` stays intact.
public struct CaptureEntryTemplateRenderer: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func render(_ template: String, for request: CaptureRequest) -> String {
        let values = CaptureDateTokenValues(date: request.createdAt, calendar: calendar)
        let id = request.id.uuidString.lowercased()
        let replacements = [
            "{timestamp}": values.timestamp,
            "{date}": values.date,
            "{time}": values.time,
            "{year}": values.year,
            "{YR}": values.shortYear,
            "{month}": values.month,
            "{day}": values.day,
            "{week}": values.weekToken,
            "{hour}": values.hour,
            "{minute}": values.minute,
            "{second}": values.second,
            "{source}": request.source.rawValue,
            "{id}": id,
            "{id8}": String(id.prefix(8)),
        ]
        return replacements.reduce(template) { rendered, replacement in
            rendered.replacingOccurrences(of: replacement.key, with: replacement.value)
        }
    }
}
