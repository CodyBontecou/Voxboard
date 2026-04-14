import XCTest
@testable import VoxboardShared

final class TranscriptEnrichmentTests: XCTestCase {

    // MARK: - Defaults

    func test_newTranscript_hasNilEnrichmentFields() {
        let t = Transcript(
            text: "hello world",
            duration: 1.0,
            modelUsed: "whisper-base",
            language: "en"
        )
        XCTAssertNil(t.title)
        XCTAssertNil(t.tags)
        XCTAssertNil(t.category)
        XCTAssertNil(t.cleanedText)
    }

    // MARK: - withEnrichment

    func test_withEnrichment_returnsCopyWithFieldsSet() {
        let original = Transcript(
            text: "raw hello world",
            duration: 2.5,
            modelUsed: "whisper-base",
            language: "en"
        )

        let enriched = original.withEnrichment(
            title: "Greeting",
            tags: ["hello", "casual"],
            category: "note",
            cleanedText: "Hello, world."
        )

        // Enrichment fields updated
        XCTAssertEqual(enriched.title, "Greeting")
        XCTAssertEqual(enriched.tags, ["hello", "casual"])
        XCTAssertEqual(enriched.category, "note")
        XCTAssertEqual(enriched.cleanedText, "Hello, world.")

        // Identity + immutable fields preserved
        XCTAssertEqual(enriched.id, original.id)
        XCTAssertEqual(enriched.text, original.text)
        XCTAssertEqual(enriched.date, original.date)
        XCTAssertEqual(enriched.duration, original.duration)
        XCTAssertEqual(enriched.modelUsed, original.modelUsed)
        XCTAssertEqual(enriched.language, original.language)
    }

    func test_withEnrichment_doesNotMutateOriginal() {
        let original = Transcript(
            text: "hi",
            duration: 1.0,
            modelUsed: "whisper-base",
            language: "en"
        )

        _ = original.withEnrichment(
            title: "Greeting",
            tags: ["hi"],
            category: "note",
            cleanedText: "Hi."
        )

        XCTAssertNil(original.title)
        XCTAssertNil(original.tags)
        XCTAssertNil(original.category)
        XCTAssertNil(original.cleanedText)
    }

    // MARK: - Backward-compat JSON decoding

    func test_legacyJSON_withoutEnrichmentFields_decodesWithNils() throws {
        let legacyJSON = #"""
        {
          "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
          "text": "hello",
          "date": 770000000.0,
          "duration": 1.5,
          "modelUsed": "whisper-base",
          "language": "en"
        }
        """#.data(using: .utf8)!

        let t = try JSONDecoder().decode(Transcript.self, from: legacyJSON)

        XCTAssertEqual(t.text, "hello")
        XCTAssertEqual(t.modelUsed, "whisper-base")
        XCTAssertNil(t.title)
        XCTAssertNil(t.tags)
        XCTAssertNil(t.category)
        XCTAssertNil(t.cleanedText)
    }

    func test_enrichedTranscript_roundTripsThroughCodable() throws {
        let t = Transcript(
            text: "raw hi",
            duration: 1.0,
            modelUsed: "whisper-base",
            language: "en"
        ).withEnrichment(
            title: "Greeting",
            tags: ["a", "b"],
            category: "note",
            cleanedText: "Hi."
        )

        let data = try JSONEncoder().encode(t)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)

        XCTAssertEqual(decoded.id, t.id)
        XCTAssertEqual(decoded.text, "raw hi")
        XCTAssertEqual(decoded.title, "Greeting")
        XCTAssertEqual(decoded.tags, ["a", "b"])
        XCTAssertEqual(decoded.category, "note")
        XCTAssertEqual(decoded.cleanedText, "Hi.")
    }

    func test_partiallyEnrichedTranscript_roundTripsThroughCodable() throws {
        // Enricher may return only some fields (e.g., LLM produced title but no tags)
        let t = Transcript(
            text: "hi",
            duration: 1.0,
            modelUsed: "whisper-base",
            language: "en"
        ).withEnrichment(
            title: "Greeting",
            tags: nil,
            category: nil,
            cleanedText: nil
        )

        let data = try JSONEncoder().encode(t)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)

        XCTAssertEqual(decoded.title, "Greeting")
        XCTAssertNil(decoded.tags)
        XCTAssertNil(decoded.category)
        XCTAssertNil(decoded.cleanedText)
    }
}
