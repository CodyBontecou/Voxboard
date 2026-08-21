import Foundation
import SwiftUI
import VoxboardShared

/// Shared support for the `{location}` entry template token. The token renders
/// a map link when the delivering Capture Preset uses Current Location,
/// independently of metadata output. These helpers surface that dependency in
/// editors and in the capture composer instead of letting it fail silently.
enum CaptureEntryLocationTokenSupport {
    /// True when either entry formatting field references `{location}`.
    static func referencesLocation(prefix: String, suffix: String) -> Bool {
        CaptureEntryTemplateRenderer.referencesLocation(in: prefix)
            || CaptureEntryTemplateRenderer.referencesLocation(in: suffix)
    }

    /// True when a capture's effective entry formatting references `{location}`
    /// while the preset that will deliver it has Current Location disabled.
    /// Mirrors the delivery-time template resolution exactly: the one-capture
    /// template override outranks the preset's template, and vault Markdown
    /// templates replace inline prefix/suffix entirely.
    static func needsPresetOptIn(
        library: CaptureLibraryEnvelope,
        destinationID: UUID?,
        oneOffTemplateID: UUID?,
        preset: CapturePresetProfile?
    ) -> Bool {
        guard let preset, !preset.locationPolicy.isEnabled, let destinationID,
              let stored = library.destinations.first(where: { $0.id == destinationID }) else {
            return false
        }
        let resolved = library.resolvedDestination(
            stored,
            overrideEntryTemplateID: oneOffTemplateID ?? preset.captureEntryTemplateID
        )
        guard resolved.markdownTemplatePath == nil else { return false }
        return referencesLocation(prefix: resolved.entryPrefix, suffix: resolved.entrySuffix)
    }

    /// Renders entry formatting through the delivery renderer with a synthetic
    /// available location, so editors preview exactly what `{location}` will
    /// produce. Returns nil when neither field references the token.
    static func renderedSample(
        prefix: String,
        suffix: String,
        precision: CaptureLocationPrecision = .exact
    ) -> String? {
        guard referencesLocation(prefix: prefix, suffix: suffix) else { return nil }
        var profile = CapturePresetProfile(
            id: "entry-location-token-preview",
            name: "Entry Location Token Preview",
            symbolName: "mappin.and.ellipse"
        )
        profile.locationPolicy.isEnabled = true
        profile.locationPolicy.precision = precision
        let request = CaptureRequest(
            id: CaptureLocationConfigurationPreview.sampleRequestID,
            createdAt: CaptureLocationConfigurationPreview.sampleTimestamp,
            source: .app,
            destinationID: CaptureLocationConfigurationPreview.sampleRequestID,
            payloads: [.text(String(localized: "Delivery Preview"))],
            voxProfile: profile,
            voxProcessingState: .applied,
            locationOutcome: .available(
                CaptureLocationConfigurationPreview.makeSampleSnapshot(
                    source: .app,
                    precision: precision
                )
            )
        )
        let renderer = CaptureEntryTemplateRenderer()
        var parts: [String] = []
        let renderedPrefix = renderer.render(prefix, for: request)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let renderedSuffix = renderer.render(suffix, for: request)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !renderedPrefix.isEmpty { parts.append(renderedPrefix) }
        if !renderedSuffix.isEmpty { parts.append(renderedSuffix) }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " … ")
    }
}

/// Shared editor row previewing how `{location}` renders. Shown only when the
/// edited formatting references the token.
struct CaptureEntryLocationTokenPreview: View {
    let sample: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(sample)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("The {location} token inserts this map link only when the Capture Preset delivering the capture uses Current Location. Location metadata is optional.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
