import XCTest
@testable import VoxboardCaptureCore

final class CaptureDraftRecordingReceiptTests: XCTestCase {
    func testRecordingReceiptsRoundTrip() throws {
        let audioID = UUID()
        let transcriptID = UUID()
        let asset = try CaptureAssetReference(
            relativePath: "recording.wav",
            originalFilename: "recording.wav",
            contentTypeIdentifier: "public.wav",
            byteCount: 42
        )
        let draft = CaptureDraft(
            stagedRecordingAudioReceipts: [audioID.uuidString.lowercased(): asset],
            appliedRecordingTranscriptIDs: [transcriptID]
        )

        let decoded = try JSONDecoder().decode(
            CaptureDraft.self,
            from: JSONEncoder().encode(draft)
        )

        XCTAssertEqual(
            decoded.stagedRecordingAudioReceipts,
            [audioID.uuidString.lowercased(): asset]
        )
        XCTAssertEqual(decoded.appliedRecordingTranscriptIDs, [transcriptID])
    }

    func testLegacyDraftWithoutRecordingReceiptsStillDecodes() throws {
        let data = try JSONEncoder().encode(CaptureDraft(text: "Legacy"))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "stagedRecordingAudioReceipts")
        object.removeValue(forKey: "appliedRecordingTranscriptIDs")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(CaptureDraft.self, from: legacyData)

        XCTAssertEqual(decoded.text, "Legacy")
        XCTAssertNil(decoded.stagedRecordingAudioReceipts)
        XCTAssertNil(decoded.appliedRecordingTranscriptIDs)
    }
}
