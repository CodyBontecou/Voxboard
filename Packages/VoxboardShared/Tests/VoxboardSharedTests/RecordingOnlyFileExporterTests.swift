import XCTest
@testable import VoxboardShared

final class RecordingOnlyFileExporterTests: XCTestCase {
    func test_filenameTemplateRendersTokensAndSanitizesPathComponents() {
        let context = RecordingOnlyFileExportContext(
            recordingID: "ABCDEF12-3456-7890-ABCD-EF1234567890",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            presetName: "Dreams / Ideas",
            originalFilename: "watch-original.m4a"
        )

        let rendered = RecordingOnlyFileExporter.renderedFilenameBase(
            template: "../{preset}/{original}-{id8}.wav",
            context: context
        )

        XCTAssertFalse(rendered.contains("/"))
        XCTAssertFalse(rendered.contains(".."))
        XCTAssertTrue(rendered.contains("Dreams---Ideas"))
        XCTAssertTrue(rendered.contains("watch-original"))
        XCTAssertTrue(rendered.contains("abcdef12"))
        XCTAssertFalse(rendered.hasSuffix(".wav"))
    }

    func test_filenameIsBoundedByUTF8Bytes() {
        let context = RecordingOnlyFileExportContext(
            recordingID: "12345678-1234-1234-1234-1234567890AB",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            presetName: String(repeating: "🎙️", count: 200),
            originalFilename: "watch.m4a"
        )

        let rendered = RecordingOnlyFileExporter.renderedFilenameBase(
            template: "{preset}",
            context: context
        )

        XCTAssertLessThanOrEqual(rendered.utf8.count, 180)
    }

    func test_emptyTemplateUsesStableDefault() {
        let context = RecordingOnlyFileExportContext(
            recordingID: "12345678-1234-1234-1234-1234567890AB",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            presetName: "Default",
            originalFilename: "watch.m4a"
        )

        let rendered = RecordingOnlyFileExporter.renderedFilenameBase(
            template: "   ",
            context: context
        )

        XCTAssertTrue(rendered.hasPrefix("recording-"))
        XCTAssertTrue(rendered.hasSuffix("-12345678"))
    }

    func test_missingAndInvalidBookmarksFailWithoutTouchingSource() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exporter = RecordingOnlyFileExporter()

        XCTAssertThrowsError(
            try exporter.reserveFilename(
                context: fixture.context,
                settings: CapturePresetWatchRecordingSettings(),
                existingReservation: nil
            )
        ) { error in
            XCTAssertEqual(error as? RecordingOnlyFileExportError, .folderNotConfigured)
        }

        var invalid = fixture.settings
        invalid.folderBookmark = Data([0, 1, 2, 3])
        XCTAssertThrowsError(try exporter.validateDestination(settings: invalid)) { error in
            XCTAssertEqual(error as? RecordingOnlyFileExportError, .invalidFolderBookmark)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceData)
    }

    func test_copyCreatesVerifiedM4AAndKeepsSource() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exporter = RecordingOnlyFileExporter(
            coordinator: ProcessLocalCaptureFileCoordinator()
        )

        let filename = try exporter.reserveFilename(
            context: fixture.context,
            settings: fixture.settings,
            existingReservation: nil
        )
        let receipt = try exporter.copy(
            sourceURL: fixture.source,
            reservedFilename: filename,
            settings: fixture.settings
        )

        XCTAssertEqual(receipt.filename, "voice-abcdef12.m4a")
        XCTAssertFalse(receipt.wasAlreadyDelivered)
        XCTAssertEqual(try Data(contentsOf: receipt.fileURL), fixture.sourceData)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceData)
    }

    func test_reservationSuffixesConflictsWithoutOverwriting() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exporter = RecordingOnlyFileExporter(
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        let occupied = fixture.folder.appendingPathComponent("voice-abcdef12.m4a")
        let occupiedData = Data("existing".utf8)
        try occupiedData.write(to: occupied)

        let filename = try exporter.reserveFilename(
            context: fixture.context,
            settings: fixture.settings,
            existingReservation: nil
        )
        let receipt = try exporter.copy(
            sourceURL: fixture.source,
            reservedFilename: filename,
            settings: fixture.settings
        )

        XCTAssertEqual(filename, "voice-abcdef12-2.m4a")
        XCTAssertEqual(try Data(contentsOf: occupied), occupiedData)
        XCTAssertEqual(try Data(contentsOf: receipt.fileURL), fixture.sourceData)
    }

    func test_existingReservedFileWithSameBytesIsIdempotent() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exporter = RecordingOnlyFileExporter(
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        let filename = "reserved.m4a"
        let destination = fixture.folder.appendingPathComponent(filename)
        try fixture.sourceData.write(to: destination)

        let receipt = try exporter.copy(
            sourceURL: fixture.source,
            reservedFilename: filename,
            settings: fixture.settings
        )

        XCTAssertTrue(receipt.wasAlreadyDelivered)
        XCTAssertEqual(
            receipt.fileURL.resolvingSymlinksInPath(),
            destination.resolvingSymlinksInPath()
        )
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceData)
    }

    func test_existingReservedFileWithDifferentBytesReportsConflict() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exporter = RecordingOnlyFileExporter(
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        let filename = "reserved.m4a"
        try Data("different".utf8).write(
            to: fixture.folder.appendingPathComponent(filename)
        )

        XCTAssertThrowsError(
            try exporter.copy(
                sourceURL: fixture.source,
                reservedFilename: filename,
                settings: fixture.settings
            )
        ) { error in
            XCTAssertEqual(error as? RecordingOnlyFileExportError, .filenameConflict)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceData)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RecordingOnlyFileExporterTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let folder = root.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("watch-source.m4a")
        let sourceData = Data((0..<512).map { UInt8($0 % 251) })
        try sourceData.write(to: source)
        let bookmark = try folder.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let settings = CapturePresetWatchRecordingSettings(
            folderBookmark: bookmark,
            folderName: "Files",
            filenameTemplate: "voice-{id8}"
        )
        let context = RecordingOnlyFileExportContext(
            recordingID: "ABCDEF12-3456-7890-ABCD-EF1234567890",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            presetName: "Voice",
            originalFilename: source.lastPathComponent
        )
        return Fixture(
            root: root,
            folder: folder,
            source: source,
            sourceData: sourceData,
            settings: settings,
            context: context
        )
    }

    private struct Fixture {
        let root: URL
        let folder: URL
        let source: URL
        let sourceData: Data
        let settings: CapturePresetWatchRecordingSettings
        let context: RecordingOnlyFileExportContext
    }
}
