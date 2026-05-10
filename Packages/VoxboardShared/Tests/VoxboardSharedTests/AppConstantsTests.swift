import XCTest
@testable import VoxboardShared

final class AppConstantsTests: XCTestCase {

    func test_appGroupIdentifier_isVoxboardGroup() {
        XCTAssertEqual(AppConstants.appGroupIdentifier, "group.bontecou.Voxboard")
    }

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

    func test_widgetListeningStateReadPath_usesSharedIPCLayout() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoxboardSharedTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }

        let directory = TranscriptionIPC.ipcDirectory(in: container)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = ListeningState(isListening: true, startedAt: 123)
        let data = try JSONEncoder().encode(state)
        try data.write(to: TranscriptionIPC.listeningStateURL(in: container), options: .atomic)

        let readState = TranscriptionIPC.readListeningState(containerURL: container)
        XCTAssertEqual(readState?.isListening, true)
        XCTAssertEqual(readState?.startedAt, 123)
    }
}
