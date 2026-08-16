import AVFoundation
import XCTest
@testable import VoxboardShared

/// Guards against probing arbitrary files with `AVAudioFile`: malformed data
/// reaches Apple audio stacks (ExtAudioFile/FFR) whose teardown paths can
/// crash the process on some runtimes. `duration(of:)` must reject obvious
/// non-audio bytes before any audio framework is invoked.
final class AudioContainerHeaderSniffTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioContainerSniffTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    private func write(_ bytes: [UInt8], name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func test_rejectsGarbageBytes() throws {
        // The orphan-recovery fixture shape: repeated filler bytes.
        let url = try write([UInt8](repeating: 3, count: 32), name: "garbage.m4a")
        XCTAssertFalse(AudioFileConverter.hasAudioContainerHeader(url))
        XCTAssertNil(AudioFileConverter.duration(of: url))
    }

    func test_rejectsSequentialBytesThatResembleNoContainer() throws {
        // The Watch pipeline test fixture shape: 0x00, 0x01, 0x02, ...
        let url = try write(Array(0..<12).map { UInt8($0) }, name: "sequential.m4a")
        XCTAssertFalse(AudioFileConverter.hasAudioContainerHeader(url))
    }

    func test_rejectsShortFiles() throws {
        let url = try write([UInt8](repeating: 0, count: 4), name: "short.m4a")
        XCTAssertFalse(AudioFileConverter.hasAudioContainerHeader(url))
    }

    func test_acceptsMP4FamilyHeader() throws {
        // size (4 bytes) + "ftyp" brand box.
        let url = try write(
            [0x00, 0x00, 0x00, 0x20] + Array("ftypM4A ".utf8),
            name: "clip.m4a"
        )
        XCTAssertTrue(AudioFileConverter.hasAudioContainerHeader(url))
    }

    func test_acceptsLegacyContainerMagic() throws {
        for (magic, name) in [
            ("caff", "a.caf"),
            ("RIFF", "a.wav"),
            ("FORM", "a.aiff"),
            ("OggS", "a.ogg"),
            ("fLaC", "a.flac"),
            ("ID3", "a.mp3"),
        ] {
            let url = try write(Array(magic.utf8) + [UInt8](repeating: 0, count: 12 - magic.utf8.count), name: name)
            XCTAssertTrue(
                AudioFileConverter.hasAudioContainerHeader(url),
                "expected \(name) to pass the header sniff"
            )
        }
    }

    func test_acceptsBareMP3SyncWord() throws {
        let url = try write([0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 0, count: 8), name: "bare.mp3")
        XCTAssertTrue(AudioFileConverter.hasAudioContainerHeader(url))
    }

    func test_missingFileIsRejectedWithoutOpening() {
        let missing = root.appendingPathComponent("does-not-exist.m4a")
        XCTAssertFalse(AudioFileConverter.hasAudioContainerHeader(missing))
        XCTAssertNil(AudioFileConverter.duration(of: missing))
    }

    func test_realAudioFileStillReportsDuration() throws {
        // Generate a real file through the production writer so the sniff
        // must let it through to AVAudioFile. The writer is scoped to a
        // helper so its deinit flushes and closes before duration probing.
        let url = root.appendingPathComponent("real.m4a")
        try writeRealAudioFile(at: url)

        XCTAssertEqual(AudioFileConverter.duration(of: url) ?? 0, 1.0, accuracy: 0.01)
    }

    private func writeRealAudioFile(at url: URL) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        try file.write(from: buffer)
    }
}
