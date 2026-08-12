import VoxboardShared
import XCTest
@testable import Voxboard

final class WidgetRecordingFlowSelectionTests: XCTestCase {
    func testStaticWidgetURLClearsStaleExplicitFlow() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("stale-control-flow", forKey: AppConstants.pendingWidgetRecordFlowIdKey)

        WidgetRecordingFlowSelection.persistRequestedFlowID(
            from: try XCTUnwrap(URL(string: "voxboard://widget-record")),
            defaults: defaults
        )

        XCTAssertNil(defaults.string(forKey: AppConstants.pendingWidgetRecordFlowIdKey))
    }

    func testWidgetURLPersistsExplicitFlowWhenProvided() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        WidgetRecordingFlowSelection.persistRequestedFlowID(
            from: try XCTUnwrap(URL(string: "voxboard://widget-record?flowId=configured")),
            defaults: defaults
        )

        XCTAssertEqual(
            defaults.string(forKey: AppConstants.pendingWidgetRecordFlowIdKey),
            "configured"
        )
    }

    func testLegacyWidgetFallsBackToDurableSelectedFlow() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let (selected, composerDraft) = makeFlows()
        CapturePresetStore.saveFlows([selected, composerDraft], defaults: defaults)
        CapturePresetStore.selectFlow(id: selected.id, defaults: defaults)

        let selection = WidgetRecordingFlowSelection.resolve(
            requestedFlowID: nil,
            defaults: defaults
        )

        XCTAssertEqual(selection.flowID, selected.id)
        XCTAssertNotEqual(selection.flowID, composerDraft.id)
        XCTAssertNil(selection.explicitlyRequestedFlow)
    }

    func testConfiguredControlWidgetKeepsItsExplicitEnabledFlow() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let (selected, configured) = makeFlows()
        CapturePresetStore.saveFlows([selected, configured], defaults: defaults)
        CapturePresetStore.selectFlow(id: selected.id, defaults: defaults)

        let selection = WidgetRecordingFlowSelection.resolve(
            requestedFlowID: configured.id,
            defaults: defaults
        )

        XCTAssertEqual(selection.flowID, configured.id)
        XCTAssertEqual(selection.explicitlyRequestedFlow?.id, configured.id)
    }

    func testDisabledRequestedFlowFallsBackToDurableSelectedFlow() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let (selected, configured) = makeFlows(configuredIsEnabled: false)
        CapturePresetStore.saveFlows([selected, configured], defaults: defaults)
        CapturePresetStore.selectFlow(id: selected.id, defaults: defaults)

        let selection = WidgetRecordingFlowSelection.resolve(
            requestedFlowID: configured.id,
            defaults: defaults
        )

        XCTAssertEqual(selection.flowID, selected.id)
        XCTAssertNil(selection.explicitlyRequestedFlow)
    }

    private func makeFlows(
        configuredIsEnabled: Bool = true
    ) -> (selected: CapturePreset, configured: CapturePreset) {
        var selected = CapturePresetStore.makeCustomFlow()
        selected.id = "durable-selected"
        selected.name = "Durable selected"

        var configured = CapturePresetStore.makeCustomFlow()
        configured.id = "composer-or-control"
        configured.name = "Composer or control"
        configured.isEnabled = configuredIsEnabled
        return (selected, configured)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "test.widget-recording-flow-selection.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }
}
