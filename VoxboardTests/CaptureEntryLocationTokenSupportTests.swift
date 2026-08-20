import XCTest
import VoxboardShared
@testable import Voxboard

final class CaptureEntryLocationTokenSupportTests: XCTestCase {
    // MARK: - renderedSample

    func testRenderedSampleIsNilWithoutLocationToken() {
        XCTAssertNil(CaptureEntryLocationTokenSupport.renderedSample(
            prefix: "- ",
            suffix: " #inbox"
        ))
        XCTAssertNil(CaptureEntryLocationTokenSupport.renderedSample(prefix: "", suffix: ""))
    }

    func testRenderedSampleRendersDeliveryMapLinkDeterministically() {
        XCTAssertEqual(
            CaptureEntryLocationTokenSupport.renderedSample(prefix: "", suffix: " Loc:{location}"),
            "Loc:[Location](https://www.google.com/maps/search/?api=1&query=37.774929%2C-122.419416)"
        )
    }

    func testRenderedSampleJoinsPrefixAndSuffixWithoutLeadingEllipsis() {
        XCTAssertEqual(
            CaptureEntryLocationTokenSupport.renderedSample(prefix: "- Entry", suffix: "📍 {location}"),
            "- Entry … 📍 [Location](https://www.google.com/maps/search/?api=1&query=37.774929%2C-122.419416)"
        )
    }

    func testRenderedSampleHonorsCityPrecision() {
        XCTAssertEqual(
            CaptureEntryLocationTokenSupport.renderedSample(prefix: "", suffix: "{location}", precision: .city),
            "[Location](https://www.google.com/maps/search/?api=1&query=37.77%2C-122.42)"
        )
    }

    // MARK: - needsPresetOptIn

    func testNeedsOptInWhenInlineSuffixReferencesTokenAndPresetLocationIsOff() {
        XCTAssertTrue(CaptureEntryLocationTokenSupport.needsPresetOptIn(
            library: makeLibrary(
                destination: makeDestination(suffix: " Loc:{location}")
            ),
            destinationID: destinationID,
            oneOffTemplateID: nil,
            preset: makePreset(locationEnabled: false)
        ))
    }

    func testNoOptInNeededWhenPresetAlreadyAttachesLocation() {
        XCTAssertFalse(CaptureEntryLocationTokenSupport.needsPresetOptIn(
            library: makeLibrary(
                destination: makeDestination(suffix: " Loc:{location}")
            ),
            destinationID: destinationID,
            oneOffTemplateID: nil,
            preset: makePreset(locationEnabled: true)
        ))
    }

    func testNoOptInNeededWhenFormattingOmitsToken() {
        XCTAssertFalse(CaptureEntryLocationTokenSupport.needsPresetOptIn(
            library: makeLibrary(
                destination: makeDestination(suffix: " #inbox")
            ),
            destinationID: destinationID,
            oneOffTemplateID: nil,
            preset: makePreset(locationEnabled: false)
        ))
    }

    func testReusableTemplateResolutionFindsTokenThroughPresetBinding() {
        let template = CaptureEntryTemplate(
            id: templateID,
            name: "Located",
            entryPrefix: "",
            entrySuffix: "\n📍 {location}"
        )
        var preset = makePreset(locationEnabled: false)
        preset.captureEntryTemplateID = templateID

        XCTAssertTrue(CaptureEntryLocationTokenSupport.needsPresetOptIn(
            library: makeLibrary(
                destination: makeDestination(suffix: ""),
                templates: [template]
            ),
            destinationID: destinationID,
            oneOffTemplateID: nil,
            preset: preset
        ))
    }

    func testOneOffTemplateOverrideOutranksPresetTemplate() {
        let locatedTemplate = CaptureEntryTemplate(
            id: templateID,
            name: "Located",
            entrySuffix: "📍 {location}"
        )
        let plainTemplate = CaptureEntryTemplate(
            id: oneOffTemplateID,
            name: "Plain",
            entrySuffix: " #tag"
        )
        var preset = makePreset(locationEnabled: false)
        preset.captureEntryTemplateID = templateID

        XCTAssertFalse(CaptureEntryLocationTokenSupport.needsPresetOptIn(
            library: makeLibrary(
                destination: makeDestination(suffix: ""),
                templates: [locatedTemplate, plainTemplate]
            ),
            destinationID: destinationID,
            oneOffTemplateID: oneOffTemplateID,
            preset: preset
        ))
    }

    func testVaultMarkdownTemplateReplacesInlineFormattingSoNoHintIsShown() {
        let destination = makeDestination(
            suffix: " Loc:{location}",
            markdownTemplatePath: "Templates/capture.md"
        )

        // Vault templates can still reference {location}, but their live file
        // is only readable at delivery; inline detection must not fire.
        XCTAssertFalse(CaptureEntryLocationTokenSupport.needsPresetOptIn(
            library: makeLibrary(destination: destination),
            destinationID: destinationID,
            oneOffTemplateID: nil,
            preset: makePreset(locationEnabled: false)
        ))
    }

    func testMissingDestinationOrPresetNeverHints() {
        XCTAssertFalse(CaptureEntryLocationTokenSupport.needsPresetOptIn(
            library: makeLibrary(destination: makeDestination(suffix: "{location}")),
            destinationID: nil,
            oneOffTemplateID: nil,
            preset: makePreset(locationEnabled: false)
        ))
        XCTAssertFalse(CaptureEntryLocationTokenSupport.needsPresetOptIn(
            library: makeLibrary(destination: makeDestination(suffix: "{location}")),
            destinationID: destinationID,
            oneOffTemplateID: nil,
            preset: nil
        ))
    }

    // MARK: - Fixtures

    private let destinationID = UUID()
    private let templateID = UUID()
    private let oneOffTemplateID = UUID()

    private func makeDestination(
        suffix: String,
        markdownTemplatePath: String? = nil
    ) -> CaptureDestination {
        CaptureDestination(
            id: destinationID,
            name: "Journal",
            rootBookmark: Data([0x01]),
            rootName: "Journal Vault",
            noteTarget: .newNote(pathTemplate: "Notes/{date}.md"),
            entrySuffix: suffix,
            markdownTemplatePath: markdownTemplatePath
        )
    }

    private func makeLibrary(
        destination: CaptureDestination,
        templates: [CaptureEntryTemplate] = []
    ) -> CaptureLibraryEnvelope {
        CaptureLibraryEnvelope(
            destinations: [destination],
            defaultDestinationID: destination.id,
            entryTemplates: templates
        )
    }

    private func makePreset(locationEnabled: Bool) -> CapturePresetProfile {
        var profile = CapturePresetProfile(
            id: "hint-test-preset",
            name: "Hint Test Preset",
            symbolName: "waveform"
        )
        profile.locationPolicy.isEnabled = locationEnabled
        return profile
    }
}
