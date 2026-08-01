import Foundation
import XCTest
@testable import VoxboardShared

final class SpeakerDiarizationTests: XCTestCase {
    func testTimestampCoverageRejectsPartialRecognizedText() {
        XCTAssertTrue(SpeakerDiarizationAttribution.hasCompleteTimestampCoverage(
            transcriptText: "Hello, world!",
            transcriptionSegments: [
                TimedTranscriptionSegment(text: "Hello", startTime: 0, endTime: 0.5),
                TimedTranscriptionSegment(text: "world", startTime: 0.5, endTime: 1),
            ]
        ))
        XCTAssertFalse(SpeakerDiarizationAttribution.hasCompleteTimestampCoverage(
            transcriptText: "Hello, missing world!",
            transcriptionSegments: [
                TimedTranscriptionSegment(text: "Hello", startTime: 0, endTime: 0.5),
                TimedTranscriptionSegment(text: "world", startTime: 0.5, endTime: 1),
            ]
        ))
    }

    func testAttributionUsesOverlapAndGroupsContiguousTurns() {
        let words = [
            TimedTranscriptionSegment(text: "Hello", startTime: 0.1, endTime: 0.5),
            TimedTranscriptionSegment(text: "there", startTime: 0.5, endTime: 0.9),
            TimedTranscriptionSegment(text: "Hi", startTime: 1.2, endTime: 1.5),
            TimedTranscriptionSegment(text: "back.", startTime: 1.5, endTime: 1.9),
        ]
        let speakers = [
            SpeakerDiarizationSegment(speakerID: "voice-a", startTime: 0, endTime: 1),
            SpeakerDiarizationSegment(speakerID: "voice-b", startTime: 1.1, endTime: 2),
        ]

        let turns = SpeakerDiarizationAttribution.turns(
            transcriptionSegments: words,
            speakerSegments: speakers
        )

        XCTAssertEqual(turns.map(\.speaker), [0, 1])
        XCTAssertEqual(turns.map(\.text), ["Hello there", "Hi back."])
        XCTAssertEqual(turns.first?.speakerLabel, "Speaker 1")
        XCTAssertEqual(SpeakerDiarizationOutput(turns: turns).renderedText, """
        Speaker 1:
        Hello there

        Speaker 2:
        Hi back.
        """)
    }

    func testAttributionUsesNearestSpeakerWhenAWordFallsInAGap() {
        let turns = SpeakerDiarizationAttribution.turns(
            transcriptionSegments: [
                TimedTranscriptionSegment(text: "first", startTime: 0.4, endTime: 0.7),
                TimedTranscriptionSegment(text: "near second", startTime: 2.7, endTime: 2.9),
            ],
            speakerSegments: [
                SpeakerDiarizationSegment(speakerID: "first", startTime: 0, endTime: 1),
                SpeakerDiarizationSegment(speakerID: "second", startTime: 3, endTime: 4),
            ]
        )

        XCTAssertEqual(turns.map(\.speaker), [0, 1])
        XCTAssertEqual(turns.map(\.text), ["first", "near second"])
    }

    func testTranscriptPreservesTurnsThroughEnrichmentAndClearsThemAfterRawEdit() throws {
        let turns = [
            TranscriptSpeakerTurn(
                speaker: 0,
                text: "Hello",
                startTime: 0,
                endTime: 1
            )
        ]
        let transcript = Transcript(
            id: UUID(),
            text: "Speaker 1:\nHello",
            date: Date(),
            duration: 1,
            modelUsed: "Test",
            language: "en",
            speakerTurns: turns
        )

        XCTAssertEqual(transcript.speakerCount, 1)
        XCTAssertEqual(
            transcript.withEnrichment(
                title: "Greeting",
                tags: nil,
                category: nil,
                cleanedText: transcript.text
            ).speakerTurns,
            turns
        )
        XCTAssertNil(
            transcript.withEdits(
                text: "Edited",
                title: nil,
                tags: nil,
                category: nil,
                cleanedText: nil
            ).speakerTurns
        )

        let encoded = try JSONEncoder().encode(transcript)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "speakerTurns")
        let legacy = try JSONDecoder().decode(
            Transcript.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(legacy.speakerTurns)
        XCTAssertEqual(legacy.speakerCount, 0)
    }
}
