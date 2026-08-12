import Foundation

/// Determines whether a Watch preset snapshot has a Capture Markdown location
/// surface. Recording Only is a raw audio export and intentionally opts out.
public enum CaptureWatchLocationAcquisitionPolicy {
    public static func shouldAcquire(presetSnapshot data: Data?) -> Bool {
        guard let data,
              let profile = try? JSONDecoder().decode(CapturePresetProfile.self, from: data),
              profile.locationPolicy.isEnabled else { return false }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["watchOutputMode"] as? String != "recordingOnly"
    }
}

public enum CaptureLocationPrecision: String, Codable, CaseIterable, Sendable {
    case exact
    case city
}

public enum CaptureLocationUnavailableBehavior: String, Codable, CaseIterable, Sendable {
    case ask
    case sendWithoutLocation
    case cancel
}

/// A request-scoped foreground decision. This is deliberately separate from
/// the preset policy so “Send Without Location” never mutates future captures.
public enum CaptureLocationDecisionOverride: String, Codable, Sendable {
    case sendWithoutLocation
}

public enum CaptureLocationOutputMode: String, Codable, CaseIterable, Sendable {
    case structured
    case advancedTemplate
}

public enum CaptureLocationField: String, Codable, CaseIterable, Sendable {
    case coordinates
    case latitude
    case longitude
    case place
    case city
    case region
    case country
    case appleMapsURL
    case googleMapsURL
    case openStreetMapURL
    case geoURI
    case accuracy
    case timestamp
    case source
    case id
}

/// One selected structured value and its user-visible YAML/inline key. The
/// single-value decoder preserves policies written before keys were renameable.
public struct CaptureLocationStructuredField: Codable, Equatable, Sendable {
    public var field: CaptureLocationField
    public var outputKey: String

    public init(field: CaptureLocationField, outputKey: String? = nil) {
        self.field = field
        self.outputKey = outputKey ?? field.rawValue
    }

    public static let coordinates = Self(field: .coordinates)
    public static let latitude = Self(field: .latitude)
    public static let longitude = Self(field: .longitude)
    public static let place = Self(field: .place)
    public static let city = Self(field: .city)
    public static let region = Self(field: .region)
    public static let country = Self(field: .country)
    public static let appleMapsURL = Self(field: .appleMapsURL)
    public static let googleMapsURL = Self(field: .googleMapsURL)
    public static let openStreetMapURL = Self(field: .openStreetMapURL)
    public static let geoURI = Self(field: .geoURI)
    public static let accuracy = Self(field: .accuracy)
    public static let timestamp = Self(field: .timestamp)
    public static let source = Self(field: .source)
    public static let id = Self(field: .id)

    private enum CodingKeys: String, CodingKey { case field, outputKey }

    public init(from decoder: Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(CaptureLocationField.self) {
            self.init(field: legacy)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let field = try container.decode(CaptureLocationField.self, forKey: .field)
        self.init(
            field: field,
            outputKey: try container.decodeIfPresent(String.self, forKey: .outputKey) ?? field.rawValue
        )
    }
}

public struct CapturePresetLocationPolicy: Codable, Equatable, Sendable {
    public static let defaultCollectionKey = "locations"
    public static let defaultStructuredFields: [CaptureLocationStructuredField] = [
        .coordinates, .place, .appleMapsURL, .timestamp, .source, .id,
    ]

    public var isEnabled: Bool
    public var precision: CaptureLocationPrecision
    public var unavailableBehavior: CaptureLocationUnavailableBehavior
    public var outputMode: CaptureLocationOutputMode
    public var structuredFields: [CaptureLocationStructuredField]
    public var collectionKey: String
    public var advancedTemplate: String

    public init(
        isEnabled: Bool = false,
        precision: CaptureLocationPrecision = .exact,
        unavailableBehavior: CaptureLocationUnavailableBehavior = .ask,
        outputMode: CaptureLocationOutputMode = .structured,
        structuredFields: [CaptureLocationStructuredField] = CapturePresetLocationPolicy.defaultStructuredFields,
        collectionKey: String = CapturePresetLocationPolicy.defaultCollectionKey,
        advancedTemplate: String = ""
    ) {
        self.isEnabled = isEnabled
        self.precision = precision
        self.unavailableBehavior = unavailableBehavior
        self.outputMode = outputMode
        self.structuredFields = structuredFields
        self.collectionKey = collectionKey
        self.advancedTemplate = advancedTemplate
    }

    /// Whether resolving this policy needs Apple's reverse geocoder. Keeping
    /// this on the pure Capture model lets lightweight clients (including the
    /// Watch app) apply the same label boundary without duplicating policy.
    public var requiresLabels: Bool {
        guard isEnabled else { return false }
        switch outputMode {
        case .structured:
            return structuredFields.contains {
                [.place, .city, .region, .country].contains($0.field)
            }
        case .advancedTemplate:
            return ["place", "city", "region", "country"].contains { field in
                advancedTemplate.range(
                    of: #"\{\{\s*\#(field)\s*\}\}"#,
                    options: .regularExpression
                ) != nil
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case precision
        case unavailableBehavior
        case outputMode
        case structuredFields
        case collectionKey
        case advancedTemplate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            precision: try container.decodeIfPresent(CaptureLocationPrecision.self, forKey: .precision) ?? .exact,
            unavailableBehavior: try container.decodeIfPresent(
                CaptureLocationUnavailableBehavior.self,
                forKey: .unavailableBehavior
            ) ?? .ask,
            outputMode: try container.decodeIfPresent(CaptureLocationOutputMode.self, forKey: .outputMode) ?? .structured,
            structuredFields: try container.decodeIfPresent(
                [CaptureLocationStructuredField].self,
                forKey: .structuredFields
            ) ?? Self.defaultStructuredFields,
            collectionKey: try container.decodeIfPresent(String.self, forKey: .collectionKey)
                ?? Self.defaultCollectionKey,
            advancedTemplate: try container.decodeIfPresent(String.self, forKey: .advancedTemplate) ?? ""
        )
    }
}

public struct CaptureLocationLabel: Codable, Equatable, Sendable {
    public var place: String?
    public var city: String?
    public var region: String?
    public var country: String?

    public init(place: String? = nil, city: String? = nil, region: String? = nil, country: String? = nil) {
        self.place = place
        self.city = city
        self.region = region
        self.country = country
    }
}

/// A privacy-adjusted, origin-time value. City snapshots discard point-of-
/// interest labels before they can enter a durable request.
public struct CaptureLocationSnapshot: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var horizontalAccuracy: Double?
    public var timestamp: Date
    public var source: CaptureSource
    public var precision: CaptureLocationPrecision
    public var label: CaptureLocationLabel?

    public init(
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double? = nil,
        timestamp: Date,
        source: CaptureSource,
        precision: CaptureLocationPrecision,
        label: CaptureLocationLabel? = nil
    ) {
        self.latitude = Self.adjust(latitude, precision: precision)
        self.longitude = Self.adjust(longitude, precision: precision)
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
        self.source = source
        self.precision = precision
        if precision == .city, let label {
            self.label = CaptureLocationLabel(
                place: nil,
                city: label.city,
                region: label.region,
                country: label.country
            )
        } else {
            self.label = label
        }
    }

    private enum CodingKeys: String, CodingKey {
        case latitude
        case longitude
        case horizontalAccuracy
        case timestamp
        case source
        case precision
        case label
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            latitude: try container.decode(Double.self, forKey: .latitude),
            longitude: try container.decode(Double.self, forKey: .longitude),
            horizontalAccuracy: try container.decodeIfPresent(Double.self, forKey: .horizontalAccuracy),
            timestamp: try container.decode(Date.self, forKey: .timestamp),
            source: try container.decode(CaptureSource.self, forKey: .source),
            precision: try container.decode(CaptureLocationPrecision.self, forKey: .precision),
            label: try container.decodeIfPresent(CaptureLocationLabel.self, forKey: .label)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.adjust(latitude, precision: precision), forKey: .latitude)
        try container.encode(Self.adjust(longitude, precision: precision), forKey: .longitude)
        try container.encodeIfPresent(horizontalAccuracy, forKey: .horizontalAccuracy)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(source, forKey: .source)
        try container.encode(precision, forKey: .precision)
        if precision == .city, let label {
            try container.encode(
                CaptureLocationLabel(
                    place: nil,
                    city: label.city,
                    region: label.region,
                    country: label.country
                ),
                forKey: .label
            )
        } else {
            try container.encodeIfPresent(label, forKey: .label)
        }
    }

    private static func adjust(_ value: Double, precision: CaptureLocationPrecision) -> Double {
        guard precision == .city else { return value }
        return (value * 100).rounded() / 100
    }
}

public enum CaptureLocationUnavailableReason: String, Codable, CaseIterable, Sendable {
    case permissionDenied
    case restricted
    case notDetermined
    /// The user granted only approximate location while exact precision was
    /// required. Callers must not label the resulting fix as exact.
    case reducedAccuracy
    case timeout
    case cancelled
    case unavailable
}

public enum CaptureLocationOutcome: Equatable, Sendable {
    /// Timestamp fallback used only to decode the short-lived legacy outcome
    /// shape that predated durable origin timestamps.
    public static let legacyUnknownAttemptedAt = Date(timeIntervalSince1970: 0)

    case available(CaptureLocationSnapshot)
    case unavailable(CaptureLocationUnavailableReason, attemptedAt: Date)
}

extension CaptureLocationOutcome: Codable {
    private enum Kind: String, Codable { case available, unavailable }
    private enum CodingKeys: String, CodingKey { case kind, snapshot, reason, attemptedAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .available:
            self = .available(try container.decode(CaptureLocationSnapshot.self, forKey: .snapshot))
        case .unavailable:
            self = .unavailable(
                try container.decode(CaptureLocationUnavailableReason.self, forKey: .reason),
                attemptedAt: try container.decodeIfPresent(Date.self, forKey: .attemptedAt)
                    ?? Self.legacyUnknownAttemptedAt
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available(let snapshot):
            try container.encode(Kind.available, forKey: .kind)
            try container.encode(snapshot, forKey: .snapshot)
        case .unavailable(let reason, let attemptedAt):
            try container.encode(Kind.unavailable, forKey: .kind)
            try container.encode(reason, forKey: .reason)
            try container.encode(attemptedAt, forKey: .attemptedAt)
        }
    }
}

public enum CaptureLocationMetadataError: Error, Equatable, LocalizedError, Sendable {
    case invalidCoordinate
    case invalidCollectionKey(String)
    case invalidOutputKey(String)
    case duplicateOutputKey(String)
    case templateTooLarge
    case outputTooLarge
    case invalidTemplateLine(Int)
    case unknownTemplateField(String, line: Int)
    case unsafeTemplate(Int)
    case reservedFieldCollision(String)
    case duplicateTemplateKey(String, Int)
    case frontmatterCollision(String)
    case advancedTemplateRequiresDocumentScope

    public var errorDescription: String? {
        switch self {
        case .invalidCoordinate:
            return "Location Metadata · coordinates"
        case .invalidCollectionKey(let key):
            return "Location Metadata · \(key)"
        case .invalidOutputKey(let key), .duplicateOutputKey(let key):
            return "Output · \(key)"
        case .templateTooLarge, .outputTooLarge:
            return "Advanced YAML Template"
        case .invalidTemplateLine(let line), .unsafeTemplate(let line):
            return "Advanced YAML Template · \(line)"
        case .unknownTemplateField(let field, let line),
             .duplicateTemplateKey(let field, let line):
            return "Advanced YAML Template · \(field) · \(line)"
        case .reservedFieldCollision(let field), .frontmatterCollision(let field):
            return "Location Metadata · \(field)"
        case .advancedTemplateRequiresDocumentScope:
            return "Advanced YAML Template · Note Frontmatter"
        }
    }
}

public struct CaptureLocationFormattedValues: Equatable, Sendable {
    public let values: [CaptureLocationField: String]

    public subscript(_ field: CaptureLocationField) -> String? { values[field] }
}

public struct CaptureLocationFormatter: Sendable {
    public init() {}

    public func format(
        snapshot: CaptureLocationSnapshot,
        requestID: UUID,
        precision: CaptureLocationPrecision? = nil
    ) throws -> CaptureLocationFormattedValues {
        let precision = precision ?? snapshot.precision
        guard snapshot.latitude.isFinite, snapshot.longitude.isFinite,
              (-90...90).contains(snapshot.latitude), (-180...180).contains(snapshot.longitude) else {
            throw CaptureLocationMetadataError.invalidCoordinate
        }
        let decimals = precision == .city ? 2 : 6
        let latitude = coordinate(snapshot.latitude, decimals: decimals)
        let longitude = coordinate(snapshot.longitude, decimals: decimals)
        let pair = "\(latitude), \(longitude)"
        let queryPair = "\(latitude),\(longitude)"
        let label = precision == .city
            ? firstNonempty(snapshot.label?.city, snapshot.label?.region, snapshot.label?.country, pair)
            : firstNonempty(snapshot.label?.place, snapshot.label?.city, pair)
        let encodedPair = percentEncode(queryPair)
        let encodedLabel = percentEncode(label)
        let zoom = precision == .city ? 10 : 16
        let validAccuracy = snapshot.horizontalAccuracy.flatMap { accuracy in
            accuracy.isFinite && accuracy >= 0 ? accuracy : nil
        }
        let geoAccuracy = validAccuracy.map { ";u=\(Self.fixed($0, decimals: 1))" } ?? ""

        var values: [CaptureLocationField: String] = [
            .coordinates: pair,
            .latitude: latitude,
            .longitude: longitude,
            .appleMapsURL: "https://maps.apple.com/?ll=\(encodedPair)&q=\(encodedLabel)",
            .googleMapsURL: "https://www.google.com/maps/search/?api=1&query=\(encodedPair)",
            .openStreetMapURL: "https://www.openstreetmap.org/?mlat=\(latitude)&mlon=\(longitude)#map=\(zoom)/\(latitude)/\(longitude)",
            .geoURI: "geo:\(queryPair)\(geoAccuracy)",
            .timestamp: Self.timestampFormatter.string(from: snapshot.timestamp),
            .source: snapshot.source.rawValue,
            .id: requestID.uuidString.lowercased(),
        ]
        if let validAccuracy {
            values[.accuracy] = Self.fixed(validAccuracy, decimals: 1) + " m"
        }
        if precision == .city {
            values[.place] = label
        } else if let place = nonempty(snapshot.label?.place) {
            values[.place] = place
        }
        if let city = nonempty(snapshot.label?.city) { values[.city] = city }
        if let region = nonempty(snapshot.label?.region) { values[.region] = region }
        if let country = nonempty(snapshot.label?.country) { values[.country] = country }
        return CaptureLocationFormattedValues(values: values)
    }

    private func coordinate(_ value: Double, decimals: Int) -> String {
        let adjusted = decimals == 2 ? (value * 100).rounded() / 100 : value
        return Self.fixed(adjusted == 0 ? 0 : adjusted, decimals: decimals)
    }

    private static func fixed(_ value: Double, decimals: Int) -> String {
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), decimals, value)
    }

    private func percentEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private func nonempty(_ value: String?) -> String? {
        let normalized = value?
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }

    private func firstNonempty(_ values: String?...) -> String {
        values.compactMap(nonempty).first ?? ""
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

// MARK: - Constrained YAML

indirect enum CaptureLocationYAMLValue: Equatable, Sendable {
    case string(String)
    case number(String)
    case boolean(Bool)
    case null
    case placeholder(CaptureLocationField, line: Int)
    case mapping([CaptureLocationYAMLPair])
    case sequence([CaptureLocationYAMLValue])
    case flowSequence([CaptureLocationYAMLValue])
}

struct CaptureLocationYAMLPair: Equatable, Sendable {
    var key: String
    var value: CaptureLocationYAMLValue
    var line: Int
}

struct CaptureLocationConstrainedYAMLParser {
    private struct Line {
        var indent: Int
        var content: String
        var number: Int
    }

    private var lines: [Line]
    private var index = 0

    init(source: String, maximumDepth: Int) throws {
        self.lines = try source.components(separatedBy: "\n").enumerated().compactMap { offset, raw in
            let number = offset + 1
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            let spaces = raw.prefix(while: { $0 == " " }).count
            guard spaces == raw.prefix(while: { $0 == " " || $0 == "\t" }).count,
                  spaces % 2 == 0,
                  spaces / 2 <= maximumDepth else {
                throw CaptureLocationMetadataError.invalidTemplateLine(number)
            }
            let content = String(raw.dropFirst(spaces))
            guard !content.hasPrefix("#"), content != "---", content != "..." else {
                throw CaptureLocationMetadataError.unsafeTemplate(number)
            }
            return Line(indent: spaces, content: content, number: number)
        }
    }

    mutating func parse() throws -> CaptureLocationYAMLValue {
        guard let first = lines.first else {
            throw CaptureLocationMetadataError.invalidTemplateLine(1)
        }
        guard first.indent == 0 else {
            throw CaptureLocationMetadataError.invalidTemplateLine(first.number)
        }
        let value = try parseBlock(indent: 0)
        guard index == lines.count else {
            throw CaptureLocationMetadataError.invalidTemplateLine(lines[index].number)
        }
        return value
    }

    private mutating func parseBlock(indent: Int) throws -> CaptureLocationYAMLValue {
        guard index < lines.count, lines[index].indent == indent else {
            throw CaptureLocationMetadataError.invalidTemplateLine(
                index < lines.count ? lines[index].number : (lines.last?.number ?? 1)
            )
        }
        return lines[index].content.hasPrefix("- ") || lines[index].content == "-"
            ? try parseSequence(indent: indent)
            : try parseMapping(indent: indent)
    }

    private mutating func parseMapping(indent: Int) throws -> CaptureLocationYAMLValue {
        var pairs: [CaptureLocationYAMLPair] = []
        var keys = Set<String>()
        while index < lines.count, lines[index].indent == indent {
            let line = lines[index]
            guard !line.content.hasPrefix("- "), line.content != "-" else { break }
            let pair = try parseMappingPair(content: line.content, logicalIndent: indent, line: line.number)
            guard keys.insert(pair.key).inserted else {
                throw CaptureLocationMetadataError.duplicateTemplateKey(pair.key, line.number)
            }
            pairs.append(pair)
        }
        guard !pairs.isEmpty else {
            throw CaptureLocationMetadataError.invalidTemplateLine(lines[index].number)
        }
        return .mapping(pairs)
    }

    private mutating func parseMappingPair(
        content: String,
        logicalIndent: Int,
        line: Int
    ) throws -> CaptureLocationYAMLPair {
        guard let colon = content.firstIndex(of: ":") else {
            throw CaptureLocationMetadataError.invalidTemplateLine(line)
        }
        let key = String(content[..<colon]).trimmingCharacters(in: .whitespaces)
        guard Self.isValidKey(key) else {
            throw CaptureLocationMetadataError.invalidTemplateLine(line)
        }
        let rawValue = String(content[content.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        index += 1
        let value: CaptureLocationYAMLValue
        if rawValue.isEmpty {
            guard index < lines.count, lines[index].indent == logicalIndent + 2 else {
                throw CaptureLocationMetadataError.invalidTemplateLine(line)
            }
            value = try parseBlock(indent: logicalIndent + 2)
        } else {
            value = try parseScalar(rawValue, line: line)
        }
        return CaptureLocationYAMLPair(key: key, value: value, line: line)
    }

    private mutating func parseSequence(indent: Int) throws -> CaptureLocationYAMLValue {
        var values: [CaptureLocationYAMLValue] = []
        while index < lines.count, lines[index].indent == indent {
            let line = lines[index]
            guard line.content == "-" || line.content.hasPrefix("- ") else { break }
            let rest = line.content == "-"
                ? ""
                : String(line.content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            index += 1
            if rest.isEmpty {
                guard index < lines.count, lines[index].indent == indent + 2 else {
                    throw CaptureLocationMetadataError.invalidTemplateLine(line.number)
                }
                values.append(try parseBlock(indent: indent + 2))
            } else if Self.inlineMappingKey(in: rest) != nil {
                values.append(try parseSequenceMappingItem(
                    firstContent: rest,
                    sequenceIndent: indent,
                    line: line.number
                ))
            } else {
                values.append(try parseScalar(rest, line: line.number))
            }
        }
        guard !values.isEmpty else {
            throw CaptureLocationMetadataError.invalidTemplateLine(lines[index].number)
        }
        return .sequence(values)
    }

    private mutating func parseSequenceMappingItem(
        firstContent: String,
        sequenceIndent: Int,
        line: Int
    ) throws -> CaptureLocationYAMLValue {
        var pairs: [CaptureLocationYAMLPair] = []
        var keys = Set<String>()

        // The sequence marker consumed two columns, so a child of this inline
        // mapping key begins four columns beyond the sequence indentation.
        let first = try parseInlineSequencePair(
            content: firstContent,
            keyIndent: sequenceIndent + 2,
            line: line
        )
        keys.insert(first.key)
        pairs.append(first)

        while index < lines.count, lines[index].indent == sequenceIndent + 2 {
            let continuation = lines[index]
            guard !continuation.content.hasPrefix("- ") else {
                throw CaptureLocationMetadataError.invalidTemplateLine(continuation.number)
            }
            let pair = try parseMappingPair(
                content: continuation.content,
                logicalIndent: sequenceIndent + 2,
                line: continuation.number
            )
            guard keys.insert(pair.key).inserted else {
                throw CaptureLocationMetadataError.duplicateTemplateKey(pair.key, continuation.number)
            }
            pairs.append(pair)
        }
        return .mapping(pairs)
    }

    private mutating func parseInlineSequencePair(
        content: String,
        keyIndent: Int,
        line: Int
    ) throws -> CaptureLocationYAMLPair {
        guard let colon = content.firstIndex(of: ":") else {
            throw CaptureLocationMetadataError.invalidTemplateLine(line)
        }
        let key = String(content[..<colon]).trimmingCharacters(in: .whitespaces)
        guard Self.isValidKey(key) else {
            throw CaptureLocationMetadataError.invalidTemplateLine(line)
        }
        let rawValue = String(content[content.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        let value: CaptureLocationYAMLValue
        if rawValue.isEmpty {
            guard index < lines.count, lines[index].indent == keyIndent + 2 else {
                throw CaptureLocationMetadataError.invalidTemplateLine(line)
            }
            value = try parseBlock(indent: keyIndent + 2)
        } else {
            value = try parseScalar(rawValue, line: line)
        }
        return CaptureLocationYAMLPair(key: key, value: value, line: line)
    }

    private func parseScalar(_ raw: String, line: Int) throws -> CaptureLocationYAMLValue {
        if raw.hasPrefix("{{") || raw.hasSuffix("}}") {
            guard raw.hasPrefix("{{"), raw.hasSuffix("}}"),
                  raw.filter({ $0 == "{" }).count == 2,
                  raw.filter({ $0 == "}" }).count == 2 else {
                throw CaptureLocationMetadataError.invalidTemplateLine(line)
            }
            let name = String(raw.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            guard let field = CaptureLocationField(rawValue: name) else {
                throw CaptureLocationMetadataError.unknownTemplateField(name, line: line)
            }
            return .placeholder(field, line: line)
        }
        if raw.hasPrefix("[") || raw.hasSuffix("]") {
            guard raw.hasPrefix("["), raw.hasSuffix("]") else {
                throw CaptureLocationMetadataError.invalidTemplateLine(line)
            }
            let body = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if body.isEmpty { return .flowSequence([]) }
            let values = try body.split(separator: ",", omittingEmptySubsequences: false).map {
                try parseScalar(String($0).trimmingCharacters(in: .whitespaces), line: line)
            }
            return .flowSequence(values)
        }
        if raw.hasPrefix("\"") || raw.hasSuffix("\"") {
            guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else {
                throw CaptureLocationMetadataError.invalidTemplateLine(line)
            }
            return .string(try decodeDoubleQuoted(String(raw.dropFirst().dropLast()), line: line))
        }
        if raw.hasPrefix("'") || raw.hasSuffix("'") {
            guard raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") else {
                throw CaptureLocationMetadataError.invalidTemplateLine(line)
            }
            return .string(String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"))
        }
        guard !raw.contains("{{"), !raw.contains("}}"),
              !raw.contains(" #"), !raw.contains(": "),
              !raw.contains("&"), !raw.contains("*"), !raw.contains("!"),
              !raw.hasPrefix("|"), !raw.hasPrefix(">"), !raw.contains("<<:") else {
            throw CaptureLocationMetadataError.unsafeTemplate(line)
        }
        switch raw.lowercased() {
        case "true": return .boolean(true)
        case "false": return .boolean(false)
        case "null", "~": return .null
        default:
            if let number = Double(raw), number.isFinite { return .number(raw) }
            return .string(raw)
        }
    }

    private func decodeDoubleQuoted(_ raw: String, line: Int) throws -> String {
        var result = ""
        var escaped = false
        for character in raw {
            if escaped {
                switch character {
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                default: throw CaptureLocationMetadataError.invalidTemplateLine(line)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        guard !escaped else { throw CaptureLocationMetadataError.invalidTemplateLine(line) }
        return result
    }

    private static func inlineMappingKey(in value: String) -> String? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let key = value[..<colon].trimmingCharacters(in: .whitespaces)
        return isValidKey(key) ? key : nil
    }

    static func isValidKey<S: StringProtocol>(_ key: S) -> Bool {
        guard let first = key.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first) else { return false }
        return key.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains($0)
        }
    }
}

struct CaptureLocationYAMLRenderer {
    func mappingLines(_ pairs: [CaptureLocationYAMLPair], indentation: Int = 0) -> [String] {
        pairs.flatMap { pair in
            let prefix = String(repeating: " ", count: indentation) + pair.key + ":"
            switch pair.value {
            case .mapping(let nested):
                return [prefix] + mappingLines(nested, indentation: indentation + 2)
            case .sequence(let values):
                return [prefix] + sequenceLines(values, indentation: indentation + 2)
            default:
                return [prefix + " " + scalar(pair.value)]
            }
        }
    }

    private func sequenceLines(_ values: [CaptureLocationYAMLValue], indentation: Int) -> [String] {
        values.flatMap { value in
            let prefix = String(repeating: " ", count: indentation) + "-"
            switch value {
            case .mapping(let pairs):
                return [prefix] + mappingLines(pairs, indentation: indentation + 2)
            case .sequence(let nested):
                return [prefix] + sequenceLines(nested, indentation: indentation + 2)
            default:
                return [prefix + " " + scalar(value)]
            }
        }
    }

    func scalar(_ value: CaptureLocationYAMLValue) -> String {
        switch value {
        case .string(let value): return quoted(value)
        case .number(let value): return value
        case .boolean(let value): return value ? "true" : "false"
        case .null: return "null"
        case .flowSequence(let values): return "[" + values.map(scalar).joined(separator: ", ") + "]"
        case .placeholder, .mapping, .sequence:
            preconditionFailure("Only resolved scalar YAML values can render inline.")
        }
    }

    private func quoted(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

public struct CaptureLocationRenderedMetadata: Equatable, Sendable {
    public var requestID: UUID
    public var collectionKey: String
    /// YAML mapping lines without the collection's list indentation.
    public var itemLines: [String]
    /// Dataview-style fields kept adjacent to a rolling-note entry.
    public var inlineLines: [String]

    public init(requestID: UUID, collectionKey: String, itemLines: [String], inlineLines: [String]) {
        self.requestID = requestID
        self.collectionKey = collectionKey
        self.itemLines = itemLines
        self.inlineLines = inlineLines
    }
}

public struct CaptureLocationMetadataRenderer: Sendable {
    public static let maximumTemplateUTF8Bytes = 8_192
    public static let maximumOutputUTF8Bytes = 16_384
    public static let maximumTemplateLines = 128
    public static let maximumNestingDepth = 8

    public init() {}

    public func render(request: CaptureRequest) throws -> CaptureLocationRenderedMetadata? {
        guard let profile = request.voxProfile else { return nil }
        let policy = profile.locationPolicy
        guard policy.isEnabled else { return nil }
        if policy.outputMode == .advancedTemplate, profile.metadataScope == .entry {
            throw CaptureLocationMetadataError.advancedTemplateRequiresDocumentScope
        }
        guard case .available(let snapshot)? = request.locationOutcome else { return nil }
        try validateKey(policy.collectionKey, collection: true)
        let formatted = try CaptureLocationFormatter().format(
            snapshot: snapshot,
            requestID: request.id,
            precision: policy.precision
        )
        switch policy.outputMode {
        case .structured:
            return try renderStructured(
                policy: policy,
                snapshot: snapshot,
                formatted: formatted,
                requestID: request.id
            )
        case .advancedTemplate:
            return try renderAdvanced(
                policy: policy,
                formatted: formatted,
                requestID: request.id
            )
        }
    }

    private func renderStructured(
        policy: CapturePresetLocationPolicy,
        snapshot: CaptureLocationSnapshot,
        formatted: CaptureLocationFormattedValues,
        requestID: UUID
    ) throws -> CaptureLocationRenderedMetadata {
        let renderer = CaptureLocationYAMLRenderer()
        var pairs = [CaptureLocationYAMLPair(
            key: "id",
            value: .string(requestID.uuidString.lowercased()),
            line: 0
        )]
        var inline = ["location.id:: \(requestID.uuidString.lowercased())"]
        var outputKeys: Set<String> = ["id"]
        var selectedFields = Set<CaptureLocationField>()

        for selection in policy.structuredFields {
            if selection.field == .id {
                guard selection.outputKey == "id" else {
                    throw CaptureLocationMetadataError.reservedFieldCollision("id")
                }
                continue
            }
            try validateKey(selection.outputKey, collection: false)
            guard selectedFields.insert(selection.field).inserted else { continue }
            guard outputKeys.insert(selection.outputKey).inserted else {
                throw CaptureLocationMetadataError.duplicateOutputKey(selection.outputKey)
            }
            guard let value = structuredValue(
                for: selection.field,
                snapshot: snapshot,
                formatted: formatted
            ) else { continue }
            pairs.append(CaptureLocationYAMLPair(key: selection.outputKey, value: value, line: 0))
            inline.append("location.\(selection.outputKey):: \(renderer.scalar(value))")
        }
        let itemLines = renderer.mappingLines(pairs)
        try validateOutput(itemLines: itemLines, inlineLines: inline)
        return CaptureLocationRenderedMetadata(
            requestID: requestID,
            collectionKey: policy.collectionKey,
            itemLines: itemLines,
            inlineLines: inline
        )
    }

    private func renderAdvanced(
        policy: CapturePresetLocationPolicy,
        formatted: CaptureLocationFormattedValues,
        requestID: UUID
    ) throws -> CaptureLocationRenderedMetadata {
        let template = normalizeNewlines(policy.advancedTemplate)
        guard template.utf8.count <= Self.maximumTemplateUTF8Bytes,
              template.components(separatedBy: "\n").count <= Self.maximumTemplateLines else {
            throw CaptureLocationMetadataError.templateTooLarge
        }
        var parser = try CaptureLocationConstrainedYAMLParser(
            source: template,
            maximumDepth: Self.maximumNestingDepth
        )
        let parsed = try parser.parse()
        let rootPairs: [CaptureLocationYAMLPair]
        switch parsed {
        case .mapping(let pairs):
            rootPairs = pairs
        case .sequence(let values):
            guard values.count == 1, case .mapping(let pairs) = values[0] else {
                throw CaptureLocationMetadataError.invalidTemplateLine(1)
            }
            rootPairs = pairs
        default:
            throw CaptureLocationMetadataError.invalidTemplateLine(1)
        }
        guard !rootPairs.contains(where: { $0.key == "id" }) else {
            throw CaptureLocationMetadataError.reservedFieldCollision("id")
        }
        let resolved = rootPairs.compactMap { pair -> CaptureLocationYAMLPair? in
            guard let value = resolve(pair.value, formatted: formatted) else { return nil }
            return CaptureLocationYAMLPair(key: pair.key, value: value, line: pair.line)
        }
        var pairs = [CaptureLocationYAMLPair(
            key: "id",
            value: .string(requestID.uuidString.lowercased()),
            line: 0
        )]
        pairs.append(contentsOf: resolved)
        let itemLines = CaptureLocationYAMLRenderer().mappingLines(pairs)
        try validateOutput(itemLines: itemLines, inlineLines: [])
        return CaptureLocationRenderedMetadata(
            requestID: requestID,
            collectionKey: policy.collectionKey,
            itemLines: itemLines,
            inlineLines: []
        )
    }

    private func resolve(
        _ value: CaptureLocationYAMLValue,
        formatted: CaptureLocationFormattedValues
    ) -> CaptureLocationYAMLValue? {
        switch value {
        case .placeholder(let field, _):
            return typedFormattedValue(field, formatted: formatted)
        case .mapping(let pairs):
            let resolved = pairs.compactMap { pair -> CaptureLocationYAMLPair? in
                guard let value = resolve(pair.value, formatted: formatted) else { return nil }
                return CaptureLocationYAMLPair(key: pair.key, value: value, line: pair.line)
            }
            return resolved.isEmpty ? nil : .mapping(resolved)
        case .sequence(let values):
            let resolved = values.compactMap { resolve($0, formatted: formatted) }
            return resolved.isEmpty ? nil : .sequence(resolved)
        case .flowSequence(let values):
            let resolved = values.compactMap { resolve($0, formatted: formatted) }
            return resolved.isEmpty ? nil : .flowSequence(resolved)
        default:
            return value
        }
    }

    private func structuredValue(
        for field: CaptureLocationField,
        snapshot: CaptureLocationSnapshot,
        formatted: CaptureLocationFormattedValues
    ) -> CaptureLocationYAMLValue? {
        if field == .accuracy {
            guard let accuracy = snapshot.horizontalAccuracy, accuracy.isFinite, accuracy >= 0 else { return nil }
            return .number(Self.fixed(accuracy, decimals: 1))
        }
        return typedFormattedValue(field, formatted: formatted)
    }

    private func typedFormattedValue(
        _ field: CaptureLocationField,
        formatted: CaptureLocationFormattedValues
    ) -> CaptureLocationYAMLValue? {
        switch field {
        case .coordinates:
            guard let latitude = formatted[.latitude], let longitude = formatted[.longitude] else { return nil }
            return .flowSequence([.number(latitude), .number(longitude)])
        case .latitude, .longitude:
            guard let value = formatted[field] else { return nil }
            return .number(value)
        case .accuracy:
            guard let value = formatted[field], let number = value.split(separator: " ").first else { return nil }
            return .number(String(number))
        default:
            guard let value = formatted[field] else { return nil }
            return .string(value)
        }
    }

    private func validateKey(_ key: String, collection: Bool) throws {
        guard CaptureLocationConstrainedYAMLParser.isValidKey(key), key.utf8.count <= 64 else {
            if collection { throw CaptureLocationMetadataError.invalidCollectionKey(key) }
            throw CaptureLocationMetadataError.invalidOutputKey(key)
        }
        if !collection, key == "id" {
            throw CaptureLocationMetadataError.reservedFieldCollision("id")
        }
    }

    private func validateOutput(itemLines: [String], inlineLines: [String]) throws {
        guard itemLines.joined(separator: "\n").utf8.count <= Self.maximumOutputUTF8Bytes,
              inlineLines.joined(separator: "\n").utf8.count <= Self.maximumOutputUTF8Bytes else {
            throw CaptureLocationMetadataError.outputTooLarge
        }
    }

    private static func fixed(_ value: Double, decimals: Int) -> String {
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), decimals, value)
    }

    private func normalizeNewlines(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
