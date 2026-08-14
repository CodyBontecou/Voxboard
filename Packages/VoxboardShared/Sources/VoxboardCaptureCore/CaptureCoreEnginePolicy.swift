import Foundation

/// Portable, binary-free M2 payload passed to a comparison adapter. It contains only
/// the bounded new-note text/link facts needed by the shared core; security-scoped
/// bookmarks, absolute URLs, native handles, and persistence objects never cross it.
public enum CaptureCorePayloadDTO: Equatable, Sendable {
    case text(text: String)
    case link(url: String, label: String)
}

public struct CaptureCoreFrontmatterFieldDTO: Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// One immutable admission snapshot. Shadow and Rust-test routing receive this exact
/// value once, before quota, filesystem, queue, attachment, or success side effects.
public struct CaptureCoreAdmittedInput: Equatable, Sendable {
    public let requestID: UUID
    public let createdAtEpochMilliseconds: Int64
    public let captureSource: String
    public let timezone: String
    public let locale: String
    public let destinationID: UUID
    public let logicalFolder: [String]
    public let noteNameTemplate: String
    public let payloads: [CaptureCorePayloadDTO]
    public let entryPrefix: String
    public let orderedFrontmatter: [CaptureCoreFrontmatterFieldDTO]
    public let retryMarkerEnabled: Bool
    public let finalNewline: Bool

    public init(
        requestID: UUID,
        createdAtEpochMilliseconds: Int64,
        captureSource: String,
        timezone: String,
        locale: String,
        destinationID: UUID,
        logicalFolder: [String],
        noteNameTemplate: String,
        payloads: [CaptureCorePayloadDTO],
        entryPrefix: String,
        orderedFrontmatter: [CaptureCoreFrontmatterFieldDTO],
        retryMarkerEnabled: Bool,
        finalNewline: Bool
    ) {
        self.requestID = requestID
        self.createdAtEpochMilliseconds = createdAtEpochMilliseconds
        self.captureSource = captureSource
        self.timezone = timezone
        self.locale = locale
        self.destinationID = destinationID
        self.logicalFolder = logicalFolder
        self.noteNameTemplate = noteNameTemplate
        self.payloads = payloads
        self.entryPrefix = entryPrefix
        self.orderedFrontmatter = orderedFrontmatter
        self.retryMarkerEnabled = retryMarkerEnabled
        self.finalNewline = finalNewline
    }
}

public enum CaptureCoreAdmissionError: String, Error, Equatable, LocalizedError, Sendable {
    case destinationMismatch
    case unsupportedSource
    case unsupportedNoteTarget
    case unsupportedPayload
    case unsupportedRequestPolicy
    case unsupportedDestinationPolicy
    case unsupportedLogicalFolderToken
    case unsupportedNoteNameToken
    case unsupportedEntrySourceToken
    case unsupportedCalendarSemantics
    case unsupportedWeekRules
    case unsupportedTimeZone
    case unsupportedFrontmatterComposition
    case aggregateControlBoundExceeded
    case contractBoundExceeded

    public var errorDescription: String? {
        "The capture is not admitted to the M2 shared-core profile (\(rawValue))."
    }
}

public enum CaptureCoreAdmission {
    private static let maximumPayloads = 128
    private static let maximumTextCharacters = 65_536
    private static let maximumURLCharacters = 8_192
    private static let maximumLabelCharacters = 4_096
    private static let maximumPathSegments = 32
    private static let maximumPathSegmentCharacters = 255
    private static let maximumNoteTemplateCharacters = 1_024
    private static let maximumFrontmatterFields = 128
    private static let maximumFrontmatterNameCharacters = 128
    private static let maximumFrontmatterValueCharacters = 8_192
    private static let maximumTemplateBytes = 256 * 1_024 * 1_024
    private static let maximumControlBytes = 1_048_576
    private static let controlFixedOverheadBytes = 65_536
    private static let controlPerPayloadOverheadBytes = 128
    private static let controlPerFrontmatterFieldOverheadBytes = 96
    private static let materializationCandidateCount = 256
    private static let pathRenderedTokens = [
        "{period}", "{timestamp}", "{date}", "{time}", "{year}", "{YR}",
        "{month}", "{day}", "{week}", "{hour}", "{minute}", "{second}",
        "{id}", "{id8}",
    ]
    private static let calendarTokens = [
        "{timestamp}", "{date}", "{time}", "{year}", "{YR}", "{month}",
        "{day}", "{week}", "{hour}", "{minute}", "{second}",
    ]
    private static let maximumPathTokenReplacementBytes = [
        "{timestamp}": 19, "{date}": 10, "{time}": 6, "{year}": 4, "{YR}": 2,
        "{month}": 2, "{day}": 2, "{week}": 8, "{hour}": 2, "{minute}": 2,
        "{second}": 2, "{id}": 36, "{id8}": 8,
    ]

    public static func admit(
        request: CaptureRequest,
        destination: CaptureDestination,
        calendar: Calendar
    ) throws -> CaptureCoreAdmittedInput {
        guard request.destinationID == destination.id else {
            throw CaptureCoreAdmissionError.destinationMismatch
        }
        guard request.deliveryKind == .standard,
              request.voxProcessingState == .notRequested,
              request.originDraftUpdatedAt == nil,
              request.relativeNotePathOverride == nil,
              request.placementOverride == nil,
              request.entryTemplateIDOverride == nil,
              request.attachmentsFolderNameOverride == nil,
              request.voxProfile == nil,
              request.locationOutcome == nil,
              request.locationDecisionOverride == nil else {
            throw CaptureCoreAdmissionError.unsupportedRequestPolicy
        }
        guard destination.entrySuffix.isEmpty,
              destination.entryTemplateID == nil,
              destination.markdownTemplatePath == nil,
              destination.placement == .append else {
            throw CaptureCoreAdmissionError.unsupportedDestinationPolicy
        }
        guard case .newNote(let pathTemplate) = destination.noteTarget else {
            throw CaptureCoreAdmissionError.unsupportedNoteTarget
        }
        guard let captureSource = portableSource(request.source) else {
            throw CaptureCoreAdmissionError.unsupportedSource
        }
        guard (1...maximumPayloads).contains(request.payloads.count) else {
            throw CaptureCoreAdmissionError.contractBoundExceeded
        }

        let pathParts = pathTemplate.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let logicalFolder = Array(pathParts.dropLast())
        guard !pathParts.isEmpty,
              logicalFolder.count < maximumPathSegments,
              logicalFolder.allSatisfy({
                  (1...maximumPathSegmentCharacters).contains($0.unicodeScalars.count)
              }),
              let noteNameTemplate = pathParts.last,
              (1...maximumNoteTemplateCharacters).contains(noteNameTemplate.unicodeScalars.count) else {
            throw CaptureCoreAdmissionError.contractBoundExceeded
        }
        let boundaryWhitespace = CharacterSet.whitespacesAndNewlines
        guard pathParts.allSatisfy({
            $0 == $0.trimmingCharacters(in: boundaryWhitespace)
        }) else {
            // Foundation trims the complete rendered path while the portable core
            // trims the filename segment. Boundary whitespace therefore remains
            // legacy-only instead of entering shadow comparison with divergent bytes.
            throw CaptureCoreAdmissionError.unsupportedDestinationPolicy
        }
        do {
            try CapturePathValidation.validateRelativePath(pathTemplate)
        } catch {
            throw CaptureCoreAdmissionError.unsupportedDestinationPolicy
        }
        guard !logicalFolder.contains(where: containsOutputAffectingPathToken) else {
            throw CaptureCoreAdmissionError.unsupportedLogicalFolderToken
        }
        guard !noteNameTemplate.contains("{period}"),
              !noteNameTemplate.contains("{source}") else {
            throw CaptureCoreAdmissionError.unsupportedNoteNameToken
        }
        if request.source == .shareExtension,
           destination.entryPrefix.contains("{source}") {
            throw CaptureCoreAdmissionError.unsupportedEntrySourceToken
        }

        let outputTemplates = [noteNameTemplate, destination.entryPrefix]
        let usesCalendar = outputTemplates.contains { template in
            calendarTokens.contains { template.contains($0) }
        }
        let usesWeek = outputTemplates.contains { $0.contains("{week}") }
        if usesCalendar,
           calendar.identifier != .gregorian,
           calendar.identifier != .iso8601 {
            throw CaptureCoreAdmissionError.unsupportedCalendarSemantics
        }
        if usesWeek,
           (calendar.firstWeekday != 2 || calendar.minimumDaysInFirstWeek != 4) {
            throw CaptureCoreAdmissionError.unsupportedWeekRules
        }
        let timezone = calendar.timeZone.identifier
        if timezone != "UTC",
           !TimeZone.knownTimeZoneIdentifiers.contains(timezone) {
            // Fixed-offset and other Foundation-only identifiers are not guaranteed
            // to parse in chrono-tz, so M2 admission fails closed.
            throw CaptureCoreAdmissionError.unsupportedTimeZone
        }
        let renderedPath: String
        do {
            renderedPath = try CapturePathPlanner(calendar: calendar).relativePath(
                for: request,
                destination: destination
            )
        } catch {
            throw CaptureCoreAdmissionError.unsupportedDestinationPolicy
        }
        let renderedFilename = (renderedPath as NSString).lastPathComponent as NSString
        let renderedExtension = renderedFilename.pathExtension
        let renderedStem = renderedFilename.deletingPathExtension
        let finalCandidate = renderedExtension.isEmpty
            ? "\(renderedStem)-256"
            : "\(renderedStem)-256.\(renderedExtension)"
        guard finalCandidate.unicodeScalars.count <= maximumPathSegmentCharacters else {
            // Preparation publishes all 256 occupancy candidates. Bound the longest
            // suffix, not only the first production path, to the portable 255-scalar
            // segment contract.
            throw CaptureCoreAdmissionError.contractBoundExceeded
        }

        let payloads = try request.payloads.map { payload -> CaptureCorePayloadDTO in
            switch payload {
            case .text(let text):
                guard text.unicodeScalars.count <= maximumTextCharacters else {
                    throw CaptureCoreAdmissionError.contractBoundExceeded
                }
                // Production hoists payload-leading frontmatter before applying the
                // destination prefix and request metadata. The M2 Rust profile owns a
                // different merge order, so that broader composition stays legacy-only.
                guard !hasLeadingFrontmatter(text, trimmingBoundaryNewlines: true) else {
                    throw CaptureCoreAdmissionError.unsupportedFrontmatterComposition
                }
                return .text(text: text)
            case .url(let url, let title):
                let absolute = url.absoluteString
                let label = title ?? ""
                guard (absolute.hasPrefix("http://") || absolute.hasPrefix("https://")),
                      (1...maximumURLCharacters).contains(absolute.unicodeScalars.count),
                      label.unicodeScalars.count <= maximumLabelCharacters else {
                    throw CaptureCoreAdmissionError.unsupportedPayload
                }
                return .link(url: absolute, label: label)
            default:
                throw CaptureCoreAdmissionError.unsupportedPayload
            }
        }

        let orderedFrontmatter = try request.frontmatter.keys.sorted().map { key in
            let value = request.frontmatter[key] ?? ""
            guard (1...maximumFrontmatterNameCharacters).contains(key.unicodeScalars.count),
                  value.unicodeScalars.count <= maximumFrontmatterValueCharacters,
                  !key.contains("\n"),
                  !key.contains("\r") else {
                throw CaptureCoreAdmissionError.contractBoundExceeded
            }
            return CaptureCoreFrontmatterFieldDTO(name: key, value: value)
        }
        guard orderedFrontmatter.count <= maximumFrontmatterFields,
              destination.entryPrefix.utf8.count <= maximumTemplateBytes else {
            throw CaptureCoreAdmissionError.contractBoundExceeded
        }
        // Swift merges request metadata before prefix frontmatter, while M2 Rust
        // begins with prefix frontmatter. Avoid claiming byte parity for that order.
        if !orderedFrontmatter.isEmpty,
           hasLeadingFrontmatter(destination.entryPrefix, trimmingBoundaryNewlines: false) {
            throw CaptureCoreAdmissionError.unsupportedFrontmatterComposition
        }

        let milliseconds = request.createdAt.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds <= 4_102_444_800_000 else {
            throw CaptureCoreAdmissionError.contractBoundExceeded
        }
        let locale = calendar.locale?.identifier ?? "en_US_POSIX"
        guard (1...64).contains(timezone.unicodeScalars.count),
              (2...35).contains(locale.unicodeScalars.count) else {
            throw CaptureCoreAdmissionError.contractBoundExceeded
        }
        guard controlBudget(
            captureSource: captureSource,
            timezone: timezone,
            locale: locale,
            logicalFolder: logicalFolder,
            noteNameTemplate: noteNameTemplate,
            payloads: payloads,
            entryPrefix: destination.entryPrefix,
            orderedFrontmatter: orderedFrontmatter
        ) < maximumControlBytes else {
            throw CaptureCoreAdmissionError.aggregateControlBoundExceeded
        }

        return CaptureCoreAdmittedInput(
            requestID: request.id,
            createdAtEpochMilliseconds: Int64(milliseconds.rounded(.towardZero)),
            captureSource: captureSource,
            timezone: timezone,
            locale: locale,
            destinationID: destination.id,
            logicalFolder: logicalFolder,
            noteNameTemplate: noteNameTemplate,
            payloads: payloads,
            entryPrefix: destination.entryPrefix,
            orderedFrontmatter: orderedFrontmatter,
            retryMarkerEnabled: destination.retryProtectionEnabled,
            // Existing Apple production behavior remains unchanged until promotion.
            finalNewline: false
        )
    }

    private static func portableSource(_ source: CaptureSource) -> String? {
        switch source {
        case .app, .keyboard, .widget, .shortcut, .watch:
            return source.rawValue
        case .shareExtension:
            return "share"
        case .mac, .deepLink, .fileImport, .voice:
            return nil
        }
    }

    private static func containsOutputAffectingPathToken(_ segment: String) -> Bool {
        pathRenderedTokens.contains { segment.contains($0) }
    }

    private static func hasLeadingFrontmatter(
        _ value: String,
        trimmingBoundaryNewlines: Bool
    ) -> Bool {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let candidate = trimmingBoundaryNewlines
            ? normalized.trimmingCharacters(in: .newlines)
            : normalized
        let lines = candidate.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---",
              let closing = lines.indices.dropFirst().first(where: { lines[$0] == "---" }) else {
            return false
        }
        return lines[1..<closing].contains { rawLine in
            guard rawLine.first != " ", rawLine.first != "\t", !rawLine.hasPrefix("#"),
                  let colon = rawLine.firstIndex(of: ":") else {
                return false
            }
            return !String(rawLine[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Upper-bounds canonical JSON control bytes rather than relying on the looser
    /// per-field scalar limits. JSON escaping can expand one UTF-8 byte to six bytes,
    /// and candidate occupancy may repeat every path 256 times in materialization.
    private static func controlBudget(
        captureSource: String,
        timezone: String,
        locale: String,
        logicalFolder: [String],
        noteNameTemplate: String,
        payloads: [CaptureCorePayloadDTO],
        entryPrefix: String,
        orderedFrontmatter: [CaptureCoreFrontmatterFieldDTO]
    ) -> Int {
        var total = controlFixedOverheadBytes

        func addJSONEscapedByteCount(_ byteCount: Int, repetitions: Int = 1) {
            let (escapedBytes, escapedOverflow) = byteCount.multipliedReportingOverflow(by: 6)
            let (repeatedBytes, repeatedOverflow) = escapedBytes.multipliedReportingOverflow(by: repetitions)
            let (next, additionOverflow) = total.addingReportingOverflow(repeatedBytes)
            total = escapedOverflow || repeatedOverflow || additionOverflow ? .max : next
        }

        func addJSONEscaped(_ value: String, repetitions: Int = 1) {
            addJSONEscapedByteCount(value.utf8.count, repetitions: repetitions)
        }

        addJSONEscaped(captureSource)
        addJSONEscaped(timezone)
        addJSONEscaped(locale)
        // The preset contains the path once and a worst-case occupancy observation
        // can contain all 256 candidates. Candidate note names use rendered token sizes.
        let pathRepetitions = materializationCandidateCount + 1
        logicalFolder.forEach { addJSONEscaped($0, repetitions: pathRepetitions) }
        addJSONEscaped(noteNameTemplate)
        addJSONEscapedByteCount(
            renderedNoteNameByteUpperBound(noteNameTemplate),
            repetitions: materializationCandidateCount
        )
        addJSONEscaped(entryPrefix)

        for payload in payloads {
            total = total.addingReportingOverflow(controlPerPayloadOverheadBytes).partialValue
            switch payload {
            case .text(let text):
                addJSONEscaped(text)
            case .link(let url, let label):
                addJSONEscaped(url)
                addJSONEscaped(label)
            }
        }
        for field in orderedFrontmatter {
            total = total.addingReportingOverflow(controlPerFrontmatterFieldOverheadBytes).partialValue
            addJSONEscaped(field.name)
            addJSONEscaped(field.value)
        }
        return total
    }

    private static func renderedNoteNameByteUpperBound(_ template: String) -> Int {
        maximumPathTokenReplacementBytes.reduce(template.utf8.count) { result, item in
            let occurrences = template.components(separatedBy: item.key).count - 1
            let expansion = max(0, item.value - item.key.utf8.count)
            return result + occurrences * expansion
        }
    }

}

/// Privacy-safe comparison facts only. No captured content or logical path can be
/// returned through this boundary or included in a diagnostic.
public struct CaptureCoreComparison: Equatable, Sendable {
    public let readinessMatched: Bool
    public let logicalPathMatched: Bool
    public let bytesMatched: Bool
    public let resultHashMatched: Bool

    public init(
        readinessMatched: Bool,
        logicalPathMatched: Bool,
        bytesMatched: Bool,
        resultHashMatched: Bool
    ) {
        self.readinessMatched = readinessMatched
        self.logicalPathMatched = logicalPathMatched
        self.bytesMatched = bytesMatched
        self.resultHashMatched = resultHashMatched
    }

    public var isExactMatch: Bool {
        readinessMatched && logicalPathMatched && bytesMatched && resultHashMatched
    }
}

public protocol CaptureCoreComparing: Sendable {
    func compare(_ input: CaptureCoreAdmittedInput) async throws -> CaptureCoreComparison
}

public enum CaptureCoreEngineError: String, Error, Equatable, LocalizedError, Sendable {
    case rustComparisonFailed
    case rustCommitNotPromoted

    public var errorDescription: String? {
        "Shared-core routing stopped before native side effects (\(rawValue))."
    }
}

public struct CaptureCoreEnginePolicy: Sendable {
    private enum Mode: Sendable {
        case legacy
        case shadow
        case rust
    }

    private let mode: Mode
    private let comparator: (any CaptureCoreComparing)?

    public static let legacy = CaptureCoreEnginePolicy(mode: .legacy, comparator: nil)

    public static func shadow(using comparator: any CaptureCoreComparing) -> Self {
        Self(mode: .shadow, comparator: comparator)
    }

    /// Rust authority is deliberately unavailable to normal product imports during M2.
    /// Tests may prove admission and the pre-commit barrier without creating user files.
    @_spi(Testing)
    public static func rust(using comparator: any CaptureCoreComparing) -> Self {
        Self(mode: .rust, comparator: comparator)
    }

    private init(mode: Mode, comparator: (any CaptureCoreComparing)?) {
        self.mode = mode
        self.comparator = comparator
    }

    func route(
        request: CaptureRequest,
        destination: CaptureDestination,
        calendar: Calendar
    ) async throws -> CaptureCoreEngineRoute {
        switch mode {
        case .legacy:
            return .legacy
        case .shadow:
            guard let admitted = try? CaptureCoreAdmission.admit(
                request: request,
                destination: destination,
                calendar: calendar
            ) else {
                return .legacy
            }
            if let comparator {
                _ = try? await comparator.compare(admitted)
            }
            return .legacy
        case .rust:
            let admitted = try CaptureCoreAdmission.admit(
                request: request,
                destination: destination,
                calendar: calendar
            )
            guard let comparator,
                  try await comparator.compare(admitted).isExactMatch else {
                throw CaptureCoreEngineError.rustComparisonFailed
            }
            return .rustCommitBarrier
        }
    }
}

enum CaptureCoreEngineRoute: Sendable {
    case legacy
    case rustCommitBarrier
}
