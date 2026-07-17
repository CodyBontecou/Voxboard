import XCTest
@testable import VoxboardShared

final class TranscriptHistoryTests: XCTestCase {
    func test_searchMatchesRawCleanedTitleTagsCategoryAndDiacritics() {
        let transcript = Transcript(
            text: "raw microphone words",
            duration: 2,
            modelUsed: "base",
            language: "fr"
        ).withEnrichment(
            title: "Résumé de réunion",
            tags: ["Client", "Launch"],
            category: "Meeting",
            cleanedText: "Discussed the shipping plan."
        )

        for query in ["microphone", "shipping", "resume", "client", "meeting", "réunion launch"] {
            XCTAssertTrue(TranscriptSearch.matches(transcript, query: query), "Expected query to match: \(query)")
        }
        XCTAssertFalse(TranscriptSearch.matches(transcript, query: "invoice"))
    }

    func test_withEditsPreservesIdentityAndVoiceMetadata() {
        let original = Transcript(text: "raw", duration: 42, modelUsed: "parakeet", language: "en")
        let edited = original.withEdits(
            text: "corrected raw",
            title: "Edited",
            tags: ["reviewed"],
            category: "note",
            cleanedText: "Corrected."
        )

        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.date, original.date)
        XCTAssertEqual(edited.duration, 42)
        XCTAssertEqual(edited.modelUsed, "parakeet")
        XCTAssertEqual(edited.language, "en")
        XCTAssertEqual(edited.text, "corrected raw")
        XCTAssertEqual(edited.cleanedText, "Corrected.")
    }

    func test_storeMergesLatestDiskVersionAcrossInstances() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("transcripts.json")
        let firstStore = TranscriptStore(fileURL: url)
        let secondStore = TranscriptStore(fileURL: url)
        let first = Transcript(text: "First", duration: 1, modelUsed: "base", language: "en")
        let second = Transcript(text: "Second", duration: 1, modelUsed: "base", language: "en")

        firstStore.add(first)
        secondStore.add(second)
        firstStore.reload()

        XCTAssertEqual(Set(firstStore.transcripts.map(\.id)), Set([first.id, second.id]))
    }

    func test_deleteByIDsIsSafeForFilteredLists() {
        let store = TranscriptStore(fileURL: nil)
        let first = Transcript(text: "First", duration: 1, modelUsed: "base", language: "en")
        let second = Transcript(text: "Second", duration: 1, modelUsed: "base", language: "en")
        let third = Transcript(text: "Third", duration: 1, modelUsed: "base", language: "en")
        store.add(first)
        store.add(second)
        store.add(third)

        store.delete(ids: [second.id])

        XCTAssertEqual(store.transcripts.map(\.id), [third.id, first.id])
    }

    func test_saveFailureIsPublishedToCallerState() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let invalidFileURL = folder.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: invalidFileURL, withIntermediateDirectories: true)
        let store = TranscriptStore(fileURL: invalidFileURL)

        store.add(Transcript(text: "Cannot persist", duration: 1, modelUsed: "base", language: "en"))

        XCTAssertNotNil(store.lastPersistenceError)
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
