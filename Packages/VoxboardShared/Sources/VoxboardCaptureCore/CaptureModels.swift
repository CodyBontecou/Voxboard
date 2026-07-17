import Foundation

public enum CaptureModelError: Error, Equatable, LocalizedError, Sendable {
    case invalidRelativePath(String)
    case invalidOriginalFilename(String)
    case unsupportedSchemaVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidRelativePath(let path):
            return "The capture asset path is not a safe relative path: \(path)"
        case .invalidOriginalFilename(let filename):
            return "The capture asset filename is invalid: \(filename)"
        case .unsupportedSchemaVersion(let version):
            return "Capture library schema version \(version) is not supported."
        }
    }
}

public enum CapturePathValidation {
    public static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw CaptureModelError.invalidRelativePath(path)
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CaptureModelError.invalidRelativePath(path)
        }
    }

    /// Resolves both the authorized root and every existing symlink component
    /// before accepting a child path. The lexical check blocks traversal while
    /// the resolved check blocks a symlink inside the root from redirecting I/O.
    public static func containedFileURL(relativePath: String, rootURL: URL) throws -> URL {
        try validateRelativePath(relativePath)
        let lexicalRoot = rootURL.standardizedFileURL
        let lexicalCandidate = lexicalRoot
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
        guard isChild(lexicalCandidate, of: lexicalRoot) else {
            throw CaptureModelError.invalidRelativePath(relativePath)
        }

        let resolvedRoot = resolvedURLIncludingExistingAncestors(lexicalRoot)
        let resolvedCandidate = resolvedURLIncludingExistingAncestors(lexicalCandidate)
        guard isChild(resolvedCandidate, of: resolvedRoot) else {
            throw CaptureModelError.invalidRelativePath(relativePath)
        }
        return lexicalCandidate
    }

    public static func validateFilename(_ filename: String) throws {
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              !filename.contains("/"),
              !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw CaptureModelError.invalidOriginalFilename(filename)
        }
    }

    private static func isChild(_ candidate: URL, of root: URL) -> Bool {
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path.hasPrefix(rootPrefix)
    }

    private static func resolvedURLIncludingExistingAncestors(_ url: URL) -> URL {
        var existingAncestor = url
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: existingAncestor.path),
              existingAncestor.path != "/" {
            missingComponents.append(existingAncestor.lastPathComponent)
            existingAncestor.deleteLastPathComponent()
        }
        var resolved = existingAncestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }
}

public struct CaptureAssetReference: Codable, Equatable, Sendable {
    public var relativePath: String
    public var originalFilename: String
    public var contentTypeIdentifier: String
    public var byteCount: Int64?

    public init(
        relativePath: String,
        originalFilename: String,
        contentTypeIdentifier: String,
        byteCount: Int64? = nil
    ) throws {
        try CapturePathValidation.validateRelativePath(relativePath)
        try CapturePathValidation.validateFilename(originalFilename)
        self.relativePath = relativePath
        self.originalFilename = originalFilename
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteCount = byteCount
    }

    private enum CodingKeys: String, CodingKey {
        case relativePath
        case originalFilename
        case contentTypeIdentifier
        case byteCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            relativePath: container.decode(String.self, forKey: .relativePath),
            originalFilename: container.decode(String.self, forKey: .originalFilename),
            contentTypeIdentifier: container.decode(String.self, forKey: .contentTypeIdentifier),
            byteCount: container.decodeIfPresent(Int64.self, forKey: .byteCount)
        )
    }
}

public enum CaptureAudioEmbedPlacement: String, Codable, Sendable {
    case none
    case top
    case bottom
}

public enum CapturePayload: Equatable, Sendable {
    case text(String)
    case url(URL, title: String?)
    case audio(CaptureAssetReference, transcript: String?)
    case retainedAudio(CaptureAssetReference, embedPlacement: CaptureAudioEmbedPlacement)
    case image(CaptureAssetReference, altText: String?)
    case file(CaptureAssetReference)
    case scannedDocument(pages: [CaptureAssetReference], pdf: CaptureAssetReference?, extractedText: String?)
    case sketch(drawing: CaptureAssetReference, preview: CaptureAssetReference, altText: String?)
}

extension CapturePayload: Codable {
    private enum Kind: String, Codable {
        case text
        case url
        case audio
        case retainedAudio
        case image
        case file
        case scannedDocument
        case sketch
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case url
        case title
        case asset
        case transcript
        case embedPlacement
        case altText
        case pages
        case pdf
        case drawing
        case preview
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .url:
            self = .url(
                try container.decode(URL.self, forKey: .url),
                title: try container.decodeIfPresent(String.self, forKey: .title)
            )
        case .audio:
            self = .audio(
                try container.decode(CaptureAssetReference.self, forKey: .asset),
                transcript: try container.decodeIfPresent(String.self, forKey: .transcript)
            )
        case .retainedAudio:
            self = .retainedAudio(
                try container.decode(CaptureAssetReference.self, forKey: .asset),
                embedPlacement: try container.decodeIfPresent(
                    CaptureAudioEmbedPlacement.self,
                    forKey: .embedPlacement
                ) ?? .none
            )
        case .image:
            self = .image(
                try container.decode(CaptureAssetReference.self, forKey: .asset),
                altText: try container.decodeIfPresent(String.self, forKey: .altText)
            )
        case .file:
            self = .file(try container.decode(CaptureAssetReference.self, forKey: .asset))
        case .scannedDocument:
            self = .scannedDocument(
                pages: try container.decode([CaptureAssetReference].self, forKey: .pages),
                pdf: try container.decodeIfPresent(CaptureAssetReference.self, forKey: .pdf),
                extractedText: try container.decodeIfPresent(String.self, forKey: .text)
            )
        case .sketch:
            self = .sketch(
                drawing: try container.decode(CaptureAssetReference.self, forKey: .drawing),
                preview: try container.decode(CaptureAssetReference.self, forKey: .preview),
                altText: try container.decodeIfPresent(String.self, forKey: .altText)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(text, forKey: .text)
        case .url(let url, let title):
            try container.encode(Kind.url, forKey: .kind)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(title, forKey: .title)
        case .audio(let asset, let transcript):
            try container.encode(Kind.audio, forKey: .kind)
            try container.encode(asset, forKey: .asset)
            try container.encodeIfPresent(transcript, forKey: .transcript)
        case .retainedAudio(let asset, let embedPlacement):
            try container.encode(Kind.retainedAudio, forKey: .kind)
            try container.encode(asset, forKey: .asset)
            try container.encode(embedPlacement, forKey: .embedPlacement)
        case .image(let asset, let altText):
            try container.encode(Kind.image, forKey: .kind)
            try container.encode(asset, forKey: .asset)
            try container.encodeIfPresent(altText, forKey: .altText)
        case .file(let asset):
            try container.encode(Kind.file, forKey: .kind)
            try container.encode(asset, forKey: .asset)
        case .scannedDocument(let pages, let pdf, let extractedText):
            try container.encode(Kind.scannedDocument, forKey: .kind)
            try container.encode(pages, forKey: .pages)
            try container.encodeIfPresent(pdf, forKey: .pdf)
            try container.encodeIfPresent(extractedText, forKey: .text)
        case .sketch(let drawing, let preview, let altText):
            try container.encode(Kind.sketch, forKey: .kind)
            try container.encode(drawing, forKey: .drawing)
            try container.encode(preview, forKey: .preview)
            try container.encodeIfPresent(altText, forKey: .altText)
        }
    }
}

public enum CaptureSource: String, Codable, CaseIterable, Sendable {
    case app
    case keyboard
    case widget
    case shortcut
    case shareExtension
    case watch
    case mac
    case deepLink
    case fileImport
    case voice
}

public struct CaptureRequest: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var source: CaptureSource
    public var destinationID: UUID
    public var payloads: [CapturePayload]
    /// A request-scoped attachment route used by deferred voice delivery.
    /// `nil` keeps the destination default; an empty string means alongside
    /// the Markdown note.
    public var attachmentsFolderNameOverride: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        source: CaptureSource,
        destinationID: UUID,
        payloads: [CapturePayload],
        attachmentsFolderNameOverride: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.destinationID = destinationID
        self.payloads = payloads
        self.attachmentsFolderNameOverride = attachmentsFolderNameOverride
    }
}

public enum CaptureRollingPeriod: String, Codable, CaseIterable, Sendable {
    case daily
    case weekly
    case monthly
    case quarterly
    case yearly
}

public struct CaptureHeadingSelector: Codable, Equatable, Sendable {
    public var title: String
    public var level: Int?

    public init(title: String, level: Int? = nil) {
        self.title = title
        self.level = level
    }
}

public enum CaptureMissingHeadingBehavior: String, Codable, Sendable {
    case fail
    case create
}

public enum CapturePlacement: Equatable, Sendable {
    case append
    case prepend
    case beneathHeading(CaptureHeadingSelector, missingHeadingBehavior: CaptureMissingHeadingBehavior)
}

extension CapturePlacement: Codable {
    private enum Kind: String, Codable {
        case append
        case prepend
        case beneathHeading
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case selector
        case missingHeadingBehavior
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .append:
            self = .append
        case .prepend:
            self = .prepend
        case .beneathHeading:
            self = .beneathHeading(
                try container.decode(CaptureHeadingSelector.self, forKey: .selector),
                missingHeadingBehavior: try container.decodeIfPresent(
                    CaptureMissingHeadingBehavior.self,
                    forKey: .missingHeadingBehavior
                ) ?? .fail
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .append:
            try container.encode(Kind.append, forKey: .kind)
        case .prepend:
            try container.encode(Kind.prepend, forKey: .kind)
        case .beneathHeading(let selector, let behavior):
            try container.encode(Kind.beneathHeading, forKey: .kind)
            try container.encode(selector, forKey: .selector)
            try container.encode(behavior, forKey: .missingHeadingBehavior)
        }
    }
}

public enum CaptureNoteTarget: Equatable, Sendable {
    case newNote(pathTemplate: String)
    case rollingNote(pathTemplate: String, period: CaptureRollingPeriod)
    case existingNote(relativePath: String)
}

extension CaptureNoteTarget: Codable {
    private enum Kind: String, Codable {
        case newNote
        case rollingNote
        case existingNote
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case pathTemplate
        case period
        case relativePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .newNote:
            self = .newNote(pathTemplate: try container.decode(String.self, forKey: .pathTemplate))
        case .rollingNote:
            self = .rollingNote(
                pathTemplate: try container.decode(String.self, forKey: .pathTemplate),
                period: try container.decode(CaptureRollingPeriod.self, forKey: .period)
            )
        case .existingNote:
            let path = try container.decode(String.self, forKey: .relativePath)
            try CapturePathValidation.validateRelativePath(path)
            self = .existingNote(relativePath: path)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .newNote(let pathTemplate):
            try container.encode(Kind.newNote, forKey: .kind)
            try container.encode(pathTemplate, forKey: .pathTemplate)
        case .rollingNote(let pathTemplate, let period):
            try container.encode(Kind.rollingNote, forKey: .kind)
            try container.encode(pathTemplate, forKey: .pathTemplate)
            try container.encode(period, forKey: .period)
        case .existingNote(let relativePath):
            try CapturePathValidation.validateRelativePath(relativePath)
            try container.encode(Kind.existingNote, forKey: .kind)
            try container.encode(relativePath, forKey: .relativePath)
        }
    }
}

public struct CaptureDestination: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var rootBookmark: Data
    public var rootName: String
    public var noteTarget: CaptureNoteTarget
    public var placement: CapturePlacement
    public var entryPrefix: String
    public var entrySuffix: String
    /// Optional live binding to a reusable library template. Prefix/suffix are
    /// retained as a safe snapshot if the template is later removed.
    public var entryTemplateID: UUID?
    public var attachmentsFolderName: String

    public init(
        id: UUID = UUID(),
        name: String,
        rootBookmark: Data,
        rootName: String,
        noteTarget: CaptureNoteTarget,
        placement: CapturePlacement = .append,
        entryPrefix: String = "",
        entrySuffix: String = "",
        entryTemplateID: UUID? = nil,
        attachmentsFolderName: String = "attachments"
    ) {
        self.id = id
        self.name = name
        self.rootBookmark = rootBookmark
        self.rootName = rootName
        self.noteTarget = noteTarget
        self.placement = placement
        self.entryPrefix = entryPrefix
        self.entrySuffix = entrySuffix
        self.entryTemplateID = entryTemplateID
        self.attachmentsFolderName = attachmentsFolderName
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case rootBookmark
        case rootName
        case noteTarget
        case placement
        case entryPrefix
        case entrySuffix
        case entryTemplateID
        case attachmentsFolderName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            rootBookmark: try container.decode(Data.self, forKey: .rootBookmark),
            rootName: try container.decode(String.self, forKey: .rootName),
            noteTarget: try container.decode(CaptureNoteTarget.self, forKey: .noteTarget),
            placement: try container.decodeIfPresent(CapturePlacement.self, forKey: .placement) ?? .append,
            entryPrefix: try container.decodeIfPresent(String.self, forKey: .entryPrefix) ?? "",
            entrySuffix: try container.decodeIfPresent(String.self, forKey: .entrySuffix) ?? "",
            entryTemplateID: try container.decodeIfPresent(UUID.self, forKey: .entryTemplateID),
            attachmentsFolderName: try container.decodeIfPresent(String.self, forKey: .attachmentsFolderName) ?? "attachments"
        )
    }
}

public struct CaptureEntryTemplate: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var entryPrefix: String
    public var entrySuffix: String

    public init(
        id: UUID = UUID(),
        name: String,
        entryPrefix: String = "",
        entrySuffix: String = ""
    ) {
        self.id = id
        self.name = name
        self.entryPrefix = entryPrefix
        self.entrySuffix = entrySuffix
    }
}

public struct CaptureFlowBinding: Codable, Equatable, Sendable {
    public var recordingFlowID: String
    public var destinationID: UUID

    public init(recordingFlowID: String, destinationID: UUID) {
        self.recordingFlowID = recordingFlowID
        self.destinationID = destinationID
    }
}

public struct CaptureLibraryEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var destinations: [CaptureDestination]
    public var defaultDestinationID: UUID?
    public var flowBindings: [String: UUID]
    public var entryTemplates: [CaptureEntryTemplate]

    public init(
        schemaVersion: Int = CaptureLibraryEnvelope.currentSchemaVersion,
        destinations: [CaptureDestination] = [],
        defaultDestinationID: UUID? = nil,
        flowBindings: [String: UUID] = [:]
    ) {
        self.init(
            schemaVersion: schemaVersion,
            destinations: destinations,
            defaultDestinationID: defaultDestinationID,
            flowBindings: flowBindings,
            entryTemplates: []
        )
    }

    public init(
        schemaVersion: Int = CaptureLibraryEnvelope.currentSchemaVersion,
        destinations: [CaptureDestination] = [],
        defaultDestinationID: UUID? = nil,
        flowBindings: [String: UUID] = [:],
        entryTemplates: [CaptureEntryTemplate]
    ) {
        self.schemaVersion = schemaVersion
        self.destinations = destinations
        self.defaultDestinationID = defaultDestinationID
        self.flowBindings = flowBindings
        self.entryTemplates = entryTemplates
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case destinations
        case defaultDestinationID
        case flowBindings
        case entryTemplates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        destinations = try container.decodeIfPresent([CaptureDestination].self, forKey: .destinations) ?? []
        defaultDestinationID = try container.decodeIfPresent(UUID.self, forKey: .defaultDestinationID)
        flowBindings = try container.decodeIfPresent([String: UUID].self, forKey: .flowBindings) ?? [:]
        entryTemplates = try container.decodeIfPresent(
            [CaptureEntryTemplate].self,
            forKey: .entryTemplates
        ) ?? []
    }

    /// Resolves a reusable template at delivery time so edits apply to every
    /// bound destination, including voice and deferred inbox requests.
    public func resolvedDestination(
        _ destination: CaptureDestination,
        overrideEntryTemplateID: UUID? = nil
    ) -> CaptureDestination {
        guard let templateID = overrideEntryTemplateID ?? destination.entryTemplateID,
              let template = entryTemplates.first(where: { $0.id == templateID }) else {
            return destination
        }
        var resolved = destination
        resolved.entryTemplateID = templateID
        resolved.entryPrefix = template.entryPrefix
        resolved.entrySuffix = template.entrySuffix
        return resolved
    }

    public static func decodeValidated(
        from data: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> CaptureLibraryEnvelope {
        let envelope = try decoder.decode(CaptureLibraryEnvelope.self, from: data)
        guard envelope.schemaVersion == currentSchemaVersion else {
            throw CaptureModelError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        return envelope
    }
}
