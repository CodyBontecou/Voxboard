import XCTest
@testable import VoxboardShared

final class TranscriptFileExporterTests: XCTestCase {

    private var tempFolder: URL!

    override func setUp() {
        super.setUp()
        tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoxboardTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempFolder)
        super.tearDown()
    }

    // MARK: - TXT New File

    func test_export_txt_newFile_createsFileWithTranscriptText() throws {
        let transcript = Transcript(text: "Hello world", duration: 5.0, modelUsed: "base", language: "en")

        let url = try TranscriptFileExporter.export(transcript, format: .txt, mode: .newFile, folderURL: tempFolder)

        XCTAssertTrue(url.lastPathComponent.hasPrefix("voxboard-"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".txt"))
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("Hello world"))
    }

    func test_export_txt_newFile_createsUniqueFilesPerCall() throws {
        let t1 = Transcript(text: "First", duration: 3.0, modelUsed: "base", language: "en")
        let t2 = Transcript(text: "Second", duration: 4.0, modelUsed: "base", language: "en")

        let url1 = try TranscriptFileExporter.export(t1, format: .txt, mode: .newFile, folderURL: tempFolder)
        let url2 = try TranscriptFileExporter.export(t2, format: .txt, mode: .newFile, folderURL: tempFolder)

        XCTAssertNotEqual(url1, url2)
    }

    // MARK: - TXT Append

    func test_export_txt_append_appendsToExistingFile() throws {
        let t1 = Transcript(text: "First", duration: 3.0, modelUsed: "base", language: "en")
        let t2 = Transcript(text: "Second", duration: 4.0, modelUsed: "base", language: "en")

        let url1 = try TranscriptFileExporter.export(t1, format: .txt, mode: .append, folderURL: tempFolder)
        let url2 = try TranscriptFileExporter.export(t2, format: .txt, mode: .append, folderURL: tempFolder)

        XCTAssertEqual(url1, url2, "Append mode should write to the same file")
        let content = try String(contentsOf: url1, encoding: .utf8)
        XCTAssertTrue(content.contains("First"))
        XCTAssertTrue(content.contains("Second"))
        XCTAssertTrue(content.contains("---"), "Entries should be separated by ---")
    }

    func test_export_txt_append_createsFileIfMissing() throws {
        let transcript = Transcript(text: "Solo entry", duration: 2.0, modelUsed: "base", language: "en")

        let url = try TranscriptFileExporter.export(transcript, format: .txt, mode: .append, folderURL: tempFolder)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("Solo entry"))
        XCTAssertFalse(content.contains("---"), "Single entry should have no separator")
    }

    // MARK: - MD New File

    func test_export_md_newFile_includesMetadataHeader() throws {
        let transcript = Transcript(text: "Hello markdown", duration: 45.0, modelUsed: "ggml-base", language: "en")

        let url = try TranscriptFileExporter.export(transcript, format: .md, mode: .newFile, folderURL: tempFolder)

        XCTAssertTrue(url.lastPathComponent.hasSuffix(".md"))
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("## Transcript"), "Should have markdown heading")
        XCTAssertTrue(content.contains("Duration"), "Should include duration metadata")
        XCTAssertTrue(content.contains("ggml-base"), "Should include model name")
        XCTAssertTrue(content.contains("Hello markdown"), "Should include transcript text")
    }

    // MARK: - MD Append

    func test_export_md_append_separatesEntries() throws {
        let t1 = Transcript(text: "First MD", duration: 10.0, modelUsed: "base", language: "en")
        let t2 = Transcript(text: "Second MD", duration: 20.0, modelUsed: "base", language: "en")

        try TranscriptFileExporter.export(t1, format: .md, mode: .append, folderURL: tempFolder)
        let url = try TranscriptFileExporter.export(t2, format: .md, mode: .append, folderURL: tempFolder)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("First MD"))
        XCTAssertTrue(content.contains("Second MD"))
        XCTAssertTrue(content.contains("---"))
    }

    // MARK: - JSON New File

    func test_export_json_newFile_isDecodableTranscript() throws {
        let transcript = Transcript(text: "JSON test", duration: 10.0, modelUsed: "base", language: "en")

        let url = try TranscriptFileExporter.export(transcript, format: .json, mode: .newFile, folderURL: tempFolder)

        XCTAssertTrue(url.lastPathComponent.hasSuffix(".json"))
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)
        XCTAssertEqual(decoded.text, "JSON test")
        XCTAssertEqual(decoded.duration, 10.0)
        XCTAssertEqual(decoded.modelUsed, "base")
    }

    // MARK: - JSON Append

    func test_export_json_append_producesValidArray() throws {
        let t1 = Transcript(text: "First JSON", duration: 5.0, modelUsed: "base", language: "en")
        let t2 = Transcript(text: "Second JSON", duration: 8.0, modelUsed: "base", language: "en")

        try TranscriptFileExporter.export(t1, format: .json, mode: .append, folderURL: tempFolder)
        let url = try TranscriptFileExporter.export(t2, format: .json, mode: .append, folderURL: tempFolder)

        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([Transcript].self, from: data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].text, "First JSON")
        XCTAssertEqual(decoded[1].text, "Second JSON")
    }

    func test_export_json_append_createsArrayFromSingleEntry() throws {
        let transcript = Transcript(text: "Solo JSON", duration: 3.0, modelUsed: "base", language: "en")

        let url = try TranscriptFileExporter.export(transcript, format: .json, mode: .append, folderURL: tempFolder)

        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([Transcript].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].text, "Solo JSON")
    }

    // MARK: - YAML

    func test_export_yaml_newFile_includesSelectedProperties() throws {
        let transcript = Transcript(text: "YAML text", duration: 9.25, modelUsed: "base", language: "en")

        let url = try TranscriptFileExporter.export(
            transcript,
            format: .yaml,
            mode: .newFile,
            folderURL: tempFolder,
            yamlProperties: [.text, .duration]
        )

        XCTAssertTrue(url.lastPathComponent.hasSuffix(".yaml"))
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("text: |-"))
        XCTAssertTrue(content.contains("YAML text"))
        XCTAssertTrue(content.contains("duration_seconds: 9.250"))
        XCTAssertFalse(content.contains("model_used:"))
        XCTAssertFalse(content.contains("language:"))
    }

    func test_export_yaml_append_separatesEntries() throws {
        let t1 = Transcript(text: "First YAML", duration: 2.0, modelUsed: "base", language: "en")
        let t2 = Transcript(text: "Second YAML", duration: 4.0, modelUsed: "small", language: "fr")

        try TranscriptFileExporter.export(t1, format: .yaml, mode: .append, folderURL: tempFolder)
        let url = try TranscriptFileExporter.export(t2, format: .yaml, mode: .append, folderURL: tempFolder)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("First YAML"))
        XCTAssertTrue(content.contains("Second YAML"))
        XCTAssertTrue(content.contains("---"))
    }

    // MARK: - exportIfEnabled

    func test_exportIfEnabled_doesNothing_whenDisabled() {
        let suiteName = "test.export.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(false, forKey: AppConstants.fileExportEnabledKey)
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let transcript = Transcript(text: "Should not export", duration: 1.0, modelUsed: "base", language: "en")
        TranscriptFileExporter.exportIfEnabled(transcript, defaults: defaults)

        // Verify no files were created in temp folder
        let files = try? FileManager.default.contentsOfDirectory(at: tempFolder, includingPropertiesForKeys: nil)
        XCTAssertEqual(files?.count ?? 0, 0, "No file should be written when export is disabled")
    }

    func test_exportIfEnabled_doesNothing_whenNoBookmark() {
        let suiteName = "test.export.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: AppConstants.fileExportEnabledKey)
        defaults.set("txt", forKey: AppConstants.fileExportFormatKey)
        defaults.set("newFile", forKey: AppConstants.fileExportModeKey)
        // No bookmark set
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let transcript = Transcript(text: "No bookmark", duration: 1.0, modelUsed: "base", language: "en")
        TranscriptFileExporter.exportIfEnabled(transcript, defaults: defaults)

        let files = try? FileManager.default.contentsOfDirectory(at: tempFolder, includingPropertiesForKeys: nil)
        XCTAssertEqual(files?.count ?? 0, 0, "No file should be written when no bookmark is set")
    }

    func test_exportIfEnabled_writesFile_whenEnabledWithFolder() throws {
        let suiteName = "test.export.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: AppConstants.fileExportEnabledKey)
        defaults.set("txt", forKey: AppConstants.fileExportFormatKey)
        defaults.set("newFile", forKey: AppConstants.fileExportModeKey)
        // Store bookmark for our temp folder (non-security-scoped since it's our own directory)
        let bookmark = try tempFolder.bookmarkData()
        defaults.set(bookmark, forKey: AppConstants.fileExportBookmarkKey)
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let transcript = Transcript(text: "Should export", duration: 5.0, modelUsed: "base", language: "en")
        TranscriptFileExporter.exportIfEnabled(transcript, defaults: defaults)

        let files = try FileManager.default.contentsOfDirectory(at: tempFolder, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1, "One file should be written")
        let content = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(content.contains("Should export"))
    }

    func test_exportIfEnabled_yamlRespectsConfiguredPropertyList() throws {
        let suiteName = "test.export.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: AppConstants.fileExportEnabledKey)
        defaults.set("yaml", forKey: AppConstants.fileExportFormatKey)
        defaults.set("newFile", forKey: AppConstants.fileExportModeKey)
        defaults.set([ExportYAMLProperty.text.rawValue], forKey: AppConstants.fileExportYAMLPropertiesKey)
        let bookmark = try tempFolder.bookmarkData()
        defaults.set(bookmark, forKey: AppConstants.fileExportBookmarkKey)
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let transcript = Transcript(text: "YAML only text", duration: 7.0, modelUsed: "large", language: "de")
        TranscriptFileExporter.exportIfEnabled(transcript, defaults: defaults)

        let files = try FileManager.default.contentsOfDirectory(at: tempFolder, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let content = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(content.contains("text: |-"))
        XCTAssertTrue(content.contains("YAML only text"))
        XCTAssertFalse(content.contains("duration_seconds"))
        XCTAssertFalse(content.contains("model_used"))
        XCTAssertFalse(content.contains("language:"))
    }
}
