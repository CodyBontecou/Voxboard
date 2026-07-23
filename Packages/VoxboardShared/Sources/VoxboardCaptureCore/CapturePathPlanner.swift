import Foundation

public struct CapturePathPlanner: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func relativePath(
        for request: CaptureRequest,
        destination: CaptureDestination,
        existingRelativePaths: Set<String> = []
    ) throws -> String {
        switch destination.noteTarget {
        case .newNote(let pathTemplate):
            let rendered = try renderedMarkdownPath(pathTemplate, request: request, rollingPeriod: nil)
            return uniquePath(rendered, avoiding: existingRelativePaths)
        case .rollingNote(let pathTemplate, let period):
            return try renderedMarkdownPath(pathTemplate, request: request, rollingPeriod: period)
        case .existingNote(let relativePath):
            try CapturePathValidation.validateRelativePath(relativePath)
            return relativePath
        }
    }

    private func renderedMarkdownPath(
        _ template: String,
        request: CaptureRequest,
        rollingPeriod: CaptureRollingPeriod?
    ) throws -> String {
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekOfYear, .yearForWeekOfYear],
            from: request.createdAt
        )
        let year = padded(components.year, width: 4)
        let shortYear = String(year.suffix(2))
        let month = padded(components.month, width: 2)
        let day = padded(components.day, width: 2)
        let hour = padded(components.hour, width: 2)
        let minute = padded(components.minute, width: 2)
        let second = padded(components.second, width: 2)
        let weekYear = padded(components.yearForWeekOfYear ?? components.year, width: 4)
        let weekNumber = padded(components.weekOfYear, width: 2)
        let id = request.id.uuidString.lowercased()

        let rollingBucket: String
        switch rollingPeriod {
        case .daily: rollingBucket = "\(year)-\(month)-\(day)"
        case .weekly: rollingBucket = "\(weekYear)-W\(weekNumber)"
        case .monthly: rollingBucket = "\(year)-\(month)"
        case .quarterly:
            let quarter = ((components.month ?? 1) - 1) / 3 + 1
            rollingBucket = "\(year)-Q\(quarter)"
        case .yearly: rollingBucket = year
        case nil: rollingBucket = "\(year)-\(month)-\(day)"
        }

        var rendered = template
        let replacements = [
            "{period}": rollingBucket,
            "{timestamp}": "\(year)-\(month)-\(day)-\(hour)\(minute)\(second)",
            "{date}": "\(year)-\(month)-\(day)",
            "{time}": "\(hour)\(minute)\(second)",
            "{year}": year,
            "{YR}": shortYear,
            "{month}": month,
            "{day}": day,
            "{week}": "\(weekYear)-W\(weekNumber)",
            "{id}": id,
            "{id8}": String(id.prefix(8)),
        ]
        for (token, value) in replacements {
            rendered = rendered.replacingOccurrences(of: token, with: value)
        }

        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = (trimmed as NSString).pathExtension.isEmpty ? trimmed + ".md" : trimmed
        try CapturePathValidation.validateRelativePath(path)
        return path
    }

    private func uniquePath(_ path: String, avoiding existingPaths: Set<String>) -> String {
        guard existingPaths.contains(path) else { return path }
        let nsPath = path as NSString
        let directory = nsPath.deletingLastPathComponent
        let ext = nsPath.pathExtension
        let base = (nsPath.lastPathComponent as NSString).deletingPathExtension

        var index = 2
        while true {
            let filename = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            let candidate = directory.isEmpty || directory == "."
                ? filename
                : (directory as NSString).appendingPathComponent(filename)
            if !existingPaths.contains(candidate) {
                return candidate
            }
            index += 1
        }
    }

    private func padded(_ value: Int?, width: Int) -> String {
        String(format: "%0*d", width, value ?? 0)
    }
}
