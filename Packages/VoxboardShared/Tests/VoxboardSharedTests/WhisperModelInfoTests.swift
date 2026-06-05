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
}
