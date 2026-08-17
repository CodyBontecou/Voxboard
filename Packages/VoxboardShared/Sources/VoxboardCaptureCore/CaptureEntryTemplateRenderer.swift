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
            "{location}": locationMapLink(for: request),
        ]
        return replacements.reduce(template) { rendered, replacement in
            rendered.replacingOccurrences(of: replacement.key, with: replacement.value)
        }
    }

    private func locationMapLink(for request: CaptureRequest) -> String {
        guard let policy = request.voxProfile?.locationPolicy,
              policy.isEnabled,
              case .available(let snapshot)? = request.locationOutcome else { return "" }
        let usesCityPrecision = policy.precision == .city || snapshot.precision == .city
        let effectivePrecision: CaptureLocationPrecision = usesCityPrecision ? .city : .exact
        guard let formatted = try? CaptureLocationFormatter().format(
            snapshot: snapshot,
            requestID: request.id,
            precision: effectivePrecision
        ), let url = formatted[.googleMapsURL] else { return "" }
        return "[Location](\(url))"
    }
}
