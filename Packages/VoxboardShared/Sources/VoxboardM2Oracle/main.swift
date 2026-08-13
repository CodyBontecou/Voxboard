import CryptoKit
import Foundation
import VoxboardCaptureCore

struct Corpus: Codable {
    let corpusVersion: Int
    let producer: Producer
    let cases: [Case]
}
struct Producer: Codable { let name: String; let productionConsumers: [String]; let sourceSHA256: String }
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
struct OraclePayload: Codable { let kind: String; let text: String?; let url: String?; let label: String? }
struct Field: Codable { let name: String; let value: String }
struct Expected: Codable { let logicalPath: [String]; let bytesBase64: String; let sha256: String }

let sourceSHA256 = ProcessInfo.processInfo.environment["VOX_M2_ORACLE_SOURCE_SHA256"] ?? String(repeating: "0", count: 64)
let fixedID = "11111111-1111-4111-8111-111111111111"
let requests = [
    OracleRequest(requestID: fixedID, createdAtEpochMilliseconds: 1_700_000_000_000, timezone: "America/Los_Angeles", source: "app", payloads: [.init(kind:"text",text:"First",url:nil,label:nil),.init(kind:"link",text:nil,url:"https://example.invalid/a(b)",label:"A [label] \\ value"),.init(kind:"text",text:"Cafe\u{301} 👩🏽‍💻",url:nil,label:nil)], logicalFolder:["Inbox","Unicode"], noteNameTemplate:"{date}-{time}-{id8}", occupiedPaths:[], entryPrefix:"## {source} {week}\n", entrySuffix:"", frontmatter:[.init(name:"source",value:"synthetic"),.init(name:"count",value:"7")], retryMarker:true, finalNewline:true),
    OracleRequest(requestID: fixedID, createdAtEpochMilliseconds: 1_704_067_200_000, timezone: "Asia/Kathmandu", source: "share", payloads: [.init(kind:"link",text:nil,url:"https://example.invalid/é",label:"")], logicalFolder:["Inbox"], noteNameTemplate:"capture.md", occupiedPaths:[["Inbox","capture.md"],["Inbox","capture-2.md"]], entryPrefix:"", entrySuffix:"", frontmatter:[], retryMarker:false, finalNewline:false),
    OracleRequest(requestID: fixedID, createdAtEpochMilliseconds: 1_700_000_000_000, timezone: "UTC", source: "app", payloads: [.init(kind:"text",text:"{date} remains literal",url:nil,label:nil)], logicalFolder:["Inbox"], noteNameTemplate:"note.txt", occupiedPaths:[], entryPrefix:"---\ntemplate: true\n---\n", entrySuffix:"", frontmatter:[], retryMarker:false, finalNewline:true),
]

func makeRequest(_ value: OracleRequest) throws -> (CaptureRequest, CaptureDestination, Calendar) {
    guard let requestID = UUID(uuidString: value.requestID), let timezone = TimeZone(identifier: value.timezone) else { throw NSError(domain:"oracle",code:1) }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone; calendar.locale = Locale(identifier: "en_US_POSIX")
    let payloads: [CapturePayload] = try value.payloads.map { item in
        switch item.kind {
        case "text": return .text(item.text ?? "")
        case "link": guard let url = URL(string:item.url ?? "") else { throw NSError(domain:"oracle",code:2) }; return .url(url,title:item.label)
        default: throw NSError(domain:"oracle",code:3)
        }
    }
    let destinationID = UUID(uuidString:"22222222-2222-4222-8222-222222222222")!
    let source = value.source == "share" ? CaptureSource.shareExtension : CaptureSource(rawValue:value.source)!
    let request = CaptureRequest(id:requestID,createdAt:Date(timeIntervalSince1970:Double(value.createdAtEpochMilliseconds)/1000),source:source,destinationID:destinationID,payloads:payloads,frontmatter:Dictionary(uniqueKeysWithValues:value.frontmatter.map{($0.name,$0.value)}))
    let pathTemplate = (value.logicalFolder + [value.noteNameTemplate]).joined(separator:"/")
    let destination = CaptureDestination(id:destinationID,name:"M2 Oracle",rootBookmark:Data(),rootName:"Synthetic",noteTarget:.newNote(pathTemplate:pathTemplate),entryPrefix:value.entryPrefix,entrySuffix:value.entrySuffix,retryProtectionEnabled:value.retryMarker)
    return (request,destination,calendar)
}

func produce(_ value: OracleRequest) throws -> Expected {
    let (request,destination,calendar) = try makeRequest(value)
    let occupied = Set(value.occupiedPaths.map{$0.joined(separator:"/")})
    let path = try CapturePathPlanner(calendar:calendar).relativePath(for:request,destination:destination,existingRelativePaths:occupied)
    let entry = try CaptureMarkdownRenderer().render(request,for:destination)
    let template = CaptureEntryTemplateRenderer(calendar:calendar)
    let mutation = MarkdownCaptureMutation(requestID:request.id,entry:entry,placement:.append,entryPrefix:template.render(destination.entryPrefix,for:request),entrySuffix:template.render(destination.entrySuffix,for:request),frontmatter:request.frontmatter,retryProtectionEnabled:value.retryMarker)
    var document = try MarkdownDocumentEditor().applying(mutation,to:"")
    if value.finalNewline && !document.hasSuffix("\n") { document.append("\n") }
    let bytes = Data(document.utf8)
    return Expected(logicalPath:path.split(separator:"/",omittingEmptySubsequences:false).map(String.init),bytesBase64:bytes.base64EncodedString(),sha256:SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined())
}

let cases = requests.enumerated().map { index, request -> Case in
    do { return Case(id:"m2-positive-\(index+1)",request:request,expected:try produce(request),expectedError:nil) }
    catch { return Case(id:"m2-positive-\(index+1)",request:request,expected:nil,expectedError:"oracleProductionFailure") }
} + [Case(id:"m2-negative-unsupported-random-uuid",request:requests[0],expected:nil,expectedError:"unsupportedNondeterministicIdentity"),Case(id:"m2-negative-case-insensitive-collision",request:requests[1],expected:nil,expectedError:"unsupportedCaseInsensitiveCollision")]
let corpus = Corpus(corpusVersion:1,producer:.init(name:"VoxboardM2Oracle",productionConsumers:["CapturePathPlanner","CaptureMarkdownRenderer","CaptureEntryTemplateRenderer","MarkdownDocumentEditor"],sourceSHA256:sourceSHA256),cases:cases)
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(corpus)); FileHandle.standardOutput.write(Data([0x0a]))
