import AVFoundation
import XCTest
@testable import VoxboardShared

final class MeetingCaptureTests: XCTestCase {
    func testMeetingAssemblerMapsLocalAndRemoteRolesOnSharedTimeline() {
        let turns = MeetingTranscriptAssembler.turns(from: [
            MeetingTimedText(source: .system, text: "Welcome", startTime: 0.5, endTime: 1.0, remoteSpeaker: 1),
            MeetingTimedText(source: .microphone, text: "Thanks", startTime: 0.2, endTime: 0.8),
        ])
        XCTAssertEqual(turns.map(\.text), ["Thanks", "Welcome"])
        XCTAssertEqual(turns.map(\.role), [.local, .remoteAnonymous])
        XCTAssertEqual(turns.first?.speakerLabel, "You")
        XCTAssertEqual(turns.last?.speakerLabel, "Speaker 3")
    }

    func testLegacySpeakerTurnDecodesWithoutRole() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","speaker":1,"text":"Hello","startTime":0,"endTime":1}"#.data(using: .utf8)!
        let turn = try JSONDecoder().decode(TranscriptSpeakerTurn.self, from: json)
        XCTAssertNil(turn.role)
        XCTAssertEqual(turn.speakerLabel, "Speaker 2")
    }

    func testNewSingleArtifactJobsRetainV1WireShape() throws {
        let job = RecordingJob(
            audioFilename: "single.wav",
            duration: 1,
            source: .macApp,
            delivery: .clipboard,
            modelID: "model",
            language: "en",
            retentionPolicy: .permanent,
            processingPolicy: .manual
        )
        XCTAssertEqual(job.schemaVersion, 1)
        XCTAssertNil(job.artifacts)
        XCTAssertEqual(job.resolvedArtifacts, [
            RecordingArtifact(role: .primaryAudio, filename: "single.wav"),
        ])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
        XCTAssertNil(object["artifacts"])
    }

    func testLegacyV1RecordingJobResolvesPrimaryArtifact() throws {
        let job = RecordingJob(
            audioFilename: "legacy.wav", duration: 1, source: .macApp, delivery: .clipboard,
            modelID: "model", language: "en", retentionPolicy: .permanent, processingPolicy: .manual
        )
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
        object["schemaVersion"] = 1
        object.removeValue(forKey: "artifacts")
        let decoded = try JSONDecoder().decode(RecordingJob.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.resolvedArtifacts, [RecordingArtifact(role: .primaryAudio, filename: "legacy.wav")])
    }

    func testSchemaV2RejectsMissingDuplicateAndUnsafeArtifacts() throws {
        let job = RecordingJob(
            audioFilename: "primary.wav",
            artifacts: [RecordingArtifact(role: .meetingSystem, filename: "primary.wav")],
            duration: 1, source: .macApp, delivery: .clipboard, modelID: "m", language: "en",
            retentionPolicy: .permanent, processingPolicy: .manual
        )
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
        for artifacts in [
            nil,
            [["role": "meetingSystem", "filename": "primary.wav"], ["role": "meetingSystem", "filename": "two.wav"]],
            [["role": "meetingSystem", "filename": "../primary.wav"]],
        ] as [Any?] {
            if let artifacts { object["artifacts"] = artifacts } else { object.removeValue(forKey: "artifacts") }
            XCTAssertThrowsError(try JSONDecoder().decode(RecordingJob.self, from: JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testBundleEnqueueCopiesAllArtifactsAndDiscardRemovesAll() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let mic = source.appendingPathComponent("mic.wav")
        let system = source.appendingPathComponent("system.wav")
        try Data([1, 2, 3]).write(to: mic); try Data([4, 5, 6]).write(to: system)
        let store = RecordingJobStore(rootDirectoryURL: root.appendingPathComponent("queue"))
        let job = try await store.enqueueBundle(
            sources: [(.meetingMicrophone, mic), (.meetingSystem, system)], duration: 1,
            source: .macApp, delivery: .clipboard, modelID: "m", language: "en",
            configuration: .init(sourceAudioRetention: .permanent, processingPolicy: .manual)
        )
        XCTAssertEqual(job.resolvedArtifacts.map(\.role), [.meetingMicrophone, .meetingSystem])
        XCTAssertTrue(store.artifactURLs(for: job).allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        _ = try await store.discard(id: job.id)
        XCTAssertTrue(store.artifactURLs(for: job).allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        try? FileManager.default.removeItem(at: root)
    }

    func testBundleEnqueueIsAtomicWhenOneSourceIsMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let valid = root.appendingPathComponent("valid.wav"); try Data([1]).write(to: valid)
        let store = RecordingJobStore(rootDirectoryURL: root.appendingPathComponent("queue"))
        do {
            _ = try await store.enqueueBundle(
                sources: [(.meetingMicrophone, valid), (.meetingSystem, root.appendingPathComponent("missing.wav"))],
                duration: 1, source: .macApp, delivery: .clipboard, modelID: "m", language: "en",
                configuration: .init(processingPolicy: .manual)
            )
            XCTFail("Expected missing source")
        } catch { }
        let jobs = try await store.load()
        XCTAssertTrue(jobs.isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    func testInterruptedBundleCommitIsRecoveredBeforeGenericOrphanImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queueRoot = root.appendingPathComponent("queue", isDirectory: true)
        let audioDirectory = queueRoot.appendingPathComponent("audio", isDirectory: true)
        let intentDirectory = queueRoot.appendingPathComponent("bundle-intents", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        for directory in [audioDirectory, intentDirectory, sourceDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        let micSource = sourceDirectory.appendingPathComponent("microphone.wav")
        let systemSource = sourceDirectory.appendingPathComponent("system.wav")
        let micData = Data([1, 2, 3, 4])
        let systemData = Data([5, 6, 7])
        try micData.write(to: micSource)
        try systemData.write(to: systemSource)
        let micFilename = "\(id.uuidString.lowercased())-meetingMicrophone.wav"
        let systemFilename = "\(id.uuidString.lowercased())-meetingSystem.wav"
        let artifacts = [
            RecordingArtifact(role: .meetingMicrophone, filename: micFilename, originalFilename: micSource.lastPathComponent),
            RecordingArtifact(role: .meetingSystem, filename: systemFilename, originalFilename: systemSource.lastPathComponent),
        ]
        let job = RecordingJob(
            id: id,
            audioFilename: systemFilename,
            artifacts: artifacts,
            originalFilename: systemSource.lastPathComponent,
            duration: 1,
            source: .macApp,
            delivery: .clipboard,
            modelID: "model",
            language: "en",
            retentionPolicy: .permanent,
            processingPolicy: .manual
        )
        let intent = RecordingBundleEnqueueIntent(
            job: job,
            sources: [
                .init(role: .meetingMicrophone, sourcePath: micSource.path, expectedByteCount: Int64(micData.count), filename: micFilename, originalFilename: micSource.lastPathComponent),
                .init(role: .meetingSystem, sourcePath: systemSource.path, expectedByteCount: Int64(systemData.count), filename: systemFilename, originalFilename: systemSource.lastPathComponent),
            ],
            removeSourcesAfterCommit: true
        )

        // Simulate termination after the first final artifact move but before
        // the schema-v2 job manifest is persisted.
        try micData.write(to: audioDirectory.appendingPathComponent(micFilename))
        try JSONEncoder().encode(intent).write(
            to: intentDirectory.appendingPathComponent("\(id.uuidString.lowercased()).json"),
            options: .atomic
        )

        let store = RecordingJobStore(rootDirectoryURL: queueRoot)
        let recovered = try await store.load(recoverInterrupted: false)
        XCTAssertEqual(recovered, [job])
        XCTAssertEqual(recovered.first?.schemaVersion, 2)
        XCTAssertEqual(recovered.first?.resolvedArtifacts.map(\.role), [.meetingMicrophone, .meetingSystem])
        XCTAssertTrue(store.artifactURLs(for: job).allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: micSource.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemSource.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: intentDirectory.appendingPathComponent("\(id.uuidString.lowercased()).json").path
        ))
    }

    func testPendingBundleIntentProtectsMembersFromV1OrphanRecoveryUntilRetrySucceeds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queueRoot = root.appendingPathComponent("queue", isDirectory: true)
        let audioDirectory = queueRoot.appendingPathComponent("audio", isDirectory: true)
        let intentDirectory = queueRoot.appendingPathComponent("bundle-intents", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        for directory in [audioDirectory, intentDirectory, sourceDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        let sourceURL = sourceDirectory.appendingPathComponent("late-system.wav")
        let filename = "\(id.uuidString.lowercased())-meetingSystem.wav"
        let bytes = Data([8, 9, 10])
        let artifact = RecordingArtifact(role: .meetingSystem, filename: filename, originalFilename: sourceURL.lastPathComponent)
        let job = RecordingJob(
            id: id,
            audioFilename: filename,
            artifacts: [artifact],
            originalFilename: sourceURL.lastPathComponent,
            duration: 1,
            source: .macApp,
            delivery: .clipboard,
            modelID: "model",
            language: "en",
            retentionPolicy: .permanent,
            processingPolicy: .manual
        )
        let intent = RecordingBundleEnqueueIntent(
            job: job,
            sources: [.init(
                role: .meetingSystem,
                sourcePath: sourceURL.path,
                expectedByteCount: Int64(bytes.count),
                filename: filename,
                originalFilename: sourceURL.lastPathComponent
            )],
            removeSourcesAfterCommit: true
        )
        try bytes.write(to: audioDirectory.appendingPathComponent(filename))
        // Force reconciliation to remain pending by making the existing final
        // member fail verification on the first launch.
        let expectedSize = intent.sources[0].expectedByteCount
        var pendingIntent = intent
        pendingIntent.sources[0].expectedByteCount = expectedSize + 1
        let intentURL = intentDirectory.appendingPathComponent("\(id.uuidString.lowercased()).json")
        try JSONEncoder().encode(pendingIntent).write(to: intentURL, options: .atomic)

        let store = RecordingJobStore(rootDirectoryURL: queueRoot)
        let pending = try await store.load(recoverInterrupted: false)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioDirectory.appendingPathComponent(filename).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: intentURL.path))

        // Repair the simulated interrupted source metadata and verify a later
        // launch adopts the same member into one v2 job rather than a v1 job.
        try bytes.write(to: sourceURL)
        try JSONEncoder().encode(intent).write(to: intentURL, options: .atomic)
        let recovered = try await store.load(recoverInterrupted: false)
        XCTAssertEqual(recovered, [job])
        XCTAssertEqual(recovered.first?.schemaVersion, 2)
    }

    func testFinalizedChunkReceiptRoundTripPreservesRecoveryPayload() throws {
        let chunk = MeetingCaptureChunk(
            source: .microphone,
            filename: "meetingMicrophone-0000.m4a",
            startTime: 0.25,
            endTime: 1.5,
            byteCount: 512
        )
        let receipt = MeetingCaptureChunkReceipt(
            chunk: chunk,
            events: [.init(source: .microphone, kind: .gap, presentationTime: 0.8, duration: 0.1)],
            warnings: ["Recovered warning"]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(MeetingCaptureChunkReceipt.self, from: JSONEncoder().encode(receipt)),
            receipt
        )
    }

    func testManifestRoundTripPreservesChunksWarningsAndRecoveryStates() throws {
        let manifest = MeetingCaptureManifest(
            sessionID: UUID(), state: .interrupted, selectedApplicationName: "Meet",
            chunks: [MeetingCaptureChunk(source: .system, filename: "system-0000.m4a", startTime: 2, endTime: 4, byteCount: 99)],
            events: [MeetingTimelineEvent(source: .system, kind: .formatChange, presentationTime: 2, sampleRate: 48_000, channelCount: 2)],
            warnings: ["System audio stopped"]
        )
        let decoded = try JSONDecoder().decode(MeetingCaptureManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded, manifest)
        XCTAssertTrue(decoded.isRecoverable)
        XCTAssertFalse(MeetingCaptureManifest(sessionID: UUID(), state: .consumed, chunks: manifest.chunks).isRecoverable)
    }

    func testManifestRecoveryMetadataRejectsUnsafeOrInvalidChunks() {
        var manifest = MeetingCaptureManifest(
            sessionID: UUID(),
            state: .interrupted,
            chunks: [.init(source: .system, filename: "../outside.m4a", startTime: 0, endTime: 1, byteCount: 10)],
            duration: 1
        )
        XCTAssertFalse(manifest.hasSafeRecoveryMetadata)
        XCTAssertFalse(manifest.isRecoverable)

        manifest.chunks = [.init(source: .system, filename: "system.m4a", startTime: 2, endTime: 1, byteCount: 10)]
        XCTAssertFalse(manifest.hasSafeRecoveryMetadata)

        manifest.chunks = [.init(source: .system, filename: "system.m4a", startTime: 0, endTime: 1, byteCount: 10)]
        manifest.events = [.init(source: .system, kind: .gap, presentationTime: 0.5, duration: -Double.infinity)]
        XCTAssertFalse(manifest.hasSafeRecoveryMetadata)
    }

    func testLifecycleRejectsInvalidStartsAndStopsExactlyOnceAcrossSessions() throws {
        var lifecycle = MeetingCaptureLifecycle()
        try lifecycle.beginSelection()
        XCTAssertThrowsError(try lifecycle.beginSelection())
        try lifecycle.beginPreparing(); try lifecycle.didStart()
        XCTAssertTrue(lifecycle.requestStop())
        XCTAssertFalse(lifecycle.requestStop())
        lifecycle.didFinish()
        try lifecycle.beginSelection()
        try lifecycle.beginPreparing(); try lifecycle.didStart()
        XCTAssertTrue(lifecycle.requestStop())
    }

    func testStopDuringChunkRotationFinalizesBufferedAudioBeforeCompleting() {
        var lifecycle = MeetingChunkWriterLifecycle()
        XCTAssertTrue(lifecycle.beginRotation())
        XCTAssertTrue(lifecycle.buffersSamples)

        XCTAssertEqual(lifecycle.requestStop(hasCurrentChunk: true), .waitForRotation)
        XCTAssertFalse(lifecycle.acceptsSamples)
        XCTAssertFalse(lifecycle.buffersSamples)
        XCTAssertEqual(
            lifecycle.didFinishRotation(hasBufferedSamples: true),
            .finalizeBufferedChunk,
            "A stop racing async rollover must finalize, not merely start, the buffered chunk"
        )

        lifecycle.didFinishStop()
        XCTAssertEqual(lifecycle.state, .stopped)
        XCTAssertEqual(lifecycle.requestStop(hasCurrentChunk: false), .alreadyStopping)
    }

    func testStopDuringChunkRotationWithoutBufferedAudioCannotStartOrphanChunk() {
        var lifecycle = MeetingChunkWriterLifecycle()
        XCTAssertTrue(lifecycle.beginRotation())
        XCTAssertEqual(lifecycle.requestStop(hasCurrentChunk: true), .waitForRotation)
        XCTAssertEqual(lifecycle.didFinishRotation(hasBufferedSamples: false), .completeStop)
        XCTAssertEqual(lifecycle.state, .stopped)
        XCTAssertFalse(lifecycle.beginRotation())
    }

    func testChunkWriterLifecycleSupportsIndependentRepeatedSessions() {
        var first = MeetingChunkWriterLifecycle()
        XCTAssertEqual(first.requestStop(hasCurrentChunk: true), .finalizeCurrent)
        first.didFinishStop()
        XCTAssertEqual(first.state, .stopped)

        var second = MeetingChunkWriterLifecycle()
        XCTAssertTrue(second.beginRotation())
        XCTAssertEqual(second.didFinishRotation(hasBufferedSamples: true), .startNextChunk)
        XCTAssertEqual(second.state, .accepting)
    }

    func testClipboardPolicyMatchesLegacyImmediateAndRetryRules() {
        XCTAssertTrue(MeetingClipboardPolicy.shouldCopyAutomatically(delivery: .clipboard, initialPolicy: .immediate, attemptedAt: nil))
        XCTAssertFalse(MeetingClipboardPolicy.shouldCopyAutomatically(delivery: .clipboard, initialPolicy: .manual, attemptedAt: nil))
        XCTAssertFalse(MeetingClipboardPolicy.shouldCopyAutomatically(delivery: .clipboard, initialPolicy: .immediate, attemptedAt: Date()))
        XCTAssertFalse(MeetingClipboardPolicy.shouldCopyAutomatically(delivery: .recovery, initialPolicy: .immediate, attemptedAt: nil))
    }

    func testMultiChunkSameRoleRecoveryNormalizesOnSharedTimeline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let later = root.appendingPathComponent("system-0001.wav")
        let earlier = root.appendingPathComponent("system-0000.wav")
        try AudioFileConverter.writeWAV(samples: Array(repeating: 0.25, count: 1_600), to: later)
        try AudioFileConverter.writeWAV(samples: Array(repeating: 0.5, count: 1_600), to: earlier)
        let manifest = MeetingCaptureManifest(
            sessionID: UUID(),
            state: .interrupted,
            chunks: [
                MeetingCaptureChunk(source: .system, filename: later.lastPathComponent, startTime: 1.0, endTime: 1.1, byteCount: 1),
                MeetingCaptureChunk(source: .system, filename: earlier.lastPathComponent, startTime: 0.25, endTime: 0.35, byteCount: 1),
            ]
        )
        let output = root.appendingPathComponent("system-normalized.wav")
        try AudioFileConverter.normalizeMeetingStem(
            chunks: manifest.orderedChunks(for: .system).map {
                (root.appendingPathComponent($0.filename), $0.startTime, $0.endTime)
            },
            outputURL: output
        )
        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 1.1, accuracy: 0.01)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        )!
        try file.read(into: buffer)
        let values = buffer.floatChannelData![0]
        XCTAssertEqual(values[1_000], 0, accuracy: 0.01, "Leading recovery offset must remain silent")
        XCTAssertGreaterThan(abs(values[4_400]), 0.02, "Earlier same-role chunk must land at 0.25 seconds")
        XCTAssertEqual(values[8_000], 0, accuracy: 0.01, "Inter-chunk gap must remain silent")
        XCTAssertGreaterThan(abs(values[16_800]), 0.02, "Later same-role chunk must land at 1.0 seconds")

        let mapped = MeetingTranscriptAssembler.mapToMeetingTimeline(
            segments: [TimedTranscriptionSegment(text: "Recovered", startTime: 1.01, endTime: 1.08)],
            source: .system,
            manifest: manifest
        )
        let recovered = try XCTUnwrap(mapped.first)
        XCTAssertEqual(recovered.startTime, 1.01, accuracy: 0.001)
        XCTAssertEqual(recovered.endTime, 1.08, accuracy: 0.001)
    }

    func testSchemaV2FixtureShapeAndMalformedVariants() throws {
        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Persistence/v1", isDirectory: true)
        let validURL = fixtureRoot.appendingPathComponent("recording-jobs/job-v2-meeting.json")
        let valid = try JSONDecoder().decode(RecordingJob.self, from: Data(contentsOf: validURL))
        XCTAssertEqual(valid.schemaVersion, RecordingJob.currentSchemaVersion)
        XCTAssertEqual(valid.resolvedArtifacts.map(\.role), [
            .playbackMix, .meetingMicrophone, .meetingSystem, .meetingTimeline,
        ])
        XCTAssertEqual(Set(valid.resolvedArtifacts.map(\.filename)).count, 4)

        for name in ["v2-missing-artifacts", "v2-duplicate-role", "v2-unsafe-filename"] {
            let url = fixtureRoot.appendingPathComponent("negative/recording-jobs/\(name).json")
            XCTAssertThrowsError(try JSONDecoder().decode(RecordingJob.self, from: Data(contentsOf: url)))
        }
    }

    func testTimelineNormalizationInsertsFirstOffsetAndInterChunkGap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = root.appendingPathComponent("one.wav")
        let two = root.appendingPathComponent("two.wav")
        try AudioFileConverter.writeWAV(samples: Array(repeating: 0.5, count: 1_600), to: one)
        try AudioFileConverter.writeWAV(samples: Array(repeating: 0.25, count: 1_600), to: two)
        let output = root.appendingPathComponent("out.wav")
        try AudioFileConverter.normalizeMeetingStem(
            chunks: [(one, 0.5, 0.6), (two, 1.0, 1.1)], outputURL: output
        )
        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 1.1, accuracy: 0.01)
    }

    func testTimelineNormalizationClipsAndPadsToPublishedChunkBounds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let long = root.appendingPathComponent("long.wav")
        let short = root.appendingPathComponent("short.wav")
        try AudioFileConverter.writeWAV(samples: Array(repeating: 0.5, count: 3_200), to: long)
        try AudioFileConverter.writeWAV(samples: Array(repeating: 0.25, count: 800), to: short)
        let output = root.appendingPathComponent("bounded.wav")

        try AudioFileConverter.normalizeMeetingStem(
            chunks: [(long, 0, 0.1), (short, 0.2, 0.3)],
            outputURL: output
        )

        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 0.3, accuracy: 0.01)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        )!
        try file.read(into: buffer)
        let values = buffer.floatChannelData![0]
        XCTAssertGreaterThan(abs(values[800]), 0.02, "The long chunk should retain audio inside its declared bound")
        XCTAssertEqual(values[2_400], 0, accuracy: 0.01, "Audio beyond the first chunk end must be clipped")
        XCTAssertGreaterThan(abs(values[3_400]), 0.02, "The short second chunk should begin at its canonical offset")
        XCTAssertEqual(values[4_600], 0, accuracy: 0.01, "A short chunk must be padded to its published end")
    }

    func testOneSourceMixUsesUnityGainAndTwoSourceUsesHeadroom() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.wav")
        try AudioFileConverter.writeWAV(samples: Array(repeating: 0.5, count: 1_600), to: input)
        let one = try AudioFileConverter.mixWhisperWAVStreaming(microphoneURL: input, systemURL: nil, outputURL: root.appendingPathComponent("one.wav"))
        let two = try AudioFileConverter.mixWhisperWAVStreaming(microphoneURL: input, systemURL: input, outputURL: root.appendingPathComponent("two.wav"))
        XCTAssertEqual(try peak(one), 0.5, accuracy: 0.03)
        XCTAssertEqual(try peak(two), 0.5, accuracy: 0.03)
    }

    private func peak(_ url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        guard let values = buffer.floatChannelData?[0] else { return 0 }
        return (0..<Int(buffer.frameLength)).map { abs(values[$0]) }.max() ?? 0
    }
}
