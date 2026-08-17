import Foundation
import XCTest
@testable import VoxboardShared

final class RecordingJobStoreTests: XCTestCase {
    func test_draftVoiceProcessingConfigurationPersistsAndPresetDeliveryDerivesImmutablePolicy() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let source = try fixture.makeAudio(named: "draft-voice.wav")
        let configuration = RecordingVoiceProcessingConfiguration(
            presetID: "meeting",
            speakerDiarizationEnabled: true
        )
        let job = try await fixture.store.enqueue(
            sourceURL: source,
            duration: 5,
            source: .importedAudio,
            delivery: .captureDraft(attachAudio: false),
            voiceProcessingConfiguration: configuration,
            modelID: "automatic",
            language: "auto",
            configuration: .default
        )
        let loadedJob = try await fixture.store.job(id: job.id)
        let reloaded = try XCTUnwrap(loadedJob)
        XCTAssertEqual(reloaded.delivery, .captureDraft(attachAudio: false))
        XCTAssertEqual(reloaded.effectiveVoiceProcessingConfiguration, configuration)

        var preset = CapturePreset(id: "preset", name: "Meeting", symbolName: "mic")
        preset.speakerDiarizationEnabled = true
        let presetJob = RecordingJob(
            audioFilename: "preset.wav",
            duration: 1,
            source: .iOSApp,
            delivery: .preset(preset),
            modelID: "automatic",
            language: "auto",
            retentionPolicy: .deleteAfterSuccess,
            processingPolicy: .manual
        )
        preset.speakerDiarizationEnabled = false
        XCTAssertEqual(
            presetJob.effectiveVoiceProcessingConfiguration,
            RecordingVoiceProcessingConfiguration(
                presetID: "preset",
                speakerDiarizationEnabled: true
            )
        )
    }

    func test_legacyJobAndHandoffWithoutVoiceConfigurationDecodeAsNil() throws {
        let handoff = RecordingJobHandoffIntent(
            audioFilename: "legacy.wav",
            duration: 1,
            source: .importedAudio,
            delivery: .captureDraft(attachAudio: false),
            modelID: "automatic",
            language: "auto",
            configuration: .default
        )
        var handoffObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(handoff)) as? [String: Any]
        )
        handoffObject.removeValue(forKey: "voiceProcessingConfiguration")
        let legacyHandoff = try JSONDecoder().decode(
            RecordingJobHandoffIntent.self,
            from: JSONSerialization.data(withJSONObject: handoffObject)
        )
        XCTAssertNil(legacyHandoff.voiceProcessingConfiguration)

        let job = RecordingJob(
            audioFilename: "legacy.wav",
            duration: 1,
            source: .importedAudio,
            delivery: .captureDraft(attachAudio: false),
            modelID: "automatic",
            language: "auto",
            retentionPolicy: .deleteAfterSuccess,
            processingPolicy: .manual
        )
        var jobObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any]
        )
        jobObject.removeValue(forKey: "voiceProcessingConfiguration")
        let legacyJob = try JSONDecoder().decode(
            RecordingJob.self,
            from: JSONSerialization.data(withJSONObject: jobObject)
        )
        XCTAssertNil(legacyJob.voiceProcessingConfiguration)
    }

    func test_enqueuePersistsOriginBoundMetadataWithoutReacquisition() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let source = try fixture.makeAudio(named: "origin.wav")
        let attemptedAt = Date(timeIntervalSince1970: 1_234)
        let outcome = CaptureLocationOutcome.unavailable(.permissionDenied, attemptedAt: attemptedAt)

        let queued = try await fixture.store.enqueue(
            sourceURL: source,
            captureSource: CaptureSource.fileImport,
            locationOutcome: outcome,
            duration: 1,
            source: .importedAudio,
            delivery: .preset(CapturePresetStore.makeCustomFlow()),
            modelID: "automatic",
            language: "auto",
            configuration: RecordingQueueConfiguration()
        )
        let loaded = try await fixture.store.job(id: queued.id)

        XCTAssertEqual(loaded?.captureSource, .fileImport)
        XCTAssertEqual(loaded?.locationOutcome, outcome)
    }

    func test_enqueueCopiesAudioAndPersistsImmutableJobSnapshot() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let sourceURL = try fixture.makeAudio(named: "source.wav")
        let preset = CapturePreset(
            id: "meeting",
            name: "Meeting",
            symbolName: "mic"
        )
        let configuration = RecordingQueueConfiguration(
            sourceAudioRetention: .timed(3 * 24 * 60 * 60),
            processingPolicy: .manual
        )

        let job = try await fixture.store.enqueue(
            sourceURL: sourceURL,
            duration: 42,
            source: .iOSApp,
            delivery: .preset(preset),
            modelID: "automatic",
            fallbackModelID: "ggml-base",
            language: "en",
            configuration: configuration
        )
        let reloaded = try await fixture.store.load()

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.audioURL(for: job).path))
        XCTAssertEqual(reloaded, [job])
        XCTAssertEqual(job.retentionPolicy, .timed(3 * 24 * 60 * 60))
        XCTAssertEqual(job.processingPolicy, .manual)
        XCTAssertEqual(job.phase, .queued)
        XCTAssertEqual(job.delivery, .preset(preset))
    }

    func test_enqueueStorageFailurePreservesOriginalAudio() async throws {
        let fileManager = FailingRemovalFileManager()
        let fixture = try makeFixture(fileManager: fileManager)
        defer { fixture.cleanup() }
        let sourceURL = try fixture.makeAudio()
        fileManager.shouldFailCopy = true

        do {
            _ = try await fixture.store.enqueue(
                sourceURL: sourceURL,
                duration: 5,
                source: .iOSApp,
                delivery: .clipboard,
                modelID: "automatic",
                language: "auto",
                configuration: .default
            )
            XCTFail("Expected staging to fail")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
            let jobs = try await fixture.store.load()
            XCTAssertTrue(jobs.isEmpty)
        }
    }

    func test_failedTranscriptionAlwaysRetainsSourceAudio() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let job = try await fixture.enqueue(retention: .deleteAfterSuccess)
        _ = try await fixture.store.claim(id: job.id)

        let failed = try await fixture.store.markFailed(
            id: job.id,
            stage: .transcription,
            message: "Model failed"
        )

        XCTAssertEqual(failed.phase, .failed)
        XCTAssertNil(failed.audioDeletionDate)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.audioURL(for: failed).path))
    }

    func test_secondProcessCannotRecoverJobWhileWorkerLeaseIsHeld() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let job = try await fixture.enqueue()
        let acquired = try await fixture.store.tryAcquireWorkerLease()
        XCTAssertTrue(acquired)
        _ = try await fixture.store.claim(id: job.id)

        let secondProcessStore = RecordingJobStore(
            rootDirectoryURL: fixture.queueRoot,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        var observed = try await secondProcessStore.load(recoverInterrupted: true)
        XCTAssertEqual(observed.first?.phase, .processing)

        await fixture.store.releaseWorkerLease()
        observed = try await secondProcessStore.load(recoverInterrupted: true)
        XCTAssertEqual(observed.first?.phase, .queued)
    }

    func test_relaunchReturnsInterruptedProcessingJobToQueue() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let job = try await fixture.enqueue()
        _ = try await fixture.store.claim(id: job.id)

        let relaunchedStore = RecordingJobStore(
            rootDirectoryURL: fixture.queueRoot,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        let recovered = try await relaunchedStore.load()

        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].phase, .queued)
        XCTAssertEqual(recovered[0].attemptCount, 1)
        XCTAssertTrue(recovered[0].statusMessage?.contains("Recovered") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: relaunchedStore.audioURL(for: recovered[0]).path))
    }

    func test_relaunchRecoversFinalizingJobWithDeliveryCheckpoints() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let job = try await fixture.enqueue(retention: .permanent)
        _ = try await fixture.store.claim(id: job.id)
        _ = try await fixture.store.markExportedNote(id: job.id, path: "/tmp/export.md")
        _ = try await fixture.store.markFinalizing(id: job.id)

        let relaunchedStore = RecordingJobStore(
            rootDirectoryURL: fixture.queueRoot,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        let recovered = try await relaunchedStore.load(recoverInterrupted: true)

        XCTAssertEqual(recovered.first?.phase, .queued)
        XCTAssertEqual(recovered.first?.exportedNotePath, "/tmp/export.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: relaunchedStore.audioURL(for: recovered[0]).path))
    }

    func test_claimNextHonorsImmediateIdleAndManualPolicies() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let manual = try await fixture.enqueue(
            createdAt: Date(timeIntervalSince1970: 1),
            processing: .manual
        )
        let idle = try await fixture.enqueue(
            createdAt: Date(timeIntervalSince1970: 2),
            processing: .whenIdle
        )
        let immediate = try await fixture.enqueue(
            createdAt: Date(timeIntervalSince1970: 3),
            processing: .immediate
        )

        let first = try await fixture.store.claimNext(includeIdle: false)
        XCTAssertEqual(first?.id, immediate.id)
        _ = try await fixture.store.markFailed(
            id: immediate.id,
            stage: .transcription,
            message: "done for test"
        )

        let second = try await fixture.store.claimNext(includeIdle: true)
        XCTAssertEqual(second?.id, idle.id)
        _ = try await fixture.store.markFailed(
            id: idle.id,
            stage: .transcription,
            message: "done for test"
        )

        let noAutomaticWork = try await fixture.store.claimNext(includeIdle: true)
        XCTAssertNil(noAutomaticWork)
        let explicitlyClaimed = try await fixture.store.claim(id: manual.id)
        XCTAssertEqual(explicitlyClaimed.id, manual.id)
    }

    func test_deliveryCheckpointsAndDraftVoicePolicySurviveFailureAndRetry() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let voiceConfiguration = RecordingVoiceProcessingConfiguration(
            presetID: "meeting",
            speakerDiarizationEnabled: true
        )
        let job = try await fixture.enqueue(
            delivery: .captureDraft(attachAudio: false),
            voiceProcessingConfiguration: voiceConfiguration
        )
        _ = try await fixture.store.claim(id: job.id)
        _ = try await fixture.store.markExportedNote(id: job.id, path: "/tmp/note.md")
        _ = try await fixture.store.markExportedAudio(id: job.id, path: "/tmp/note.m4a")
        _ = try await fixture.store.markAutomaticClipboardDeliveryAttempted(id: job.id)
        _ = try await fixture.store.markFailed(
            id: job.id,
            stage: .delivery,
            message: "Attach failed"
        )

        let retried = try await fixture.store.retry(id: job.id)

        XCTAssertEqual(retried.exportedNotePath, "/tmp/note.md")
        XCTAssertEqual(retried.exportedAudioPath, "/tmp/note.m4a")
        XCTAssertNotNil(retried.automaticClipboardDeliveryAttemptedAt)
        XCTAssertEqual(retried.delivery, .captureDraft(attachAudio: false))
        XCTAssertEqual(retried.voiceProcessingConfiguration, voiceConfiguration)
    }

    func test_repairedAudioCheckpointInvalidatesPriorReferenceCheckpoint() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let job = try await fixture.enqueue(retention: .permanent)
        _ = try await fixture.store.claim(id: job.id)
        _ = try await fixture.store.markExportedAudio(id: job.id, path: "/tmp/original.m4a")
        let referenced = try await fixture.store.markAudioReferenceAttached(id: job.id)
        XCTAssertNotNil(referenced.audioReferenceAttachedAt)

        let repaired = try await fixture.store.markExportedAudio(
            id: job.id,
            path: "/tmp/repaired.wav"
        )

        XCTAssertEqual(repaired.exportedAudioPath, "/tmp/repaired.wav")
        XCTAssertNil(repaired.audioReferenceAttachedAt)
    }

    func test_sameAudioCheckpointPreservesReferenceCheckpoint() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let job = try await fixture.enqueue(retention: .permanent)
        _ = try await fixture.store.claim(id: job.id)
        _ = try await fixture.store.markExportedAudio(id: job.id, path: "/tmp/existing.m4a")
        let referenced = try await fixture.store.markAudioReferenceAttached(id: job.id)

        let unchanged = try await fixture.store.markExportedAudio(
            id: job.id,
            path: "/tmp/existing.m4a"
        )

        XCTAssertEqual(unchanged.audioReferenceAttachedAt, referenced.audioReferenceAttachedAt)
    }

    func test_processNowPreservesOriginalDeferredPolicyForLateClipboardSafety() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let job = try await fixture.enqueue(processing: .manual)

        let processNow = try await fixture.store.processNow(id: job.id)

        XCTAssertEqual(processNow.processingPolicy, .immediate)
        XCTAssertEqual(processNow.initialProcessingPolicy, .manual)
    }

    func test_exportCheckpointsClearPrivateDeliveryTransactionsAfterManifestPersistence() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let job = try await fixture.enqueue(retention: .permanent)
        _ = try await fixture.store.claim(id: job.id)
        let noteTransactionURL = fixture.store.externalDeliveryTransactionDirectoryURL(
            for: job.id,
            artifact: .note
        )
        let audioTransactionURL = fixture.store.externalDeliveryTransactionDirectoryURL(
            for: job.id,
            artifact: .audio
        )
        let referenceTransactionURL = fixture.store.externalDeliveryTransactionDirectoryURL(
            for: job.id,
            artifact: .noteAudioReference
        )
        let exportedNoteURL = fixture.root.appendingPathComponent("external-note.txt")
        let exportedAudioURL = fixture.root.appendingPathComponent("external-audio.wav")
        _ = try ExternalFileDeliveryTransaction(directoryURL: noteTransactionURL)
            .prepareAndPublish(
                data: Data("note".utf8),
                to: exportedNoteURL,
                expecting: .missing
            )
        _ = try ExternalFileDeliveryTransaction(directoryURL: audioTransactionURL)
            .prepareAndPublish(
                data: Data("audio".utf8),
                to: exportedAudioURL,
                expecting: .missing
            )
        XCTAssertTrue(FileManager.default.fileExists(atPath: noteTransactionURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioTransactionURL.path))

        _ = try await fixture.store.markExportedNote(id: job.id, path: exportedNoteURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: noteTransactionURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioTransactionURL.path))
        let updated = try await fixture.store.markExportedAudio(id: job.id, path: exportedAudioURL.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: audioTransactionURL.path))
        _ = try ExternalFileDeliveryTransaction(directoryURL: referenceTransactionURL)
            .prepareAndPublish(
                data: Data("note with audio reference".utf8),
                to: exportedNoteURL,
                expecting: .contents(Data("note".utf8))
            )
        XCTAssertTrue(FileManager.default.fileExists(atPath: referenceTransactionURL.path))
        let referenced = try await fixture.store.markAudioReferenceAttached(id: job.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: referenceTransactionURL.path))
        XCTAssertEqual(updated.exportedNotePath, exportedNoteURL.path)
        XCTAssertEqual(updated.exportedAudioPath, exportedAudioURL.path)
        XCTAssertNotNil(referenced.audioReferenceAttachedAt)
    }

    func test_deferredClipboardAudioWaitsForExplicitCopy() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let job = try await fixture.enqueue(retention: .permanent)
        _ = try await fixture.store.claim(id: job.id)

        let awaitingCopy = try await fixture.store.markCompleted(
            id: job.id,
            transcriptText: "durable transcript"
        )
        XCTAssertEqual(awaitingCopy.phase, .completed)
        XCTAssertNil(awaitingCopy.audioDeletionDate)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.audioURL(for: awaitingCopy).path))

        let overridden = try await fixture.store.updateRetention(
            id: job.id,
            policy: .deleteAfterSuccess
        )
        XCTAssertNil(overridden.audioDeletionDate)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.audioURL(for: overridden).path))

        let delivered = try await fixture.store.clearCompletedTranscriptText(id: job.id)
        XCTAssertNil(delivered.transcriptText)
        XCTAssertNotNil(delivered.audioDeletedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.audioURL(for: delivered).path))
    }

    func test_failedClipboardCanCompleteThroughExplicitCopyWithoutRetranscribing() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let job = try await fixture.enqueue(retention: .permanent)
        _ = try await fixture.store.claim(id: job.id)
        _ = try await fixture.store.recordTranscriptCheckpoint(id: job.id, text: "copy me")
        _ = try await fixture.store.markFailed(
            id: job.id,
            stage: .delivery,
            message: "Pasteboard failed"
        )

        let delivered = try await fixture.store.clearCompletedTranscriptText(id: job.id)

        XCTAssertEqual(delivered.phase, .completed)
        XCTAssertNil(delivered.failureStage)
        XCTAssertNil(delivered.transcriptText)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.audioURL(for: delivered).path))
    }

    func test_deleteAfterSuccessDeletesOnlyAfterCompletedStateIsPersisted() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let job = try await fixture.enqueue(retention: .deleteAfterSuccess)
        _ = try await fixture.store.claim(id: job.id)
        _ = try await fixture.store.markFinalizing(id: job.id)

        let completed = try await fixture.store.markCompleted(
            id: job.id,
            completedAt: Date(timeIntervalSince1970: 100)
        )
        let persisted = try await fixture.store.job(id: job.id)

        XCTAssertEqual(completed.phase, .completed)
        XCTAssertNotNil(completed.audioDeletedAt)
        XCTAssertEqual(persisted?.phase, .completed)
        XCTAssertNotNil(persisted?.audioDeletedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.audioURL(for: completed).path))
    }

    func test_cleanupFailureDoesNotRepeatSuccessfulProcessing() async throws {
        let fileManager = FailingRemovalFileManager()
        let fixture = try makeFixture(fileManager: fileManager)
        defer { fixture.cleanup() }
        let job = try await fixture.enqueue(retention: .deleteAfterSuccess)
        _ = try await fixture.store.claim(id: job.id)
        fileManager.shouldFailRemoval = true

        let completed = try await fixture.store.markCompleted(id: job.id)

        XCTAssertEqual(completed.phase, .completed)
        XCTAssertNil(completed.failureStage)
        XCTAssertNotNil(completed.audioDeletionDate)
        XCTAssertNil(completed.audioDeletedAt)
        XCTAssertTrue(completed.statusMessage?.contains("cleanup is pending") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.audioURL(for: completed).path))
    }

    func test_relaunchRepairsDeletionReceiptAfterDeleteBeforeMetadataCrash() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let job = try await fixture.enqueue(retention: .timed(3600))
        _ = try await fixture.store.claim(id: job.id)
        var completed = try await fixture.store.markCompleted(
            id: job.id,
            completedAt: Date(timeIntervalSince1970: 10_000)
        )
        completed.audioDeletionDate = Date(timeIntervalSince1970: 1)
        completed.audioDeletedAt = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let itemURL = fixture.queueRoot
            .appendingPathComponent("items", isDirectory: true)
            .appendingPathComponent("\(job.id.uuidString.lowercased()).json")
        try encoder.encode(completed).write(to: itemURL, options: .atomic)
        try FileManager.default.removeItem(at: fixture.store.audioURL(for: completed))

        let relaunchedStore = RecordingJobStore(
            rootDirectoryURL: fixture.queueRoot,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        let recovered = try await relaunchedStore.load(recoverInterrupted: true)

        XCTAssertEqual(recovered.first?.phase, .completed)
        XCTAssertNotNil(recovered.first?.audioDeletedAt)
        XCTAssertNil(recovered.first?.failureStage)
    }

    func test_timedRetentionKeepsAudioUntilDeadline() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let interval: TimeInterval = 3600
        let job = try await fixture.enqueue(retention: .timed(interval))
        _ = try await fixture.store.claim(id: job.id)
        let completedAt = Date(timeIntervalSince1970: 10_000)

        let completed = try await fixture.store.markCompleted(
            id: job.id,
            completedAt: completedAt
        )
        XCTAssertEqual(completed.audioDeletionDate, completedAt.addingTimeInterval(interval))
        XCTAssertNil(completed.audioDeletedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.audioURL(for: completed).path))

        let early = try await fixture.store.performRetentionCleanup(
            now: completedAt.addingTimeInterval(interval - 1)
        )
        XCTAssertTrue(early.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.audioURL(for: completed).path))

        let due = try await fixture.store.performRetentionCleanup(
            now: completedAt.addingTimeInterval(interval)
        )
        XCTAssertEqual(due, [job.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.audioURL(for: completed).path))
    }

    func test_permanentRetentionKeepsCompletedAudio() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let job = try await fixture.enqueue(retention: .permanent)
        _ = try await fixture.store.claim(id: job.id)

        let completed = try await fixture.store.markCompleted(id: job.id)
        _ = try await fixture.store.performRetentionCleanup(now: .distantFuture)

        XCTAssertNil(completed.audioDeletionDate)
        XCTAssertNil(completed.audioDeletedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.audioURL(for: completed).path))
    }

    func test_orphanedAudioIsSurfacedAsManualRecoveryJob() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let audioDirectory = fixture.queueRoot.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let orphanURL = audioDirectory.appendingPathComponent("orphan.wav")
        try Data(repeating: 9, count: 128).write(to: orphanURL)

        let jobs = try await fixture.store.load()

        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].source, .recovered)
        XCTAssertEqual(jobs[0].delivery, .recovery)
        XCTAssertEqual(jobs[0].phase, .failed)
        XCTAssertEqual(jobs[0].processingPolicy, .manual)
        XCTAssertEqual(jobs[0].retentionPolicy, .permanent)
        XCTAssertEqual(fixture.store.audioURL(for: jobs[0]), orphanURL)
    }

    func test_stagingHandoffWaitsForCutoffThenRecoversWithoutLocationWork() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let sourceURL = try fixture.makeAudio(named: "recording_staging.wav")
        let createdAt = Date(timeIntervalSince1970: 2_000)
        let jobID = UUID()
        try RecordingJobHandoffIntentStore(recordingsDirectoryURL: fixture.root).save(
            RecordingJobHandoffIntent(
                jobID: jobID,
                audioFilename: sourceURL.lastPathComponent,
                captureSource: .voice,
                locationOutcome: .unavailable(.unavailable, attemptedAt: createdAt),
                createdAt: createdAt,
                duration: 8,
                source: .iOSApp,
                delivery: .clipboard,
                modelID: "frozen",
                language: "en",
                configuration: .default
            )
        )

        let liveRecovery = try await fixture.store.recoverExternalOrphans(
            recordingsDirectoryURL: fixture.root,
            olderThan: createdAt.addingTimeInterval(-1)
        )
        XCTAssertTrue(liveRecovery.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))

        let crashedRecovery = try await fixture.store.recoverExternalOrphans(
            recordingsDirectoryURL: fixture.root,
            olderThan: createdAt.addingTimeInterval(1)
        )
        XCTAssertEqual(crashedRecovery.map(\.id), [jobID])
        XCTAssertEqual(crashedRecovery.first?.locationOutcome, .unavailable(.unavailable, attemptedAt: createdAt))
    }

    func test_finalizedHandoffFreezesProducerMetadata() throws {
        let createdAt = Date(timeIntervalSince1970: 3_000)
        let draftID = UUID()
        let sessionID = UUID()
        let preset = CapturePreset(id: "immutable", name: "Immutable", symbolName: "lock")
        let staged = RecordingJobHandoffIntent(
            audioFilename: "import_source.wav",
            requestID: "request",
            draftRequestID: draftID,
            liveSessionID: sessionID,
            captureSource: .fileImport,
            locationOutcome: .unavailable(.unavailable, attemptedAt: createdAt),
            createdAt: createdAt,
            duration: 0,
            source: .importedAudio,
            delivery: .preset(preset),
            modelID: "model-a",
            fallbackModelID: "fallback-a",
            language: "fr",
            configuration: RecordingQueueConfiguration(sourceAudioRetention: .permanent, processingPolicy: .manual)
        )
        let finalOutcome = CaptureLocationOutcome.unavailable(.timeout, attemptedAt: createdAt)
        let finalized = staged.finalized(
            audioFilename: "import.wav",
            relatedAudioFilenames: ["import_source.wav"],
            duration: 12,
            captureSource: .fileImport,
            locationOutcome: finalOutcome
        )

        XCTAssertEqual(finalized.readiness, .ready)
        XCTAssertEqual(finalized.requestID, "request")
        XCTAssertEqual(finalized.draftRequestID, draftID)
        XCTAssertEqual(finalized.liveSessionID, sessionID)
        XCTAssertEqual(finalized.createdAt, createdAt)
        XCTAssertEqual(finalized.source, .importedAudio)
        XCTAssertEqual(finalized.delivery, .preset(preset))
        XCTAssertEqual(finalized.modelID, "model-a")
        XCTAssertEqual(finalized.fallbackModelID, "fallback-a")
        XCTAssertEqual(finalized.language, "fr")
        XCTAssertEqual(finalized.configuration.processingPolicy, .manual)
        XCTAssertEqual(finalized.locationOutcome, finalOutcome)
        XCTAssertEqual(finalized.audioFilename, "import.wav")
        XCTAssertEqual(finalized.duration, 12)
    }

    func test_maliciousAndFutureHandoffIntentsAreIgnoredWithoutFilesystemAccess() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let outsideURL = fixture.root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID()).wav")
        try Data(repeating: 9, count: 128).write(to: outsideURL)
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        let safe = RecordingJobHandoffIntent(
            audioFilename: "recording_safe.wav",
            duration: 1,
            source: .iOSApp,
            delivery: .clipboard,
            modelID: "model",
            language: "en",
            configuration: .default
        )
        let store = RecordingJobHandoffIntentStore(recordingsDirectoryURL: fixture.root)
        try store.save(safe)
        let intentURL = RecordingJobHandoffIntentStore.url(
            for: safe.jobID,
            in: RecordingJobHandoffIntentStore.directoryURL(in: fixture.root)
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: intentURL)) as? [String: Any])
        object["schemaVersion"] = 99
        object["audioFilename"] = "../\(outsideURL.lastPathComponent)"
        try JSONSerialization.data(withJSONObject: object).write(to: intentURL, options: .atomic)
        XCTAssertThrowsError(try store.load(jobID: safe.jobID))

        let recovered = try await fixture.store.recoverExternalOrphans(
            recordingsDirectoryURL: fixture.root,
            olderThan: .distantFuture
        )
        XCTAssertTrue(recovered.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: intentURL.path))
    }

    func test_primaryCleanupFailureReceiptPreventsDuplicateRecovery() async throws {
        let fileManager = FailingRemovalFileManager()
        let fixture = try makeFixture(fileManager: fileManager)
        defer { fixture.cleanup() }
        let sourceURL = try fixture.makeAudio(named: "recording_cleanup.wav")
        fileManager.failedRemovalURL = sourceURL
        let job = try await fixture.store.enqueue(
            sourceURL: sourceURL,
            duration: 2,
            source: .iOSApp,
            delivery: .clipboard,
            modelID: "model",
            language: "en",
            configuration: .default
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(RecordingArtifactDeliveryReceipt.exists(for: sourceURL))

        let recovered = try await fixture.store.recoverExternalOrphans(
            recordingsDirectoryURL: fixture.root,
            olderThan: .distantFuture
        )
        XCTAssertTrue(recovered.isEmpty)
        let loadedIDs = try await fixture.store.load().map(\.id)
        XCTAssertEqual(loadedIDs, [job.id])
        XCTAssertTrue(RecordingArtifactDeliveryReceipt.exists(for: sourceURL))
    }

    func test_handoffIntentRecoversExactIdentityAndImmutableMetadata() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let sourceURL = try fixture.makeAudio(named: "recording_handoff.wav")
        let jobID = UUID()
        let draftID = UUID()
        let sessionID = UUID()
        let attemptedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let outcome = CaptureLocationOutcome.unavailable(.timeout, attemptedAt: attemptedAt)
        let voiceConfiguration = RecordingVoiceProcessingConfiguration(
            presetID: "handoff-preset",
            speakerDiarizationEnabled: true
        )
        let intent = RecordingJobHandoffIntent(
            jobID: jobID,
            audioFilename: sourceURL.lastPathComponent,
            requestID: "request-identity",
            draftRequestID: draftID,
            liveSessionID: sessionID,
            captureSource: .fileImport,
            locationOutcome: outcome,
            duration: 12,
            source: .importedAudio,
            delivery: .captureDraft(attachAudio: false),
            voiceProcessingConfiguration: voiceConfiguration,
            modelID: "automatic",
            fallbackModelID: "fallback",
            language: "fr",
            configuration: RecordingQueueConfiguration(
                sourceAudioRetention: .timed(600),
                processingPolicy: .whenIdle
            )
        )
        try RecordingJobHandoffIntentStore(recordingsDirectoryURL: fixture.root).save(intent)

        let recovered = try await fixture.store.recoverExternalOrphans(
            recordingsDirectoryURL: fixture.root,
            olderThan: .distantFuture
        )

        let job = try XCTUnwrap(recovered.first(where: { $0.id == jobID }))
        XCTAssertEqual(job.requestID, "request-identity")
        XCTAssertEqual(job.draftRequestID, draftID)
        XCTAssertEqual(job.liveSessionID, sessionID)
        XCTAssertEqual(job.captureSource, .fileImport)
        XCTAssertEqual(job.locationOutcome, outcome)
        XCTAssertEqual(job.delivery, .captureDraft(attachAudio: false))
        XCTAssertEqual(job.voiceProcessingConfiguration, voiceConfiguration)
        XCTAssertEqual(job.modelID, "automatic")
        XCTAssertEqual(job.fallbackModelID, "fallback")
        XCTAssertEqual(job.language, "fr")
        XCTAssertEqual(job.createdAt.timeIntervalSince1970, intent.createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(job.duration, 12)
        XCTAssertEqual(job.source, .importedAudio)
        XCTAssertEqual(job.retentionPolicy, .timed(600))
        XCTAssertEqual(job.processingPolicy, .whenIdle)
        XCTAssertEqual(job.originalFilename, sourceURL.lastPathComponent)
        XCTAssertEqual(job.audioFilename, "\(jobID.uuidString.lowercased()).wav")
        XCTAssertNil(try RecordingJobHandoffIntentStore(
            recordingsDirectoryURL: fixture.root
        ).load(jobID: jobID))
    }

    func test_handoffPrimaryCleanupFailureKeepsReceiptAndPreventsDuplicateRecovery() async throws {
        let fileManager = FailingRemovalFileManager()
        let fixture = try makeFixture(fileManager: fileManager)
        defer { fixture.cleanup() }
        let sourceURL = try fixture.makeAudio(named: "recording_handoff_cleanup.wav")
        let jobID = UUID()
        try RecordingJobHandoffIntentStore(recordingsDirectoryURL: fixture.root).save(
            RecordingJobHandoffIntent(
                jobID: jobID,
                audioFilename: sourceURL.lastPathComponent,
                duration: 2,
                source: .iOSApp,
                delivery: .clipboard,
                modelID: "model",
                language: "en",
                configuration: .default
            )
        )
        fileManager.failedRemovalURL = sourceURL

        let recovered = try await fixture.store.recoverExternalOrphans(
            recordingsDirectoryURL: fixture.root,
            olderThan: .distantFuture
        )
        let secondRecovery = try await fixture.store.recoverExternalOrphans(
            recordingsDirectoryURL: fixture.root,
            olderThan: .distantFuture
        )

        XCTAssertEqual(recovered.map(\.id), [jobID])
        XCTAssertTrue(secondRecovery.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(RecordingArtifactDeliveryReceipt.exists(for: sourceURL))
        XCTAssertNil(try RecordingJobHandoffIntentStore(
            recordingsDirectoryURL: fixture.root
        ).load(jobID: jobID))
        let loadedIDs = try await fixture.store.load().map(\.id)
        XCTAssertEqual(loadedIDs, [jobID])
    }

    func test_handoffRecoverySuppressesRelatedJournalWithoutDuplicateJob() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let finalURL = try fixture.makeAudio(named: "recording_final.wav")
        let journalURL = try fixture.makeAudio(named: "segment_active_same.wav")
        let jobID = UUID()
        try RecordingJobHandoffIntentStore(recordingsDirectoryURL: fixture.root).save(
            RecordingJobHandoffIntent(
                jobID: jobID,
                audioFilename: finalURL.lastPathComponent,
                relatedAudioFilenames: [journalURL.lastPathComponent],
                draftRequestID: UUID(),
                liveSessionID: UUID(),
                captureSource: .voice,
                duration: 4,
                source: .iOSApp,
                delivery: .captureDraft(attachAudio: true),
                modelID: "automatic",
                language: "auto",
                configuration: .default
            )
        )

        let recovered = try await fixture.store.recoverExternalOrphans(
            recordingsDirectoryURL: fixture.root,
            olderThan: .distantFuture
        )
        let allJobs = try await fixture.store.load()

        XCTAssertEqual(recovered.map(\.id), [jobID])
        XCTAssertEqual(allJobs.map(\.id), [jobID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func test_successfulEnqueueConsumesHandoffIdempotently() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let sourceURL = try fixture.makeAudio(named: "mac_import_handoff.wav")
        let jobID = UUID()
        try RecordingJobHandoffIntentStore(recordingsDirectoryURL: fixture.root).save(
            RecordingJobHandoffIntent(
                jobID: jobID,
                audioFilename: sourceURL.lastPathComponent,
                draftRequestID: UUID(),
                duration: 3,
                source: .importedAudio,
                delivery: .captureDraft(attachAudio: false),
                modelID: "automatic",
                language: "auto",
                configuration: .default
            )
        )

        let first = try await fixture.store.enqueue(
            sourceURL: sourceURL,
            id: jobID,
            duration: 3,
            source: .importedAudio,
            delivery: .captureDraft(attachAudio: false),
            modelID: "automatic",
            language: "auto",
            configuration: .default
        )
        let second = try await fixture.store.enqueue(
            sourceURL: fixture.store.audioURL(for: first),
            id: jobID,
            duration: 3,
            source: .importedAudio,
            delivery: .captureDraft(attachAudio: false),
            modelID: "automatic",
            language: "auto",
            configuration: .default
        )

        XCTAssertEqual(first, second)
        XCTAssertNil(try RecordingJobHandoffIntentStore(
            recordingsDirectoryURL: fixture.root
        ).load(jobID: jobID))
        let jobs = try await fixture.store.load()
        XCTAssertEqual(jobs.count, 1)
    }

    func test_recentActiveSegmentJournalIsRecoveredImmediatelyAfterRelaunch() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let journalURL = try fixture.makeAudio(named: "segment_active_\(UUID().uuidString).wav")

        let recovered = try await fixture.store.recoverExternalOrphans(
            recordingsDirectoryURL: fixture.root,
            olderThan: Date().addingTimeInterval(1)
        )

        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].phase, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.audioURL(for: recovered[0]).path))
    }

    func test_deliveredExternalArtifactIsCleanedInsteadOfRecovered() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let deliveredURL = try fixture.makeAudio(named: "segment_delivered.wav")
        try RecordingArtifactDeliveryReceipt.write(for: deliveredURL)
        let markerURL = RecordingArtifactDeliveryReceipt.markerURL(for: deliveredURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: deliveredURL.path
        )

        let recovered = try await fixture.store.recoverExternalOrphans(
            recordingsDirectoryURL: fixture.root,
            olderThan: Date(timeIntervalSince1970: 2)
        )

        XCTAssertTrue(recovered.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deliveredURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        let storedJobs = try await fixture.store.load()
        XCTAssertTrue(storedJobs.isEmpty)
    }

    func test_deliveredExternalArtifactCleanupFailureNeverCreatesRetryJob() async throws {
        let fileManager = FailingRemovalFileManager()
        let fixture = try makeFixture(fileManager: fileManager)
        defer { fixture.cleanup() }
        let deliveredURL = try fixture.makeAudio(named: "segment_delivered_pending.wav")
        try RecordingArtifactDeliveryReceipt.write(for: deliveredURL)
        let markerURL = RecordingArtifactDeliveryReceipt.markerURL(for: deliveredURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: deliveredURL.path
        )
        fileManager.shouldFailRemoval = true

        let firstRecovery = try await fixture.store.recoverExternalOrphans(
            recordingsDirectoryURL: fixture.root,
            olderThan: Date(timeIntervalSince1970: 2)
        )

        XCTAssertTrue(firstRecovery.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: deliveredURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        fileManager.shouldFailRemoval = false

        let secondRecovery = try await fixture.store.recoverExternalOrphans(
            recordingsDirectoryURL: fixture.root,
            olderThan: Date(timeIntervalSince1970: 2)
        )
        XCTAssertTrue(secondRecovery.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deliveredURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func test_invalidPersistedAudioPathCannotEscapeQueueDirectory() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let itemsDirectory = fixture.queueRoot.appendingPathComponent("items", isDirectory: true)
        try FileManager.default.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
        let victimURL = fixture.queueRoot.appendingPathComponent("victim.wav")
        try Data(repeating: 7, count: 64).write(to: victimURL)
        let malicious = RecordingJob(
            audioFilename: "../victim.wav",
            duration: 1,
            source: .recovered,
            delivery: .recovery,
            modelID: "automatic",
            language: "auto",
            retentionPolicy: .deleteAfterSuccess,
            processingPolicy: .manual,
            phase: .completed,
            completedAt: Date(timeIntervalSince1970: 1),
            audioDeletionDate: Date(timeIntervalSince1970: 1)
        )
        let encoder = JSONEncoder()
        try encoder.encode(malicious).write(
            to: itemsDirectory.appendingPathComponent("\(malicious.id.uuidString.lowercased()).json"),
            options: .atomic
        )

        let loaded = try await fixture.store.load()

        XCTAssertTrue(loaded.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victimURL.path))
    }

    func test_externalLegacyRecordingIsRecoveredWithoutImportingUnrelatedAudio() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let orphanURL = try fixture.makeAudio(named: "segment_interrupted.wav")
        let unrelatedURL = try fixture.makeAudio(named: "user-song.wav")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: orphanURL.path
        )

        let recovered = try await fixture.store.recoverExternalOrphans(
            recordingsDirectoryURL: fixture.root,
            olderThan: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].phase, .failed)
        XCTAssertEqual(recovered[0].delivery, .recovery)
        XCTAssertEqual(recovered[0].retentionPolicy, .permanent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.audioURL(for: recovered[0]).path))
    }

    func test_futureManifestFailsActionablyAndRemainsPreserved() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let itemsDirectory = fixture.queueRoot.appendingPathComponent("items", isDirectory: true)
        try FileManager.default.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
        let job = RecordingJob(
            audioFilename: "future.wav",
            duration: 1,
            source: .iOSApp,
            delivery: .clipboard,
            modelID: "automatic",
            language: "en",
            retentionPolicy: .permanent,
            processingPolicy: .manual
        )
        let encoder = JSONEncoder()
        let current = try encoder.encode(job)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: current) as? [String: Any])
        object["schemaVersion"] = 99
        let future = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let url = itemsDirectory
            .appendingPathComponent(job.id.uuidString.lowercased())
            .appendingPathExtension("json")
        try future.write(to: url)

        do {
            _ = try await fixture.store.load(recoverInterrupted: false)
            XCTFail("Expected future schema rejection")
        } catch RecordingJobStoreError.unsupportedSchemaVersion(99) {
            XCTAssertEqual(try Data(contentsOf: url), future)
        }
    }

    func test_legacyManifestDecodesWithoutOptionalCheckpointFields() throws {
        let original = RecordingJob(
            audioFilename: "legacy.wav",
            duration: 12,
            source: .iOSApp,
            delivery: .clipboard,
            modelID: "automatic",
            language: "en",
            retentionPolicy: .permanent,
            processingPolicy: .immediate
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for key in [
            "initialProcessingPolicy",
            "automaticClipboardDeliveryAttemptedAt",
            "exportedNotePath",
            "exportedAudioPath",
            "audioReferenceAttachedAt",
        ] {
            object.removeValue(forKey: key)
        }
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(RecordingJob.self, from: legacyData)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertNil(decoded.initialProcessingPolicy)
        XCTAssertNil(decoded.automaticClipboardDeliveryAttemptedAt)
        XCTAssertNil(decoded.exportedNotePath)
        XCTAssertNil(decoded.exportedAudioPath)
        XCTAssertNil(decoded.audioReferenceAttachedAt)
    }

    func test_preferencesRoundTripAllUserConfigurableChoices() {
        let suiteName = "RecordingJobStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configurations: [RecordingQueueConfiguration] = [
            RecordingQueueConfiguration(
                sourceAudioRetention: .deleteAfterSuccess,
                processingPolicy: .immediate
            ),
            RecordingQueueConfiguration(
                sourceAudioRetention: .timed(30 * 24 * 60 * 60),
                processingPolicy: .whenIdle
            ),
            RecordingQueueConfiguration(
                sourceAudioRetention: .permanent,
                processingPolicy: .manual
            ),
        ]

        for configuration in configurations {
            RecordingQueuePreferences.save(configuration, to: defaults)
            XCTAssertEqual(RecordingQueuePreferences.load(from: defaults), configuration)
        }
    }

    private func makeFixture(
        fileManager: FileManager = .default
    ) throws -> RecordingJobStoreFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RecordingJobStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queueRoot = root.appendingPathComponent("queue", isDirectory: true)
        return RecordingJobStoreFixture(
            root: root,
            queueRoot: queueRoot,
            store: RecordingJobStore(
                rootDirectoryURL: queueRoot,
                coordinator: ProcessLocalCaptureFileCoordinator(),
                fileManager: fileManager
            )
        )
    }
}

private struct RecordingJobStoreFixture {
    let root: URL
    let queueRoot: URL
    let store: RecordingJobStore

    func makeAudio(named name: String = "source-\(UUID().uuidString).wav") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 7, count: 512).write(to: url)
        return url
    }

    func enqueue(
        createdAt: Date = Date(),
        retention: SourceAudioRetentionPolicy = .deleteAfterSuccess,
        processing: RecordingJobProcessingPolicy = .immediate,
        delivery: RecordingJobDelivery = .clipboard,
        voiceProcessingConfiguration: RecordingVoiceProcessingConfiguration? = nil
    ) async throws -> RecordingJob {
        let sourceURL = try makeAudio()
        return try await store.enqueue(
            sourceURL: sourceURL,
            createdAt: createdAt,
            duration: 5,
            source: .macApp,
            delivery: delivery,
            voiceProcessingConfiguration: voiceProcessingConfiguration,
            modelID: "ggml-base",
            language: "auto",
            configuration: RecordingQueueConfiguration(
                sourceAudioRetention: retention,
                processingPolicy: processing
            )
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class FailingRemovalFileManager: FileManager, @unchecked Sendable {
    var shouldFailRemoval = false
    var shouldFailCopy = false
    var failedRemovalURL: URL?

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if shouldFailCopy {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }

    override func removeItem(at URL: URL) throws {
        if shouldFailRemoval || URL.standardizedFileURL == failedRemovalURL?.standardizedFileURL {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}
