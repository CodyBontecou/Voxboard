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
    case contractBoundExceeded

    public var errorDescription: String? {
        "The capture is not admitted to the M2 shared-core profile (\(rawValue))."
    }
}

public enum CaptureCoreAdmission {
    private static let maximumPayloads = 128
    private static let maximumTextBytes = 65_536
    private static let maximumURLBytes = 8_192
    private static let maximumLabelBytes = 4_096
    private static let maximumPathSegments = 32
    private static let maximumNoteTemplateBytes = 1_024
    private static let maximumFrontmatterFields = 128
    private static let maximumFrontmatterNameBytes = 128
    private static let maximumFrontmatterValueBytes = 8_192
    private static let maximumTemplateBytes = 256 * 1_024 * 1_024

    public static func admit(
        request: CaptureRequest,
        destination: CaptureDestination,
        calendar: Calendar
    ) throws -> CaptureCoreAdmittedInput {
        guard request.destinationID == destination.id else {
            throw CaptureCoreAdmissionError.destinationMismatch
        }
        guard request.relativeNotePathOverride == nil,
              request.placementOverride == nil,
              request.entryTemplateIDOverride == nil,
              request.attachmentsFolderNameOverride == nil,
              request.voxProfile == nil,
              request.locationOutcome == nil,
              request.locationDecisionOverride == nil else {
            throw CaptureCoreAdmissionError.unsupportedRequestPolicy
        }
        guard destination.entrySuffix.isEmpty,
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
        guard !pathParts.isEmpty,
              pathParts.count <= maximumPathSegments,
              let noteNameTemplate = pathParts.last,
              noteNameTemplate.utf8.count <= maximumNoteTemplateBytes else {
            throw CaptureCoreAdmissionError.contractBoundExceeded
        }
        do {
            try CapturePathValidation.validateRelativePath(pathTemplate)
        } catch {
            throw CaptureCoreAdmissionError.unsupportedDestinationPolicy
        }

        let payloads = try request.payloads.map { payload -> CaptureCorePayloadDTO in
            switch payload {
            case .text(let text):
                guard text.utf8.count <= maximumTextBytes else {
                    throw CaptureCoreAdmissionError.contractBoundExceeded
                }
                return .text(text: text)
            case .url(let url, let title):
                let absolute = url.absoluteString
                let label = title ?? ""
                guard (url.scheme == "http" || url.scheme == "https"),
                      (1...maximumURLBytes).contains(absolute.utf8.count),
                      label.utf8.count <= maximumLabelBytes else {
                    throw CaptureCoreAdmissionError.unsupportedPayload
                }
                return .link(url: absolute, label: label)
            default:
                throw CaptureCoreAdmissionError.unsupportedPayload
            }
        }

        let orderedFrontmatter = try request.frontmatter.keys.sorted().map { key in
            let value = request.frontmatter[key] ?? ""
            guard (1...maximumFrontmatterNameBytes).contains(key.utf8.count),
                  value.utf8.count <= maximumFrontmatterValueBytes,
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

        let milliseconds = request.createdAt.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds <= 4_102_444_800_000 else {
            throw CaptureCoreAdmissionError.contractBoundExceeded
        }
        let timezone = calendar.timeZone.identifier
        let locale = calendar.locale?.identifier ?? "en_US_POSIX"
        guard (1...64).contains(timezone.utf8.count),
              (2...35).contains(locale.utf8.count) else {
            throw CaptureCoreAdmissionError.contractBoundExceeded
        }

        return CaptureCoreAdmittedInput(
            requestID: request.id,
            createdAtEpochMilliseconds: Int64(milliseconds.rounded(.towardZero)),
            captureSource: captureSource,
            timezone: timezone,
            locale: locale,
            destinationID: destination.id,
            logicalFolder: Array(pathParts.dropLast()),
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
