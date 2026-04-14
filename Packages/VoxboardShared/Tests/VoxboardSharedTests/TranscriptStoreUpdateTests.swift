import XCTest
@testable import VoxboardShared

final class TranscriptStoreUpdateTests: XCTestCase {

    // These tests exercise the in-memory behavior of TranscriptStore.update(_:).
    // TranscriptStore's on-disk persistence goes through AppConstants.sharedContainerURL,
    // which is nil in the unit-test host — so save() is a silent no-op here and we only
    // assert on the `transcripts` array.

    func test_update_replacesTranscriptWithMatchingId() {
        let store = TranscriptStore()
        let original = Transcript(
            text: "hello",
            duration: 1.0,
            modelUsed: "whisper-base",
            language: "en"
        )
        store.add(original)

        let enriched = original.withEnrichment(
            title: "Greeting",
            tags: ["hello"],
            category: "note",
            cleanedText: "Hello."
        )

        store.update(enriched)

        XCTAssertEqual(store.transcripts.count, 1)
        XCTAssertEqual(store.transcripts[0].id, original.id)
        XCTAssertEqual(store.transcripts[0].title, "Greeting")
        XCTAssertEqual(store.transcripts[0].cleanedText, "Hello.")
    }

    func test_update_preservesOrderingWhenReplacing() {
        let store = TranscriptStore()
        let first = Transcript(text: "first", duration: 1.0, modelUsed: "m", language: "en")
        let second = Transcript(text: "second", duration: 1.0, modelUsed: "m", language: "en")
        let third = Transcript(text: "third", duration: 1.0, modelUsed: "m", language: "en")
        store.add(first)
        store.add(second)
        store.add(third)
        // insertion is at index 0, so order is [third, second, first]

        let enrichedSecond = second.withEnrichment(
            title: "Second",
            tags: nil,
            category: nil,
            cleanedText: nil
        )
        store.update(enrichedSecond)

        XCTAssertEqual(store.transcripts.count, 3)
        XCTAssertEqual(store.transcripts[0].id, third.id)
        XCTAssertEqual(store.transcripts[1].id, second.id)
        XCTAssertEqual(store.transcripts[1].title, "Second")
        XCTAssertEqual(store.transcripts[2].id, first.id)
    }

    func test_update_isNoOpForUnknownId() {
        let store = TranscriptStore()
        let saved = Transcript(text: "hi", duration: 1.0, modelUsed: "m", language: "en")
        store.add(saved)

        let stranger = Transcript(text: "stranger", duration: 1.0, modelUsed: "m", language: "en")
            .withEnrichment(title: "X", tags: nil, category: nil, cleanedText: nil)

        store.update(stranger)

        XCTAssertEqual(store.transcripts.count, 1)
        XCTAssertEqual(store.transcripts[0].id, saved.id)
        XCTAssertNil(store.transcripts[0].title)
    }
}
