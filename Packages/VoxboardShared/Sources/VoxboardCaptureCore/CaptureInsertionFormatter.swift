import Foundation

public enum CaptureInsertionFormatterError: Error, Equatable, LocalizedError, Sendable {
    case invalidWikiLink
    case invalidCoordinates

    public var errorDescription: String? {
        switch self {
        case .invalidWikiLink:
            return "The wiki-link target is not safe."
        case .invalidCoordinates:
            return "The map coordinates are invalid."
        }
    }
}

public enum CaptureDueDateShortcut: Equatable, Sendable {
    case today
    case tomorrow
    case thisWeekend
}

public enum CaptureDueDateAdjustmentUnit: Equatable, Sendable {
    case minute
    case hour
}

/// Deterministic insertion formatting with explicit calendrical dependencies.
///
/// Date output is stable for a given Calendar, Locale, and TimeZone. Callers can
/// pass the user's current dependencies in production and fixed values in tests.
public struct CaptureInsertionFormatter: Sendable {
    public let calendar: Calendar
    public let locale: Locale
    public let timeZone: TimeZone

    public init(
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        var configuredCalendar = calendar
        configuredCalendar.locale = locale
        configuredCalendar.timeZone = timeZone
        self.calendar = configuredCalendar
        self.locale = locale
        self.timeZone = timeZone
    }

    public func dueDateToken(for date: Date, includeTime: Bool = false) -> String {
        let pattern = includeTime ? "yyyy-MM-dd hh:mm a" : "yyyy-MM-dd"
        return "(@\(formatted(date, pattern: pattern)))"
    }

    public func currentTimestamp(at date: Date = Date()) -> String {
        formatted(date, pattern: "h:mm a yyyy-MM-dd")
    }

    public func timestamp(for date: Date) -> String {
        currentTimestamp(at: date)
    }

    /// Produces an Obsidian-style wiki link after normalizing path separators.
    /// Absolute paths, traversal components, controls, and wiki syntax injection
    /// are rejected. A final `.md` extension is removed case-insensitively.
    public func wikiLink(for target: String) throws -> String {
        guard !target.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CaptureInsertionFormatterError.invalidWikiLink
        }

        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~") else {
            throw CaptureInsertionFormatterError.invalidWikiLink
        }

        let separatorNormalized = trimmed.replacingOccurrences(of: "\\", with: "/")
        guard !separatorNormalized.hasPrefix("/"),
              !hasWindowsDrivePrefix(separatorNormalized),
              !separatorNormalized.contains("["),
              !separatorNormalized.contains("]"),
              !separatorNormalized.contains("|") else {
            throw CaptureInsertionFormatterError.invalidWikiLink
        }

        var components = separatorNormalized
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CaptureInsertionFormatterError.invalidWikiLink
        }

        if let last = components.last, last.lowercased().hasSuffix(".md") {
            components[components.count - 1] = String(last.dropLast(3))
        }
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CaptureInsertionFormatterError.invalidWikiLink
        }

        return "[[\(components.joined(separator: "/"))]]"
    }

    /// Produces a Google Maps Markdown link with locale-independent decimal
    /// coordinates and a label escaped for Markdown's bracket syntax.
    public func googleMapsLink(
        latitude: Double,
        longitude: Double,
        label: String = "Location"
    ) throws -> String {
        guard latitude.isFinite,
              longitude.isFinite,
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else {
            throw CaptureInsertionFormatterError.invalidCoordinates
        }

        let latitudeText = posixCoordinate(latitude)
        let longitudeText = posixCoordinate(longitude)
        return "[\(escapedMarkdownLabel(label))](https://www.google.com/maps?q=\(latitudeText),\(longitudeText))"
    }

    /// Applies a due-date shortcut while preserving the reference time of day.
    /// `thisWeekend` returns the reference date when it is already a weekend;
    /// otherwise it finds the next weekend day using the injected Calendar.
    public func applying(_ shortcut: CaptureDueDateShortcut, to date: Date) -> Date {
        switch shortcut {
        case .today:
            return date
        case .tomorrow:
            return calendar.date(byAdding: .day, value: 1, to: date) ?? date
        case .thisWeekend:
            guard !calendar.isDateInWeekend(date) else { return date }
            var candidate = date
            for _ in 0..<8 {
                guard let next = calendar.date(byAdding: .day, value: 1, to: candidate) else {
                    return date
                }
                candidate = next
                if calendar.isDateInWeekend(candidate) {
                    return candidate
                }
            }
            return date
        }
    }

    /// Adjusts a due date with Calendar arithmetic, so midnight and daylight
    /// saving transitions follow the injected calendar and time zone.
    public func adjusting(
        _ date: Date,
        by value: Int,
        unit: CaptureDueDateAdjustmentUnit
    ) -> Date {
        let component: Calendar.Component
        switch unit {
        case .minute:
            component = .minute
        case .hour:
            component = .hour
        }
        return calendar.date(byAdding: component, value: value, to: date) ?? date
    }

    private func formatted(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private func posixCoordinate(_ value: Double) -> String {
        let normalized = abs(value) < 0.0000005 ? 0 : value
        return String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            normalized
        )
    }

    private func escapedMarkdownLabel(_ value: String) -> String {
        var sanitized = ""
        for scalar in value.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) {
                sanitized.append(" ")
            } else {
                sanitized.unicodeScalars.append(scalar)
            }
        }
        return sanitized
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private func hasWindowsDrivePrefix(_ value: String) -> Bool {
        let source = value as NSString
        guard source.length >= 3,
              source.character(at: 1) == 58,
              source.character(at: 2) == 47 else {
            return false
        }
        let first = source.character(at: 0)
        return (65...90).contains(first) || (97...122).contains(first)
    }
}
