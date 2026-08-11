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
        let components = calendar.dateComponents([.month], from: request.createdAt)
        let values = CaptureDateTokenValues(date: request.createdAt, calendar: calendar)
        let id = request.id.uuidString.lowercased()

        let rollingBucket: String
        switch rollingPeriod {
        case .daily: rollingBucket = values.date
        case .weekly: rollingBucket = values.weekToken
        case .monthly: rollingBucket = "\(values.year)-\(values.month)"
        case .quarterly:
            let quarter = ((components.month ?? 1) - 1) / 3 + 1
            rollingBucket = "\(values.year)-Q\(quarter)"
        case .yearly: rollingBucket = values.year
        case nil: rollingBucket = values.date
        }

        var rendered = template
        let replacements = [
            "{period}": rollingBucket,
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

}
