import XCTest
@testable import VoxboardShared

final class LiveActivityCommandBuilderTests: XCTestCase {

    func test_buildStartCommand_usesStartSegmentAction() {
        let cmd = LiveActivityCommandBuilder.buildStartCommand(
            requestId: "req-1",
            modelId: "whisper-base",
            language: "en",
            flowId: "meeting"
        )
        XCTAssertEqual(cmd.action, .startSegment)
        XCTAssertEqual(cmd.requestId, "req-1")
        XCTAssertEqual(cmd.modelId, "whisper-base")
        XCTAssertEqual(cmd.language, "en")
        XCTAssertEqual(cmd.flowId, "meeting")
    }

    func test_buildStopCommand_usesStopSegmentAction() {
        let cmd = LiveActivityCommandBuilder.buildStopCommand(requestId: "req-1")
        XCTAssertEqual(cmd.action, .stopSegment)
        XCTAssertEqual(cmd.requestId, "req-1")
        XCTAssertNil(cmd.modelId)
        XCTAssertNil(cmd.language)
    }

    func test_buildStartCommand_generatesUniqueRequestIdByDefault() {
        let a = LiveActivityCommandBuilder.buildStartCommand()
        let b = LiveActivityCommandBuilder.buildStartCommand()
        XCTAssertFalse(a.requestId.isEmpty)
        XCTAssertFalse(b.requestId.isEmpty)
        XCTAssertNotEqual(a.requestId, b.requestId)
    }

    func test_enqueue_writesCommandToProvidedURLAndNotifies() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vb-liveactivity-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var notified = false
        let cmd = RecordingCommand(requestId: "rid", action: .startSegment)

        LiveActivityCommandBuilder.enqueue(cmd, commandURL: tmp, notify: { notified = true })

        let data = try Data(contentsOf: tmp)
        let decoded = try JSONDecoder().decode(RecordingCommand.self, from: data)
        XCTAssertEqual(decoded.requestId, "rid")
        XCTAssertEqual(decoded.action, .startSegment)
        XCTAssertTrue(notified)
    }
}
