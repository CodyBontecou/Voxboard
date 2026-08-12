import XCTest
import VoxboardShared
@testable import Voxboard

final class CaptureLocationConfigurationSupportTests: XCTestCase {
    func testStructuredEntryPreviewUsesDeliveryInlineFields() throws {
        var profile = makeProfile(scope: .entry)
        profile.locationPolicy.structuredFields = [
            CaptureLocationStructuredField(field: .city, outputKey: "capture_city")
        ]

        let preview = try CaptureLocationConfigurationPreview.render(profile: profile, source: .app)

        XCTAssertTrue(preview.contains("location.id:: 12345678-1234-1234-1234-1234567890ab"))
        XCTAssertTrue(preview.contains("location.capture_city:: \"San Francisco\""))
    }

    func testDocumentPreviewSurfacesStaticFrontmatterCollectionCollision() {
        var profile = makeProfile(scope: .document)
        profile.staticFrontmatter = ["locations": "already-used"]

        XCTAssertThrowsError(
            try CaptureLocationConfigurationPreview.render(profile: profile, source: .app)
        ) { error in
            XCTAssertEqual(
                error as? CaptureLocationMetadataError,
                .frontmatterCollision("locations")
            )
        }
    }

    func testAdvancedTemplateAndEntryScopeAreRejectedWithoutLosingTemplate() {
        var profile = makeProfile(scope: .entry)
        profile.locationPolicy.outputMode = .advancedTemplate
        profile.locationPolicy.advancedTemplate = "where:\n  city: {{city}}"

        XCTAssertThrowsError(
            try CaptureLocationConfigurationPreview.render(profile: profile, source: .app)
        ) { error in
            XCTAssertEqual(
                error as? CaptureLocationMetadataError,
                .advancedTemplateRequiresDocumentScope
            )
        }
        XCTAssertEqual(profile.locationPolicy.advancedTemplate, "where:\n  city: {{city}}")
    }

    private func makeProfile(scope: CapturePresetMetadataScope) -> CapturePresetProfile {
        CapturePresetProfile(
            id: "location-preview-test",
            name: "Location Preview Test",
            symbolName: "location",
            locationPolicy: CapturePresetLocationPolicy(isEnabled: true),
            metadataScope: scope
        )
    }
}
