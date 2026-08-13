import CryptoKit
import Foundation
import VoxboardCaptureCore

struct Corpus: Codable {
    let corpusVersion: Int
    let producer: Producer
    let cases: [Case]
}

struct Producer: Codable {
    let name: String
    let sourceRevision: String
    let oracleSourceSHA256: String
    let productionConsumers: [Consumer]
    let swiftCompilerIdentity: String
    let xcodeIdentity: String
    let toolchainManifestSHA256: String
}

struct Consumer: Codable {
    let name: String
    let path: String
    let sha256: String
}

struct Case: Codable {
    let id: String
    let request: OracleRequest
    let expected: Expected?
    let expectedError: String?
}

struct OracleRequest: Codable {
    let requestID: String
    let createdAtEpochMilliseconds: Int64
    let timezone: String
    let source: String
    let payloads: [OraclePayload]
    let logicalFolder: [String]
    let noteNameTemplate: String
    let occupiedPaths: [[String]]
    let entryPrefix: String
    let entrySuffix: String
    let frontmatter: [Field]
    let retryMarker: Bool
    let finalNewline: Bool
}

struct OraclePayload: Codable {
    let kind: String
    let text: String?
    let url: String?
    let label: String?
}

struct Field: Codable {
    let name: String
    let value: String
}

struct Expected: Codable {
    let logicalPath: [String]
    let bytesBase64: String
    let sha256: String
}

struct Seed {
    let id: String
    let request: OracleRequest
    let expectedError: String?
}

func requiredEnvironment(_ name: String) -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        fatalError("Missing required oracle provenance environment")
    }
    return value
}

let fixedID = "11111111-1111-4111-8111-111111111111"
let base = OracleRequest(
    requestID: fixedID,
    createdAtEpochMilliseconds: 1_700_000_000_000,
    timezone: "America/Los_Angeles",
    source: "app",
    payloads: [
        .init(kind: "text", text: "First", url: nil, label: nil),
        .init(kind: "link", text: nil, url: "https://example.invalid/a(b)", label: "A [label] \\ value"),
        .init(kind: "text", text: "Cafe\u{301} 👩🏽‍💻", url: nil, label: nil),
    ],
    logicalFolder: ["Inbox", "Unicode"],
    noteNameTemplate: "{date}-{time}-{id8}",
    occupiedPaths: [],
    entryPrefix: "## {source} {week}\n",
    entrySuffix: "",
    // This order is the order emitted by the production dictionary-based Apple
    // adapter. The portable ordered-fields contract preserves these normalized facts.
    frontmatter: [.init(name: "count", value: "7"), .init(name: "source", value: "synthetic")],
    retryMarker: true,
    finalNewline: true
)

let seeds: [Seed] = [
    .init(id: "m2-positive-unicode-template-frontmatter", request: base, expectedError: nil),
    .init(
        id: "m2-positive-collision-link-no-final-lf",
        request: .init(
            requestID: fixedID,
            createdAtEpochMilliseconds: 1_704_067_200_000,
            timezone: "Asia/Kathmandu",
            source: "share",
            payloads: [.init(kind: "link", text: nil, url: "https://example.invalid/é", label: "")],
            logicalFolder: ["Inbox"],
            noteNameTemplate: "capture.md",
            occupiedPaths: [["Inbox", "capture.md"], ["Inbox", "capture-2.md"]],
            entryPrefix: "",
            entrySuffix: "",
            frontmatter: [],
            retryMarker: false,
            finalNewline: false
        ),
        expectedError: nil
    ),
    .init(
        id: "m2-positive-template-frontmatter-literal-token",
        request: .init(
            requestID: fixedID,
            createdAtEpochMilliseconds: 1_700_000_000_000,
            timezone: "UTC",
            source: "app",
            payloads: [.init(kind: "text", text: "{date} remains literal", url: nil, label: nil)],
            logicalFolder: ["Inbox"],
            noteNameTemplate: "note.txt",
            occupiedPaths: [],
            entryPrefix: "---\ntemplate: true\n---\n",
            entrySuffix: "",
            frontmatter: [],
            retryMarker: false,
            finalNewline: true
        ),
        expectedError: nil
    ),
    .init(
        id: "m2-positive-crlf-cr-boundaries",
        request: .init(
            requestID: fixedID,
            createdAtEpochMilliseconds: 0,
            timezone: "UTC",
            source: "keyboard",
            payloads: [.init(kind: "text", text: "\r\nAlpha\rBeta\r\n", url: nil, label: nil)],
            logicalFolder: ["Inbox"],
            noteNameTemplate: "line-endings",
            occupiedPaths: [],
            entryPrefix: "Prefix\r\n",
            entrySuffix: "",
            frontmatter: [],
            retryMarker: false,
            finalNewline: true
        ),
        expectedError: nil
    ),
    .init(
        id: "m2-positive-ordered-frontmatter",
        request: .init(
            requestID: fixedID,
            createdAtEpochMilliseconds: 4_102_444_800_000,
            timezone: "Pacific/Kiritimati",
            source: "widget",
            payloads: [.init(kind: "text", text: "ordered", url: nil, label: nil)],
            logicalFolder: ["Inbox"],
            noteNameTemplate: "{year}-{id8}",
            occupiedPaths: [],
            entryPrefix: "",
            entrySuffix: "",
            frontmatter: [.init(name: "alpha", value: "one"), .init(name: "zeta", value: "two")],
            retryMarker: false,
            finalNewline: false
        ),
        expectedError: nil
    ),
    .init(
        id: "m2-positive-occupancy-order-a",
        request: .init(
            requestID: fixedID,
            createdAtEpochMilliseconds: 1_700_000_000_000,
            timezone: "UTC",
            source: "app",
            payloads: [.init(kind: "text", text: "stable", url: nil, label: nil)],
            logicalFolder: ["Inbox"],
            noteNameTemplate: "stable",
            occupiedPaths: [["Inbox", "stable-2.md"], ["Inbox", "stable.md"]],
            entryPrefix: "",
            entrySuffix: "",
            frontmatter: [],
            retryMarker: false,
            finalNewline: false
        ),
        expectedError: nil
    ),
    .init(
        id: "m2-positive-occupancy-order-b",
        request: .init(
            requestID: fixedID,
            createdAtEpochMilliseconds: 1_700_000_000_000,
            timezone: "UTC",
            source: "app",
            payloads: [.init(kind: "text", text: "stable", url: nil, label: nil)],
            logicalFolder: ["Inbox"],
            noteNameTemplate: "stable",
            occupiedPaths: [["Inbox", "stable.md"], ["Inbox", "stable-2.md"]],
            entryPrefix: "",
            entrySuffix: "",
            frontmatter: [],
            retryMarker: false,
            finalNewline: false
        ),
        expectedError: nil
    ),
    .init(id: "m2-negative-parent-traversal", request: .init(requestID: fixedID, createdAtEpochMilliseconds: 1_700_000_000_000, timezone: "UTC", source: "app", payloads: [.init(kind: "text", text: "x", url: nil, label: nil)], logicalFolder: [".."], noteNameTemplate: "escape", occupiedPaths: [], entryPrefix: "", entrySuffix: "", frontmatter: [], retryMarker: false, finalNewline: false), expectedError: "invalidPath"),
    .init(id: "m2-negative-current-segment", request: .init(requestID: fixedID, createdAtEpochMilliseconds: 1_700_000_000_000, timezone: "UTC", source: "app", payloads: [.init(kind: "text", text: "x", url: nil, label: nil)], logicalFolder: ["."], noteNameTemplate: "escape", occupiedPaths: [], entryPrefix: "", entrySuffix: "", frontmatter: [], retryMarker: false, finalNewline: false), expectedError: "invalidPath"),
    .init(id: "m2-negative-backslash", request: .init(requestID: fixedID, createdAtEpochMilliseconds: 1_700_000_000_000, timezone: "UTC", source: "app", payloads: [.init(kind: "text", text: "x", url: nil, label: nil)], logicalFolder: ["bad\\segment"], noteNameTemplate: "escape", occupiedPaths: [], entryPrefix: "", entrySuffix: "", frontmatter: [], retryMarker: false, finalNewline: false), expectedError: "invalidPath"),
    .init(id: "m2-negative-absolute-path", request: .init(requestID: fixedID, createdAtEpochMilliseconds: 1_700_000_000_000, timezone: "UTC", source: "app", payloads: [.init(kind: "text", text: "x", url: nil, label: nil)], logicalFolder: [], noteNameTemplate: "/escape", occupiedPaths: [], entryPrefix: "", entrySuffix: "", frontmatter: [], retryMarker: false, finalNewline: false), expectedError: "invalidPath"),
    .init(id: "m2-negative-unsafe-url", request: .init(requestID: fixedID, createdAtEpochMilliseconds: 1_700_000_000_000, timezone: "UTC", source: "app", payloads: [.init(kind: "link", text: nil, url: "ftp://example.invalid/private", label: "x")], logicalFolder: ["Inbox"], noteNameTemplate: "link", occupiedPaths: [], entryPrefix: "", entrySuffix: "", frontmatter: [], retryMarker: false, finalNewline: false), expectedError: "invalidRendering"),
]

func makeRequest(_ value: OracleRequest) throws -> (CaptureRequest, CaptureDestination, Calendar) {
    guard let requestID = UUID(uuidString: value.requestID),
          let timezone = TimeZone(identifier: value.timezone) else {
        throw NSError(domain: "oracle", code: 1)
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone
    calendar.locale = Locale(identifier: "en_US_POSIX")
    let payloads: [CapturePayload] = try value.payloads.map { item in
        switch item.kind {
        case "text": return .text(item.text ?? "")
        case "link":
            guard let url = URL(string: item.url ?? "") else { throw NSError(domain: "oracle", code: 2) }
            return .url(url, title: item.label)
        default: throw NSError(domain: "oracle", code: 3)
        }
    }
    let destinationID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let source = value.source == "share" ? CaptureSource.shareExtension : CaptureSource(rawValue: value.source)!
    let request = CaptureRequest(
        id: requestID,
        createdAt: Date(timeIntervalSince1970: Double(value.createdAtEpochMilliseconds) / 1_000),
        source: source,
        destinationID: destinationID,
        payloads: payloads,
        frontmatter: Dictionary(uniqueKeysWithValues: value.frontmatter.map { ($0.name, $0.value) })
    )
    let pathTemplate = (value.logicalFolder + [value.noteNameTemplate]).joined(separator: "/")
    let destination = CaptureDestination(
        id: destinationID,
        name: "M2 Oracle",
        rootBookmark: Data(),
        rootName: "Synthetic",
        noteTarget: .newNote(pathTemplate: pathTemplate),
        entryPrefix: value.entryPrefix,
        entrySuffix: value.entrySuffix,
        retryProtectionEnabled: value.retryMarker
    )
    return (request, destination, calendar)
}

func produce(_ value: OracleRequest) throws -> Expected {
    let (request, destination, calendar) = try makeRequest(value)
    let occupied = Set(value.occupiedPaths.map { $0.joined(separator: "/") })
    let path = try CapturePathPlanner(calendar: calendar).relativePath(
        for: request,
        destination: destination,
        existingRelativePaths: occupied
    )
    let entry = try CaptureMarkdownRenderer().render(request, for: destination)
    let template = CaptureEntryTemplateRenderer(calendar: calendar)
    let mutation = MarkdownCaptureMutation(
        requestID: request.id,
        entry: entry,
        placement: .append,
        entryPrefix: template.render(destination.entryPrefix, for: request),
        entrySuffix: template.render(destination.entrySuffix, for: request),
        frontmatter: request.frontmatter,
        retryProtectionEnabled: value.retryMarker
    )
    var document = try MarkdownDocumentEditor().applying(mutation, to: "")
    if value.finalNewline && !document.hasSuffix("\n") { document.append("\n") }
    let bytes = Data(document.utf8)
    return Expected(
        logicalPath: path.split(separator: "/", omittingEmptySubsequences: false).map(String.init),
        bytesBase64: bytes.base64EncodedString(),
        sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    )
}

func errorCode(_ error: Error) -> String {
    switch error {
    case CaptureModelError.invalidRelativePath: return "invalidPath"
    case CaptureRenderingError.unsafeURL: return "invalidRendering"
    default: return "oracleProductionFailure"
    }
}

let cases = seeds.map { seed -> Case in
    do {
        let expected = try produce(seed.request)
        guard seed.expectedError == nil else {
            fatalError("A negative oracle case unexpectedly succeeded")
        }
        return Case(id: seed.id, request: seed.request, expected: expected, expectedError: nil)
    } catch {
        let actual = errorCode(error)
        guard seed.expectedError == actual else {
            fatalError("Oracle failure classification did not match the declared synthetic case")
        }
        return Case(id: seed.id, request: seed.request, expected: nil, expectedError: actual)
    }
}

let consumerNames = [
    ("CapturePathPlanner", "Packages/VoxboardShared/Sources/VoxboardCaptureCore/CapturePathPlanner.swift", "VOX_M2_CAPTURE_PATH_PLANNER_SHA256"),
    ("CaptureMarkdownRenderer", "Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureMarkdownRenderer.swift", "VOX_M2_CAPTURE_MARKDOWN_RENDERER_SHA256"),
    ("CaptureEntryTemplateRenderer", "Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureEntryTemplateRenderer.swift", "VOX_M2_CAPTURE_ENTRY_TEMPLATE_RENDERER_SHA256"),
    ("MarkdownDocumentEditor", "Packages/VoxboardShared/Sources/VoxboardCaptureCore/MarkdownDocumentEditor.swift", "VOX_M2_MARKDOWN_DOCUMENT_EDITOR_SHA256"),
]
let consumers = consumerNames.map { Consumer(name: $0.0, path: $0.1, sha256: requiredEnvironment($0.2)) }
let corpus = Corpus(
    corpusVersion: 1,
    producer: .init(
        name: "VoxboardM2Oracle",
        sourceRevision: requiredEnvironment("VOX_M2_SOURCE_REVISION"),
        oracleSourceSHA256: requiredEnvironment("VOX_M2_ORACLE_SOURCE_SHA256"),
        productionConsumers: consumers,
        swiftCompilerIdentity: requiredEnvironment("VOX_M2_SWIFT_COMPILER_IDENTITY"),
        xcodeIdentity: requiredEnvironment("VOX_M2_XCODE_IDENTITY"),
        toolchainManifestSHA256: requiredEnvironment("VOX_M2_TOOLCHAIN_MANIFEST_SHA256")
    ),
    cases: cases
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(corpus))
FileHandle.standardOutput.write(Data([0x0a]))
