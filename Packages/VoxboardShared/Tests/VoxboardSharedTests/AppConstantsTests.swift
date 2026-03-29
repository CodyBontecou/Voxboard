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
}
