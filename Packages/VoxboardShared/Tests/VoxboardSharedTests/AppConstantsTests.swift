import XCTest
@testable import VoxboardShared

final class AppConstantsTests: XCTestCase {

    func test_fileExportEnabledKey_isDefined() {
        XCTAssertFalse(AppConstants.fileExportEnabledKey.isEmpty)
    }

    func test_fileExportFormatKey_isDefined() {
        XCTAssertFalse(AppConstants.fileExportFormatKey.isEmpty)
    }

    func test_fileExportModeKey_isDefined() {
        XCTAssertFalse(AppConstants.fileExportModeKey.isEmpty)
    }

    func test_fileExportBookmarkKey_isDefined() {
        XCTAssertFalse(AppConstants.fileExportBookmarkKey.isEmpty)
    }

    func test_fileExportYAMLPropertiesKey_isDefined() {
        XCTAssertFalse(AppConstants.fileExportYAMLPropertiesKey.isEmpty)
    }

    func test_fileExportYAMLObsidianBasesKey_isDefined() {
        XCTAssertFalse(AppConstants.fileExportYAMLObsidianBasesKey.isEmpty)
    }

    func test_fileExportNewFileNameTemplateKey_isDefined() {
        XCTAssertFalse(AppConstants.fileExportNewFileNameTemplateKey.isEmpty)
    }

    func test_fileExportAppendFileNameKey_isDefined() {
        XCTAssertFalse(AppConstants.fileExportAppendFileNameKey.isEmpty)
    }

    func test_autoListenEnabledKey_isDefined() {
        XCTAssertFalse(AppConstants.autoListenEnabledKey.isEmpty)
    }

    func test_pendingWidgetRecordKey_isDefined() {
        XCTAssertFalse(AppConstants.pendingWidgetRecordKey.isEmpty)
    }

    func test_pendingWidgetRecordFlowIdKey_isDefined() {
        XCTAssertFalse(AppConstants.pendingWidgetRecordFlowIdKey.isEmpty)
    }

    func test_voiceAutoStopRetainsLegacyPreferenceKeys() {
        XCTAssertEqual(
            AppConstants.voiceAutoStopEnabledKey,
            AppConstants.parakeetKeyboardAutoStopEnabledKey
        )
        XCTAssertEqual(
            AppConstants.voiceAutoStopPauseDurationKey,
            AppConstants.parakeetKeyboardPauseDurationKey
        )
    }

    func test_voiceAutoStopCapturePathsHaveIndependentPreferenceKeys() {
        let keys = VoiceAutoStopCapturePath.allCases.map {
            AppConstants.voiceAutoStopCapturePathKey(for: $0)
        }

        XCTAssertEqual(Set(keys).count, VoiceAutoStopCapturePath.allCases.count)
        XCTAssertTrue(keys.allSatisfy {
            $0.hasPrefix(AppConstants.voiceAutoStopCapturePathKeyPrefix)
        })
    }

    func test_captureStorageUsesVersionedStableNames() {
        XCTAssertEqual(AppConstants.captureDirectoryName, "Capture")
        XCTAssertEqual(AppConstants.captureLibraryFilename, "capture-library-v1.json")
        XCTAssertEqual(
            AppConstants.captureLibraryURL?.lastPathComponent,
            AppConstants.captureLibraryFilename
        )
        XCTAssertEqual(AppConstants.captureHistoryFilename, "capture-history-v1.json")
        XCTAssertEqual(
            AppConstants.captureHistoryURL?.lastPathComponent,
            AppConstants.captureHistoryFilename
        )
        XCTAssertEqual(AppConstants.activityStatsFilename, "activity-stats-v1.json")
        XCTAssertEqual(
            AppConstants.activityStatsURL?.lastPathComponent,
            AppConstants.activityStatsFilename
        )
    }
}
