import Foundation
import VoxboardShared

/// Pure configuration preview used by both preset editors. It deliberately
/// exercises the delivery renderer and document merger so the editor surfaces
/// the same template, key, and existing-frontmatter failures as Capture.
struct CaptureLocationConfigurationPreviewError: Error {
    let message: String
}

enum CaptureLocationConfigurationPreview {
    static let sampleRequestID = UUID(uuidString: "12345678-1234-1234-1234-1234567890ab")!

    static func result(
        profile: CapturePresetProfile,
        source: CaptureSource
    ) -> Result<String, CaptureLocationConfigurationPreviewError> {
        do {
            return .success(try render(profile: profile, source: source))
        } catch let error as CaptureLocationMetadataError {
            return .failure(CaptureLocationConfigurationPreviewError(message: localizedMessage(for: error)))
        } catch {
            return .failure(CaptureLocationConfigurationPreviewError(
                message: String(localized: "Error") + ": " + error.localizedDescription
            ))
        }
    }

    static func render(
        profile: CapturePresetProfile,
        source: CaptureSource
    ) throws -> String {
        let snapshot = CaptureLocationSnapshot(
            latitude: 37.774929,
            longitude: -122.419416,
            horizontalAccuracy: 8.5,
            timestamp: Date(timeIntervalSince1970: 1_735_689_600),
            source: source,
            precision: profile.locationPolicy.precision,
            label: CaptureLocationLabel(
                place: "Civic Center",
                city: "San Francisco",
                region: "California",
                country: "United States"
            )
        )
        let request = CaptureRequest(
            id: sampleRequestID,
            source: source,
            destinationID: sampleRequestID,
            payloads: [.text(String(localized: "Delivery Preview"))],
            voxProfile: profile,
            voxProcessingState: .applied,
            locationOutcome: .available(snapshot)
        )
        guard let metadata = try CaptureLocationMetadataRenderer().render(request: request) else {
            return ""
        }
        if profile.metadataScope == .entry {
            return metadata.inlineLines.joined(separator: "\n")
        }
        return try MarkdownDocumentEditor().applying(
            MarkdownCaptureMutation(
                requestID: metadata.requestID,
                entry: String(localized: "Delivery Preview"),
                placement: .append,
                frontmatter: profile.staticFrontmatter,
                locationMetadata: metadata
            ),
            to: ""
        )
    }

    private static func localizedMessage(for error: CaptureLocationMetadataError) -> String {
        // Core validation errors contain only configuration keys, line numbers,
        // and bounded structural descriptions—never coordinates or note text.
        String(localized: "Error") + ": " + error.localizedDescription
    }
}

extension CaptureLocationField {
    var configurationDisplayName: String {
        switch self {
        case .coordinates: String(localized: "Location Metadata") + " · coordinates"
        case .latitude: String(localized: "Location Metadata") + " · latitude"
        case .longitude: String(localized: "Location Metadata") + " · longitude"
        case .place: String(localized: "Location") + " · place"
        case .city: String(localized: "City")
        case .region: String(localized: "Location") + " · region"
        case .country: String(localized: "Location") + " · country"
        case .appleMapsURL: "Apple Maps URL"
        case .googleMapsURL: "Google Maps URL"
        case .openStreetMapURL: "OpenStreetMap URL"
        case .geoURI: "geo: URI"
        case .accuracy: String(localized: "Location Metadata") + " · accuracy"
        case .timestamp: String(localized: "Timestamp")
        case .source: String(localized: "Capture Sources")
        case .id: "Capture ID"
        }
    }
}

extension CaptureSource {
    var configurationDisplayName: String {
        switch self {
        case .app: String(localized: "App")
        case .keyboard: String(localized: "Keyboard")
        case .widget: String(localized: "Widget")
        case .shortcut: String(localized: "Shortcut")
        case .shareExtension: String(localized: "Share")
        case .watch: String(localized: "Apple Watch")
        case .mac: String(localized: "Mac")
        case .deepLink: String(localized: "Deep Link")
        case .fileImport: String(localized: "File Import")
        case .voice: String(localized: "Voice")
        }
    }
}
