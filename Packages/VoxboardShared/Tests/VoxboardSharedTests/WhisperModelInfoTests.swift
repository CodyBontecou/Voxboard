import XCTest
@testable import VoxboardShared

final class WhisperModelInfoTests: XCTestCase {

    func test_parakeetFolderNames_matchFluidAudioCacheLayout() {
        XCTAssertEqual(ModelEngine.parakeetV2.parakeetRepoFolderName, "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(ModelEngine.parakeetV3.parakeetRepoFolderName, "parakeet-tdt-0.6b-v3")
    }

    func test_parakeetModelFileNames_useLocalCacheFolders() throws {
        let parakeetV2 = try XCTUnwrap(WhisperModelInfo.availableModels.first { $0.id == "parakeet-v2" })
        let parakeetV3 = try XCTUnwrap(WhisperModelInfo.availableModels.first { $0.id == "parakeet-v3" })

        XCTAssertEqual(parakeetV2.fileName, parakeetV2.engine.parakeetRepoFolderName)
        XCTAssertEqual(parakeetV3.fileName, parakeetV3.engine.parakeetRepoFolderName)
    }

    func test_parakeetCompleteness_requiresVocabularyFile() {
        XCTAssertEqual(ModelEngine.parakeetVocabularyFile, "parakeet_vocab.json")
    }

    func test_allLocalModelsRequireExplicitDownload() {
        XCTAssertTrue(WhisperModelInfo.availableModels.allSatisfy { !$0.isBundled })
    }

    func test_whisperExternalInstallationRequiresTrustedByteCount() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("renamed-existing-model.bin")
        let model = testWhisperModel(expectedBytes: 4)

        try Data([0, 1, 2, 3]).write(to: file)
        XCTAssertTrue(model.isValidInstallation(at: file))

        try Data([0, 1, 2]).write(to: file)
        XCTAssertFalse(model.isValidInstallation(at: file))
        XCTAssertFalse(model.isValidInstallation(at: directory))
    }

    func test_parakeetExternalInstallationRequiresEveryTrustedArtifact() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try XCTUnwrap(
            WhisperModelInfo.availableModels.first { $0.id == "parakeet-v3" }
        )
        let expectedArtifacts = try XCTUnwrap(model.engine.parakeetExpectedArtifactSizes)

        for (relativePath, expectedByteCount) in expectedArtifacts {
            try createFixtureArtifact(
                at: directory.appendingPathComponent(relativePath),
                relativePath: relativePath,
                byteCount: expectedByteCount
            )
        }

        XCTAssertTrue(model.isValidInstallation(at: directory))
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(ModelEngine.parakeetVocabularyFile)
        )
        XCTAssertFalse(model.isValidInstallation(at: directory))
    }

    #if os(macOS)
    @MainActor
    func test_useExistingModelPersistsSelectionAcrossManagers() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try XCTUnwrap(
            WhisperModelInfo.availableModels.first { $0.id == "ggml-tiny" }
        )
        let file = directory.appendingPathComponent("existing-tiny.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(try XCTUnwrap(model.downloadSizeBytes)))
        XCTAssertFalse(model.isValidInstallation(at: file))
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: try XCTUnwrap(model.trustedFileHeader))
        try handle.close()
        XCTAssertTrue(model.isValidInstallation(at: file))

        let suiteName = "WhisperModelInfoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = ModelManager(defaults: defaults)
        XCTAssertTrue(manager.useExistingModel(model, at: file))
        XCTAssertEqual(manager.selectedModelId, model.id)
        XCTAssertEqual(manager.installationSource(for: model), .external)

        let relaunchedManager = ModelManager(defaults: defaults)
        XCTAssertEqual(relaunchedManager.selectedModelId, model.id)
        XCTAssertTrue(relaunchedManager.isModelDownloaded(model))
        XCTAssertEqual(relaunchedManager.installationSource(for: model), .external)
    }

    func test_externalInstallationTakesPrecedenceThenFallsBackToAppCopy() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appModelsDirectory = directory.appendingPathComponent("app-models", isDirectory: true)
        let externalFile = directory.appendingPathComponent("external-model.bin")
        try FileManager.default.createDirectory(
            at: appModelsDirectory,
            withIntermediateDirectories: true
        )
        let model = testWhisperModel(expectedBytes: 4)
        try Data([0, 1, 2, 3]).write(
            to: appModelsDirectory.appendingPathComponent(model.fileName)
        )
        try Data([3, 2, 1, 0]).write(to: externalFile)

        let suiteName = "WhisperModelInfoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let bookmark = try externalFile.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        ExternalModelBookmarkStore.save(
            bookmarkData: bookmark,
            for: model.id,
            defaults: defaults
        )

        var access = try XCTUnwrap(model.installedModelAccess(
            defaults: defaults,
            modelsDirectory: appModelsDirectory
        ))
        XCTAssertEqual(access.source, .external)
        XCTAssertEqual(access.url.standardizedFileURL, externalFile.standardizedFileURL)

        ExternalModelBookmarkStore.removeBookmark(for: model.id, defaults: defaults)
        access = try XCTUnwrap(model.installedModelAccess(
            defaults: defaults,
            modelsDirectory: appModelsDirectory
        ))
        XCTAssertEqual(access.source, .appManaged)
        XCTAssertEqual(
            access.url.standardizedFileURL,
            appModelsDirectory.appendingPathComponent(model.fileName).standardizedFileURL
        )
    }

    @MainActor
    func test_externalBookmarkIsResolvedAndDeleteOnlyForgetsReference() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shared-model.bin")
        try Data([0, 1, 2, 3]).write(to: file)

        let suiteName = "WhisperModelInfoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = testWhisperModel(expectedBytes: 4)
        let bookmark = try file.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        ExternalModelBookmarkStore.save(
            bookmarkData: bookmark,
            for: model.id,
            defaults: defaults
        )

        let manager = ModelManager(defaults: defaults)
        XCTAssertTrue(manager.isModelDownloaded(model))
        XCTAssertEqual(manager.installationSource(for: model), .external)

        XCTAssertTrue(manager.deleteModel(model))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(manager.hasExternalModelReference(model))
        XCTAssertFalse(manager.isModelDownloaded(model))
    }
    #endif

    private func testWhisperModel(expectedBytes: Int64) -> WhisperModelInfo {
        WhisperModelInfo(
            id: "test-whisper-\(UUID().uuidString)",
            name: "Test Whisper",
            fileName: "missing-app-managed-model.bin",
            sizeLabel: "4 bytes",
            downloadSizeBytes: expectedBytes,
            downloadURL: URL(string: "https://example.com/model.bin")!,
            isBundled: false
        )
    }

    private func createFixtureArtifact(
        at url: URL,
        relativePath: String,
        byteCount: Int64
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if URL(fileURLWithPath: relativePath).pathExtension.lowercased() == "json" {
            let json = relativePath.hasSuffix(ModelEngine.parakeetVocabularyFile)
                ? "{\"0\":\"fixture\"}"
                : "[{\"fixture\":true}]"
            var data = Data(json.utf8)
            data.append(Data(repeating: 0x20, count: Int(byteCount) - data.count))
            try data.write(to: url)
            return
        }

        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(byteCount))
        try handle.close()
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-model-info-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
