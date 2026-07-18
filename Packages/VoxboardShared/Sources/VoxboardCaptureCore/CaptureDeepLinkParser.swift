import Foundation

public enum CaptureRequestedInput: String, CaseIterable, Sendable {
    case photos
    case screenshots
    case camera
    case files
    case scan
    case sketch
    case link
    case voice
}

public struct CaptureDeepLinkDraft: Equatable, Sendable {
    public var text: String?
    public var url: URL?
    public var destinationID: UUID?
    public var voxID: String?
    public var requestedInput: CaptureRequestedInput?
    public var source: CaptureSource?

    public init(
        text: String? = nil,
        url: URL? = nil,
        destinationID: UUID? = nil,
        voxID: String? = nil,
        requestedInput: CaptureRequestedInput? = nil,
        source: CaptureSource? = nil
    ) {
        self.text = text
        self.url = url
        self.destinationID = destinationID
        self.voxID = voxID
        self.requestedInput = requestedInput
        self.source = source
    }
}

public enum CaptureDeepLinkAction: Equatable, Sendable {
    case openComposer(CaptureDeepLinkDraft)
    case processInboxRequest(UUID)
}

public enum CaptureDeepLinkError: Error, Equatable, LocalizedError, Sendable {
    case invalidScheme
    case unknownAction(String)
    case forbiddenParameter(String)
    case duplicateParameter(String)
    case invalidDestination
    case invalidVox
    case invalidURL
    case invalidRequestID
    case invalidAction
    case invalidSource
    case payloadTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidScheme: return "This is not a Vox.md capture link."
        case .unknownAction(let action): return "Unknown Vox.md link action: \(action)"
        case .forbiddenParameter(let name): return "The capture link contains a forbidden parameter: \(name)"
        case .duplicateParameter(let name): return "The capture link repeats a parameter: \(name)"
        case .invalidDestination: return "The capture destination identifier is invalid."
        case .invalidVox: return "The capture Vox identifier is invalid."
        case .invalidURL: return "Only HTTP and HTTPS links can be captured."
        case .invalidRequestID: return "The capture inbox request identifier is invalid."
        case .invalidAction: return "The requested capture input is not supported."
        case .invalidSource: return "The capture link source is not supported."
        case .payloadTooLarge: return "The capture link text is too large."
        }
    }
}

public struct CaptureDeepLinkParser: Sendable {
    public static let maximumTextLength = CaptureInputLimits.maximumTextCharacters
    private static let allowedComposerParameters: Set<String> = ["text", "url", "destination", "vox", "action", "source"]

    public init() {}

    public func parse(_ url: URL) throws -> CaptureDeepLinkAction {
        guard url.scheme?.lowercased() == "voxboard" else {
            throw CaptureDeepLinkError.invalidScheme
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []

        switch url.host?.lowercased() {
        case "capture":
            try validateParameters(items, allowed: Self.allowedComposerParameters)
            let text = value(named: "text", in: items)
            if let text, text.count > Self.maximumTextLength {
                throw CaptureDeepLinkError.payloadTooLarge
            }

            let capturedURL: URL?
            if let rawURL = value(named: "url", in: items) {
                guard let parsed = URL(string: rawURL),
                      let scheme = parsed.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else {
                    throw CaptureDeepLinkError.invalidURL
                }
                capturedURL = parsed
            } else {
                capturedURL = nil
            }

            let destinationID: UUID?
            if let rawDestination = value(named: "destination", in: items) {
                guard let parsed = UUID(uuidString: rawDestination) else {
                    throw CaptureDeepLinkError.invalidDestination
                }
                destinationID = parsed
            } else {
                destinationID = nil
            }
            let voxID: String?
            if let rawVox = value(named: "vox", in: items) {
                let trimmed = rawVox.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.count <= 160 else {
                    throw CaptureDeepLinkError.invalidVox
                }
                voxID = trimmed
            } else {
                voxID = nil
            }
            let requestedInput: CaptureRequestedInput?
            if let rawAction = value(named: "action", in: items) {
                guard let input = CaptureRequestedInput(rawValue: rawAction) else {
                    throw CaptureDeepLinkError.invalidAction
                }
                requestedInput = input
            } else {
                requestedInput = nil
            }
            let source: CaptureSource?
            if let rawSource = value(named: "source", in: items) {
                guard rawSource == CaptureSource.widget.rawValue else {
                    throw CaptureDeepLinkError.invalidSource
                }
                source = .widget
            } else {
                source = nil
            }
            return .openComposer(
                CaptureDeepLinkDraft(
                    text: text,
                    url: capturedURL,
                    destinationID: destinationID,
                    voxID: voxID,
                    requestedInput: requestedInput,
                    source: source
                )
            )

        case "capture-request":
            try validateParameters(items, allowed: ["id"])
            guard let rawID = value(named: "id", in: items),
                  let id = UUID(uuidString: rawID) else {
                throw CaptureDeepLinkError.invalidRequestID
            }
            return .processInboxRequest(id)

        default:
            throw CaptureDeepLinkError.unknownAction(url.host ?? "")
        }
    }

    private func validateParameters(_ items: [URLQueryItem], allowed: Set<String>) throws {
        var seen: Set<String> = []
        for item in items {
            guard allowed.contains(item.name) else {
                throw CaptureDeepLinkError.forbiddenParameter(item.name)
            }
            guard seen.insert(item.name).inserted else {
                throw CaptureDeepLinkError.duplicateParameter(item.name)
            }
        }
    }

    private func value(named name: String, in items: [URLQueryItem]) -> String? {
        items.first(where: { $0.name == name })?.value
    }
}
