import CryptoKit
import Foundation
import VoxboardCaptureCore
import VoxboardShared

@main
struct VoxboardPersistenceFixtures {
    private static let fixtureVersion = "v1"
    fileprivate static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    fileprivate static let requestID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private static let destinationID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private static let templateID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!

    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments == ["--generate"] || arguments == ["--validate"] else {
            throw FixtureError.usage
        }
        let root = try fixtureRoot()
        if arguments[0] == "--generate" {
            try generate(at: root)
            print("Generated synthetic persistence fixtures at \(root.path)")
        } else {
            try validate(at: root)
            print("Validated synthetic persistence fixtures at \(root.path)")
        }
    }

    private static func fixtureRoot() throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
        let packageRoot = source
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = packageRoot
            .appendingPathComponent("Tests", isDirectory: true)
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("Persistence", isDirectory: true)
            .appendingPathComponent(fixtureVersion, isDirectory: true)
        guard root.standardizedFileURL.path.hasPrefix(packageRoot.standardizedFileURL.path + "/") else {
            throw FixtureError.unsafeFixtureRoot(root.path)
        }
        return root
    }

    private static func generate(at root: URL) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: root)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let asset = try CaptureAssetReference(
            relativePath: "staging/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/voice.m4a",
            originalFilename: "voice.m4a",
            contentTypeIdentifier: "public.mpeg-4-audio",
            byteCount: 4
        )
        let preset = syntheticPreset()
        let library = syntheticLibrary()
        let location = CaptureLocationOutcome.unavailable(.timeout, attemptedAt: fixedDate)
        let request = CaptureRequest(
            id: requestID,
            createdAt: fixedDate,
            source: .watch,
            destinationID: destinationID,
            payloads: [.text("Synthetic fixture text"), .retainedAudio(asset, embedPlacement: .bottom)],
            frontmatter: ["fixture": "true"],
            voxProfile: preset.captureProfile,
            voxProcessingState: .applied,
            locationOutcome: location,
            relativeNotePathOverride: "Fixtures/Inbox.md",
            placementOverride: .beneathHeading(
                CaptureHeadingSelector(title: "Inbox", level: 2),
                missingHeadingBehavior: .create
            ),
            entryTemplateIDOverride: templateID,
            attachmentsFolderNameOverride: "fixtures"
        )
        let draft = CaptureDraft(
            id: requestID,
            requestID: requestID,
            createdAt: fixedDate,
            updatedAt: fixedDate.addingTimeInterval(5),
            captureStartedAt: fixedDate,
            text: "Synthetic draft",
            voxID: preset.id,
            voxProfileSnapshot: preset.captureProfile,
            destinationSelectionMode: .explicit,
            destinationID: destinationID,
            captureSource: .deepLink,
            locationOutcome: location,
            deliveryKind: .standard,
            placementOverride: .prepend,
            relativeNotePathOverride: "Fixtures/Draft.md",
            entryTemplateID: templateID,
            additionalPayloads: [.retainedAudio(asset, embedPlacement: .bottom)],
            stagedRecordingAudioReceipts: [requestID.uuidString.lowercased(): asset],
            appliedRecordingTranscriptIDs: [requestID]
        )
        let history = try CaptureHistoryRecord(
            requestID: requestID,
            createdAt: fixedDate,
            deliveredAt: fixedDate.addingTimeInterval(10),
            source: .watch,
            outcome: .delivered,
            destinationID: destinationID,
            destinationName: "Synthetic Vault",
            voxID: preset.id,
            voxName: preset.name,
            relativeNotePath: "Fixtures/Inbox.md",
            attachmentCount: 1
        )
        let job = RecordingJob(
            id: requestID,
            requestID: requestID.uuidString.lowercased(),
            captureSource: .watch,
            locationOutcome: location,
            audioFilename: "fixture.m4a",
            originalFilename: "watch-fixture.m4a",
            createdAt: fixedDate,
            duration: 42,
            source: .recovered,
            delivery: .preset(preset),
            modelID: "automatic",
            fallbackModelID: "ggml-base",
            language: "en",
            retentionPolicy: .timed(SourceAudioRetentionPolicy.defaultTimedRetention),
            processingPolicy: .manual,
            phase: .failed,
            failureStage: .delivery,
            statusMessage: "Synthetic failure",
            attemptCount: 2,
            revision: 3,
            transcriptText: "Synthetic transcript",
            exportedNotePath: "/synthetic/platform/path/Fixtures.md"
        )
        let handoff = RecordingJobHandoffIntent(
            jobID: requestID,
            readiness: .ready,
            audioFilename: "fixture.m4a",
            relatedAudioFilenames: ["fixture-segment.wav"],
            requestID: requestID.uuidString.lowercased(),
            captureSource: .watch,
            locationOutcome: location,
            createdAt: fixedDate,
            duration: 42,
            source: .recovered,
            delivery: .preset(preset),
            modelID: "automatic",
            fallbackModelID: "ggml-base",
            language: "en",
            configuration: RecordingQueueConfiguration(
                sourceAudioRetention: .timed(SourceAudioRetentionPolicy.defaultTimedRetention),
                processingPolicy: .manual
            )
        )

        try generateCaptureLibraryFixture(
            at: root,
            library: library,
            libraryRelativePath: "capture-library/library-v1.json"
        )
        try writeJSON(preset, to: root, relativePath: "presets/preset-v1.json", sorted: true)
        try generatePresetStoreCompatibilityFixtures(at: root, preset: preset)
        try generateCaptureDraftFixtures(
            at: root,
            draft: draft,
            request: request,
            draftRelativePath: "drafts/draft-current.json",
            preparedRelativePath: "drafts/prepared-request.json"
        )
        try write(
            Data(try replacingJSONValue(in: draft, keyPath: ["captureSource"], with: "futureSource").utf8),
            to: root,
            relativePath: "negative/drafts/unknown-source-enum.json"
        )
        try write(
            Data("{synthetic corrupt draft".utf8),
            to: root,
            relativePath: "drafts/corrupt-input.json"
        )
        try generateCaptureInboxStateFixtures(at: root, request: request)
        try generateCaptureInboxCompatibilityFixtures(at: root, request: request)
        try generateCaptureInboxCompletionFixture(
            at: root,
            request: request,
            completedAt: fixedDate,
            receiptRelativePath: "inbox/completion-receipt-v1.json"
        )
        try generateCaptureHistoryFixture(
            at: root,
            records: [history],
            historyRelativePath: "history/history-v1.json"
        )
        try generateCaptureHistoryCompatibilityFixtures(at: root)
        try write(
            Data("{synthetic corrupt history".utf8),
            to: root,
            relativePath: "history/corrupt-input.json"
        )
        try writeJSON(job, to: root, relativePath: "recording-jobs/job-v1.json", sorted: true)
        try write(
            Data(try replacingJSONValue(in: job, keyPath: ["phase"], with: "futurePhase").utf8),
            to: root,
            relativePath: "negative/recording-jobs/unknown-phase-enum.json"
        )
        try generateRecordingJobRecoveryFixtures(at: root, baseJob: job)
        try generateRecordingJobCheckpointFixtures(at: root, baseJob: job)
        try writeJSON(handoff, to: root, relativePath: "recording-jobs/handoff-v1.json", sorted: true)
        let markerArtifactURL = root.appendingPathComponent("recording-jobs/delivered-source.m4a")
        try write(Data(repeating: 5, count: 16), to: root, relativePath: "recording-jobs/delivered-source.m4a")
        try RecordingArtifactDeliveryReceipt.write(for: markerArtifactURL)
        try generateExternalDeliveryTransactionFixtures(at: root)
        try generateExternalDeliveryTransactionNegativeFixtures(at: root)
        try writeJSON(SyntheticWatchInboxItem.fixture(preset: preset, location: location), to: root, relativePath: "watch-inbox/item-current.json", sorted: true)
        try generateWatchInboxCompatibilityFixtures(at: root)
        try writeJSON(SyntheticWatchInboxItem.legacy, to: root, relativePath: "watch-inbox/item-legacy.json", sorted: true)
        let transcript = Transcript(
            id: requestID,
            text: "Synthetic transcript",
            date: fixedDate,
            duration: 42,
            modelUsed: "automatic",
            language: "en",
            speakerTurns: [
                TranscriptSpeakerTurn(
                    id: templateID,
                    speaker: 0,
                    text: "Synthetic speaker turn",
                    startTime: 0,
                    endTime: 4
                )
            ],
            title: "Synthetic title",
            tags: ["fixture"],
            category: "test",
            cleanedText: "Synthetic transcript."
        )
        try generateTranscriptFixture(
            at: root,
            transcript: transcript,
            transcriptRelativePath: "transcripts/transcripts.json"
        )
        try generateTranscriptCompatibilityFixtures(at: root)
        try generateActivityStatsFixture(
            at: root,
            recording: RecordingActivityEvent(id: requestID, date: fixedDate, duration: 42),
            capture: CaptureActivityEvent(id: requestID, date: fixedDate, source: .watch, attachmentCount: 1),
            statsRelativePath: "stats/activity-stats-v1.json"
        )
        try generateActivityStatsCompatibilityFixtures(at: root)
        try generateCaptureUsageFixture(
            at: root,
            request: request,
            ledgerRelativePath: "usage/capture-usage-v1.json"
        )
        try generateCaptureUsageCompatibilityFixtures(at: root)
        try generateTranscriptionUsageNegativeFixtures(at: root)
        try generateQueuePreferenceNegativeFixtures(at: root)
        try generateModelSelectionNegativeFixtures(at: root)
        try generateRecordingOriginFixture(
            at: root,
            snapshot: CaptureRecordingOriginSnapshot(
                presetID: preset.id,
                source: .watch,
                outcome: location
            ),
            recordingID: requestID.uuidString.lowercased(),
            originRelativePath: "recording-origin/origin-v1.json"
        )
        try generateRecordingOriginCompatibilityFixtures(at: root)
        try writeJSON(
            TranscriptionRequest(
                compatibilityFixtureID: requestID.uuidString.lowercased(),
                audioFileName: "fixture.m4a",
                modelId: "automatic",
                language: "en",
                createdAt: fixedDate.timeIntervalSince1970
            ),
            to: root,
            relativePath: "keyboard-ipc/request.json",
            sorted: true
        )
        try writeJSON(
            TranscriptionResponse(
                requestId: requestID.uuidString.lowercased(),
                text: "Synthetic transcript",
                usesLiveTranscription: true
            ),
            to: root,
            relativePath: "keyboard-ipc/response.json",
            sorted: true
        )
        try writeJSON(
            RecordingStatus(
                requestId: requestID.uuidString.lowercased(),
                phase: .transcribing,
                message: "Synthetic status",
                recordingStartedAt: fixedDate.timeIntervalSince1970,
                recordingStoppedAt: fixedDate.addingTimeInterval(42).timeIntervalSince1970,
                transcriptionProgress: 0.5,
                updatedAt: fixedDate.addingTimeInterval(43).timeIntervalSince1970
            ),
            to: root,
            relativePath: "keyboard-ipc/status.json",
            sorted: true
        )
        try writeJSON(
            RecordingCommand(
                requestId: requestID.uuidString.lowercased(),
                action: .stopSegment,
                modelId: "automatic",
                language: "en",
                flowId: preset.id,
                origin: .keyboardExtension
            ),
            to: root,
            relativePath: "keyboard-ipc/command.json",
            sorted: true
        )
        try writeJSON(
            ListeningState(
                isListening: true,
                startedAt: fixedDate.timeIntervalSince1970,
                lastHeartbeatAt: fixedDate.addingTimeInterval(1).timeIntervalSince1970
            ),
            to: root,
            relativePath: "keyboard-ipc/listening-state.json",
            sorted: true
        )
        try writeJSON(
            LiveTranscriptionSnapshot(
                requestId: requestID.uuidString.lowercased(),
                revision: 3,
                finalizedText: "Synthetic finalized text",
                volatileText: "synthetic tail",
                updatedAt: fixedDate.timeIntervalSince1970
            ),
            to: root,
            relativePath: "keyboard-ipc/live-transcription.json",
            sorted: true
        )
        try writeJSON(
            LiveTranscriptionDeliveryCheckpoint(
                requestId: requestID.uuidString.lowercased(),
                revision: 3,
                deliveredText: "Synthetic finalized text"
            ),
            to: root,
            relativePath: "keyboard-ipc/live-delivery-checkpoint.json",
            sorted: true
        )
        var audioLevel: Float = 0.25
        try write(
            Data(bytes: &audioLevel, count: MemoryLayout<Float>.size),
            to: root,
            relativePath: "keyboard-ipc/audio-level.bin"
        )
        try write(
            Data("Synthetic pending text".utf8),
            to: root,
            relativePath: "keyboard-ipc/pending-text.txt"
        )
        try write(
            Data([0, 0, 0, 0]),
            to: root,
            relativePath: "keyboard-ipc/retained-audio.m4a"
        )
        try writeJSON(
            VoxboardLiveActivityState(
                isSegmentActive: true,
                isTranscribing: false,
                segmentStartedAt: fixedDate.timeIntervalSince1970,
                segmentRequestId: requestID.uuidString.lowercased(),
                transcriptionProgress: 0.5
            ),
            to: root,
            relativePath: "live-state/live-activity-state.json",
            sorted: true
        )
        try generateKeyboardIPCCompatibilityFixtures(at: root)
        try generateLiveActivityCompatibilityFixtures(at: root)
        try generateSettingsFixture(
            at: root,
            preset: preset,
            settingsRelativePath: "settings/allowlisted-settings-v1.json"
        )

        let watchContext = syntheticWatchContext(preset: preset)
        let watchMetadata = syntheticWatchFileMetadata(preset: preset, location: location)
        try writePropertyList(watchContext, to: root, relativePath: "watch-property-lists/application-context.xml", format: .xml)
        try writePropertyList(watchContext, to: root, relativePath: "watch-property-lists/application-context.binary.plist", format: .binary)
        try writePropertyList(
            syntheticLegacyWatchContext(),
            to: root,
            relativePath: "watch-property-lists/application-context-legacy-minimal.xml",
            format: .xml
        )
        try writePropertyList(watchMetadata, to: root, relativePath: "watch-property-lists/file-metadata.xml", format: .xml)
        try writePropertyList(watchMetadata, to: root, relativePath: "watch-property-lists/file-metadata.binary.plist", format: .binary)
        try writePropertyList(
            syntheticLegacyWatchFileMetadata(),
            to: root,
            relativePath: "watch-property-lists/file-metadata-legacy-minimal.xml",
            format: .xml
        )
        try writePropertyList(
            syntheticMalformedWatchFileMetadata(),
            to: root,
            relativePath: "watch-property-lists/file-metadata-incompatible.xml",
            format: .xml
        )
        for command in ["start", "stop", "toggle", "status", "acknowledge", "selectPreset"] {
            try writePropertyList(
                syntheticWatchCommand(command),
                to: root,
                relativePath: "watch-property-lists/commands/\(command).xml",
                format: .xml
            )
        }
        for outcome in ["accepted", "rejected", "stale"] {
            try writePropertyList(
                syntheticWatchPresetAcknowledgement(outcome: outcome),
                to: root,
                relativePath: "watch-property-lists/preset-acknowledgements/\(outcome).xml",
                format: .xml
            )
        }
        try generateWatchDefaultsFixtures(at: root, preset: preset)
        try generateWatchLocalQueueFixtures(at: root, preset: preset, location: location)

        let unknownFieldFixtures: [String: String] = [
            "capture-library/unknown-field.json": try addingUnknownField(to: library),
            "drafts/unknown-field.json": try addingUnknownField(to: draft),
            "recording-jobs/unknown-field.json": try addingUnknownField(to: job),
            "keyboard-ipc/unknown-field.json": try addingUnknownField(
                to: RecordingStatus(
                    requestId: requestID.uuidString.lowercased(),
                    phase: .recording,
                    updatedAt: fixedDate.timeIntervalSince1970
                )
            ),
        ]
        for (relativePath, text) in unknownFieldFixtures {
            try write(Data(text.utf8), to: root, relativePath: "compatibility/\(relativePath)")
        }

        var futureJobObject = try JSONSerialization.jsonObject(
            with: deterministicEncoded(job)
        ) as! [String: Any]
        futureJobObject["schemaVersion"] = 99
        let futureJobData = try JSONSerialization.data(
            withJSONObject: futureJobObject,
            options: [.prettyPrinted, .sortedKeys]
        )

        let malformed: [String: String] = [
            "capture-library/future-version.json": #"{"schemaVersion":99,"destinations":[],"entryTemplates":[]}"#,
            "capture-library/unknown-note-target-enum.json": try replacingJSONValue(
                in: library,
                keyPath: ["destinations", "0", "noteTarget", "kind"],
                with: "futureNoteTarget"
            ),
            "presets/unknown-kind.json": #"{"id":"fixture","name":"Fixture","symbolName":"waveform","kind":"futureKind"}"#,
            "presets/malformed-store.bin": "not-json",
            "capture-library/malformed-bookmark.json": #"{"schemaVersion":1,"destinations":[{"id":"11111111-2222-3333-4444-555555555555","name":"Inbox","rootBookmark":"***","rootName":"Vault","noteTarget":{"kind":"existingNote","relativePath":"Inbox.md"}}],"entryTemplates":[]}"#,
            "drafts/missing-id.json": #"{"requestID":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","createdAt":721692800,"updatedAt":721692800}"#,
            "inbox/future-completion-receipt.json": #"{"schemaVersion":99,"requestID":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","completedAt":721692800}"#,
            "history/future-version.json": #"{"schemaVersion":99,"records":[]}"#,
            "stats/future-version.json": #"{"schemaVersion":99,"recordings":[],"captures":[]}"#,
            "usage/future-version.json": #"{"schemaVersion":99,"unattributedSuccessfulCount":0,"committedRequestIDs":[],"reservationTokensByRequestID":[]}"#,
            "usage/malformed.json": #"{"schemaVersion":1,"unattributedSuccessfulCount":"wrong"}"#,
            "keyboard-ipc/unknown-status-phase.json": #"{"requestId":"fixture","phase":"futurePhase"}"#,
            "keyboard-ipc/unknown-command-action.json": #"{"requestId":"fixture","action":"futureAction"}"#,
            "watch-inbox/malformed.json": #"{"id":"fixture","filename":42}"#,
            "settings/wrong-types.json": #"{"schemaVersion":1,"values":{"recordingQueue.processingPolicy.v1":{"type":"int64","value":-1.5}}}"#,
            "settings/future-version.json": #"{"schemaVersion":99,"values":{}}"#,
            "watch-defaults/confirmed-missing-id.json": #"{"displayName":"Missing ID","snapshot":"AQID"}"#,
            "watch-defaults/pending-wrong-sequence.json": #"{"requestID":"bad","presetID":"fixture","epoch":1,"sequence":"wrong","sentAt":1700000000}"#,
        ]
        for (relativePath, text) in malformed {
            try write(Data(text.utf8), to: root, relativePath: "negative/\(relativePath)")
        }
        try write(
            futureJobData,
            to: root,
            relativePath: "negative/recording-jobs/future-job-version.json"
        )

        var entries: [FixtureManifest.Entry] = []
        for url in try recursiveFiles(at: root) where url.lastPathComponent != "manifest.json" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let data = try Data(contentsOf: url)
            entries.append(.init(path: relative, byteCount: data.count, sha256: sha256(data)))
        }
        let generatorData = try Data(contentsOf: URL(fileURLWithPath: #filePath))
        let manifest = FixtureManifest(
            schemaVersion: 1,
            planningParentCommit: "b50167aebb959e394908af3a5949f43fa88d6265",
            producerRevision: "uncommitted-determinism-candidate-worktree",
            generatorPath: "Packages/VoxboardShared/Sources/VoxboardPersistenceFixtures/main.swift",
            generatorSHA256: sha256(generatorData),
            producer: "VoxboardPersistenceFixtures using production package codecs; app-target Watch and toolbar fixtures are validated by VoxboardTests",
            privacy: "Fixed synthetic values only; no user defaults, App Group, bookmarks, media library, location, microphone, or WCSession access.",
            foundationWire: "Default Foundation JSON: Date numeric seconds since 2001-01-01, Data base64, UUID string, raw enum string.",
            entries: entries.sorted { $0.path < $1.path }
        )
        try writeJSON(manifest, to: root, relativePath: "manifest.json", sorted: true)
    }

    private static func validate(at root: URL) throws {
        var exercisedPaths = Set<String>()
        func exercise(_ paths: String...) {
            exercisedPaths.formUnion(paths)
        }
        let manifest: FixtureManifest = try decodeJSON(at: root, relativePath: "manifest.json")
        let generatorURL = URL(fileURLWithPath: #filePath)
        let generatorDigest = sha256(try Data(contentsOf: generatorURL))
        guard manifest.schemaVersion == 1,
              manifest.planningParentCommit == "b50167aebb959e394908af3a5949f43fa88d6265",
              manifest.producerRevision == "uncommitted-determinism-candidate-worktree",
              manifest.generatorPath == "Packages/VoxboardShared/Sources/VoxboardPersistenceFixtures/main.swift",
              manifest.generatorSHA256 == generatorDigest,
              manifest.producer == "VoxboardPersistenceFixtures using production package codecs; app-target Watch and toolbar fixtures are validated by VoxboardTests" else {
            throw FixtureError.invalidManifest
        }
        let actualPaths = Set(try recursiveFiles(at: root).map {
            $0.path.replacingOccurrences(of: root.path + "/", with: "")
        }.filter { $0 != "manifest.json" })
        let expectedPaths = Set(manifest.entries.map(\.path))
        guard actualPaths == expectedPaths else {
            throw FixtureError.fixtureSetDrift(expected: expectedPaths, actual: actualPaths)
        }
        for entry in manifest.entries {
            let data = try Data(contentsOf: root.appendingPathComponent(entry.path))
            guard entry.sha256.count == 64,
                  entry.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  data.count == entry.byteCount,
                  sha256(data) == entry.sha256 else {
                throw FixtureError.fixtureHashMismatch(entry.path)
            }
        }

        let externallyExercisedPrefixes = [
            "watch-defaults/",
            "watch-inbox/",
            "watch-local-queue/",
            "watch-property-lists/",
            "negative/watch-defaults/",
            "negative/watch-inbox/",
            "compatibility/watch-inbox/",
        ]
        let packageOwnedPaths = Set(expectedPaths.filter { path in
            !externallyExercisedPrefixes.contains { path.hasPrefix($0) }
        })

        let library = try validateCaptureLibraryFixture(
            at: root,
            libraryRelativePath: "capture-library/library-v1.json"
        )
        guard library.schemaVersion == 1,
              library.destinations.first?.rootBookmark == Data([0, 1, 2, 255]),
              library.entryTemplates.first?.id == templateID else { throw FixtureError.semanticMismatch("library") }
        exercise("capture-library/library-v1.json")
        let preset: CapturePreset = try decodeJSON(at: root, relativePath: "presets/preset-v1.json")
        guard preset.watchOutputMode == .recordingOnly,
              preset.watchRecordingSettings.folderBookmark == Data([9, 8, 7]),
              preset.speakerDiarizationEnabled else { throw FixtureError.semanticMismatch("preset") }
        exercise("presets/preset-v1.json")
        let (draft, prepared) = try validateCaptureDraftFixtures(
            at: root,
            draftRelativePath: "drafts/draft-current.json",
            preparedRelativePath: "drafts/prepared-request.json"
        )
        try validateCaptureDraftRecoveryFixtures(at: root, draft: draft, request: prepared)
        guard draft.id == requestID,
              draft.locationOutcome == .unavailable(.timeout, attemptedAt: fixedDate) else { throw FixtureError.semanticMismatch("draft") }
        exercise("drafts/draft-current.json", "drafts/corrupt-input.json")
        guard prepared.id == requestID, prepared.payloads.count == 2 else { throw FixtureError.semanticMismatch("prepared request") }
        try validateCaptureInboxStateFixtures(at: root, requestID: requestID)
        try validateCaptureInboxCompatibilityFixtures(at: root, requestID: requestID)
        exercise(
            "compatibility/inbox/pending-unknown-field.json",
            "compatibility/inbox/completed-unknown-field.json",
            "negative/inbox/pending-missing-optional-fields.json",
            "negative/inbox/pending-missing-required-field.json",
            "negative/inbox/pending-unknown-source-enum.json"
        )
        exercise(
            "drafts/prepared-request.json",
            "inbox/pending-request.json",
            "inbox/processing-request.json",
            "inbox/failed-request.json"
        )
        try validateCaptureHistoryFixture(
            at: root,
            historyRelativePath: "history/history-v1.json",
            expectedRequestID: requestID
        )
        try validateCaptureHistoryCompatibilityFixtures(at: root)
        exercise(
            "compatibility/history/unknown-field.json",
            "negative/history/unknown-source-enum.json"
        )
        try validateCaptureHistoryQuarantineFixture(at: root)
        exercise("history/history-v1.json", "history/corrupt-input.json")
        try validateCaptureInboxCompletionFixture(
            at: root,
            requestID: requestID,
            receiptRelativePath: "inbox/completion-receipt-v1.json"
        )
        exercise("inbox/completion-receipt-v1.json")
        let job: RecordingJob = try decodeJSON(at: root, relativePath: "recording-jobs/job-v1.json")
        guard job.schemaVersion == 1, job.phase == .failed, job.processingPolicy == .manual else { throw FixtureError.semanticMismatch("recording job") }
        exercise("recording-jobs/job-v1.json")
        try validateRecordingJobRecoveryFixtures(at: root)
        exercise(
            "recording-jobs/recovery/processing-with-audio.json",
            "recording-jobs/recovery/finalizing-with-audio.json",
            "recording-jobs/recovery/queued-missing-audio.json",
            "recording-jobs/recovery/completed-deleted-audio.json",
            "recording-jobs/recovery/orphan-audio.wav"
        )
        try validateRecordingJobCheckpointFixtures(at: root)
        exercise(
            "recording-jobs/checkpoints/transcript.json",
            "recording-jobs/checkpoints/audio.json",
            "recording-jobs/checkpoints/note.json",
            "recording-jobs/checkpoints/reference.json",
            "recording-jobs/delivered-source.m4a",
            "recording-jobs/delivered-source.m4a.vox-delivered"
        )
        let handoff: RecordingJobHandoffIntent = try decodeJSON(at: root, relativePath: "recording-jobs/handoff-v1.json")
        guard handoff.readiness == .ready, handoff.relatedAudioFilenames == ["fixture-segment.wav"] else { throw FixtureError.semanticMismatch("recording handoff") }
        exercise("recording-jobs/handoff-v1.json")
        try validateExternalDeliveryTransactionFixtures(at: root)
        try validateExternalDeliveryTransactionNegativeFixtures(at: root)
        exercise(
            "recording-jobs/delivery-journals/note/journal.json",
            "recording-jobs/delivery-journals/note/payload",
            "recording-jobs/delivery-journals/audio/journal.json",
            "recording-jobs/delivery-journals/audio/payload",
            "recording-jobs/delivery-journals/noteAudioReference/journal.json",
            "recording-jobs/delivery-journals/noteAudioReference/payload",
            "negative/recording-jobs/delivery-journals/payload-only/payload",
            "negative/recording-jobs/delivery-journals/journal-only/journal.json",
            "negative/recording-jobs/delivery-journals/future-version/journal.json",
            "negative/recording-jobs/delivery-journals/future-version/payload",
            "negative/recording-jobs/delivery-journals/digest-mismatch/journal.json",
            "negative/recording-jobs/delivery-journals/digest-mismatch/payload",
            "negative/recording-jobs/delivery-journals/unknown-field/journal.json",
            "negative/recording-jobs/delivery-journals/unknown-field/payload"
        )
        let watchItem: SyntheticWatchInboxItem = try decodeJSON(at: root, relativePath: "watch-inbox/item-current.json")
        guard watchItem.requestID == requestID, watchItem.phase == "failed" else { throw FixtureError.semanticMismatch("watch inbox") }
        try validateSettingsFixture(
            at: root,
            settingsRelativePath: "settings/allowlisted-settings-v1.json",
            expectedPresetID: preset.id
        )
        exercise("settings/allowlisted-settings-v1.json")
        try validateTranscriptFixture(
            at: root,
            transcriptRelativePath: "transcripts/transcripts.json",
            expectedID: requestID
        )
        try validateTranscriptCompatibilityFixtures(at: root)
        exercise(
            "transcripts/transcripts.json",
            "compatibility/transcripts/unknown-field.json",
            "negative/transcripts/malformed.json"
        )
        try validateActivityStatsFixture(
            at: root,
            statsRelativePath: "stats/activity-stats-v1.json"
        )
        try validateActivityStatsCompatibilityFixtures(at: root)
        exercise(
            "stats/activity-stats-v1.json",
            "compatibility/stats/missing-schema-version.json",
            "compatibility/stats/unknown-field.json",
            "negative/stats/unknown-source-enum.json"
        )
        try validateCaptureUsageFixture(
            at: root,
            ledgerRelativePath: "usage/capture-usage-v1.json"
        )
        try validateCaptureUsageCompatibilityFixtures(at: root)
        try validateTranscriptionUsageNegativeFixtures(at: root)
        try validateQueuePreferenceNegativeFixtures(at: root)
        try validateModelSelectionNegativeFixtures(at: root)
        try validateLiveActivityCompatibilityFixtures(at: root)
        exercise(
            "usage/capture-usage-v1.json",
            "compatibility/usage/legacy-high-water-decimal.txt",
            "compatibility/usage/missing-default-fields.json",
            "compatibility/usage/unknown-field.json",
            "negative/usage-settings/wrong-types.json",
            "negative/usage-settings/unknown-access-level.json",
            "negative/queue-preferences/wrong-types.json",
            "negative/queue-preferences/unknown-enums.json",
            "negative/models/wrong-types.json",
            "negative/models/unknown-selection.json",
            "compatibility/live-state/unknown-field.json",
            "negative/live-state/malformed.json"
        )
        try validateRecordingOriginFixture(
            at: root,
            originRelativePath: "recording-origin/origin-v1.json",
            recordingID: requestID.uuidString.lowercased(),
            expectedPresetID: preset.id
        )
        try validateRecordingOriginCompatibilityFixtures(at: root)
        exercise(
            "recording-origin/origin-v1.json",
            "compatibility/recording-origin/unknown-field.json",
            "negative/recording-origin/missing-preset-id.json",
            "negative/recording-origin/unknown-source-enum.json",
            "negative/recording-origin/malformed.json"
        )
        let transcriptionRequest: TranscriptionRequest = try decodeJSON(at: root, relativePath: "keyboard-ipc/request.json")
        let transcriptionResponse: TranscriptionResponse = try decodeJSON(at: root, relativePath: "keyboard-ipc/response.json")
        let recordingStatus: RecordingStatus = try decodeJSON(at: root, relativePath: "keyboard-ipc/status.json")
        let recordingCommand: RecordingCommand = try decodeJSON(at: root, relativePath: "keyboard-ipc/command.json")
        let listeningState: ListeningState = try decodeJSON(at: root, relativePath: "keyboard-ipc/listening-state.json")
        let liveSnapshot: LiveTranscriptionSnapshot = try decodeJSON(at: root, relativePath: "keyboard-ipc/live-transcription.json")
        let deliveryCheckpoint: LiveTranscriptionDeliveryCheckpoint = try decodeJSON(at: root, relativePath: "keyboard-ipc/live-delivery-checkpoint.json")
        guard transcriptionRequest.id == requestID.uuidString.lowercased(),
              transcriptionResponse.requestId == transcriptionRequest.id,
              recordingStatus.phase == .transcribing,
              recordingCommand.origin == .keyboardExtension,
              listeningState.isListening,
              liveSnapshot.revision == 3,
              deliveryCheckpoint.deliveredText == "Synthetic finalized text" else {
            throw FixtureError.semanticMismatch("keyboard IPC")
        }
        exercise(
            "keyboard-ipc/request.json", "keyboard-ipc/response.json", "keyboard-ipc/status.json",
            "keyboard-ipc/command.json", "keyboard-ipc/listening-state.json",
            "keyboard-ipc/live-transcription.json", "keyboard-ipc/live-delivery-checkpoint.json"
        )
        let audioLevelData = try Data(contentsOf: root.appendingPathComponent("keyboard-ipc/audio-level.bin"))
        let decodedAudioLevel = audioLevelData.withUnsafeBytes { bytes -> Float? in
            guard bytes.count == MemoryLayout<Float>.size else { return nil }
            var value: Float = 0
            withUnsafeMutableBytes(of: &value) { destination in
                destination.copyBytes(from: bytes)
            }
            return value
        }
        guard decodedAudioLevel == 0.25,
              try Data(contentsOf: root.appendingPathComponent("keyboard-ipc/pending-text.txt")) == Data("Synthetic pending text".utf8),
              try Data(contentsOf: root.appendingPathComponent("keyboard-ipc/retained-audio.m4a")) == Data([0, 0, 0, 0]) else {
            throw FixtureError.semanticMismatch("keyboard IPC raw files")
        }
        exercise(
            "keyboard-ipc/audio-level.bin", "keyboard-ipc/pending-text.txt",
            "keyboard-ipc/retained-audio.m4a"
        )
        let liveState: VoxboardLiveActivityState = try decodeJSON(at: root, relativePath: "live-state/live-activity-state.json")
        guard liveState.isSegmentActive, liveState.segmentRequestId == requestID.uuidString.lowercased() else { throw FixtureError.semanticMismatch("live state") }
        exercise("live-state/live-activity-state.json")
        for relative in [
            "watch-property-lists/application-context.xml",
            "watch-property-lists/application-context.binary.plist",
            "watch-property-lists/file-metadata.xml",
            "watch-property-lists/file-metadata.binary.plist",
        ] {
            let data = try Data(contentsOf: root.appendingPathComponent(relative))
            let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let dictionary = object as? [String: Any], !dictionary.isEmpty else {
                throw FixtureError.semanticMismatch(relative)
            }
        }
        exercise("presets/preset-v1.json")
        try validatePresetStoreCompatibilityFixtures(at: root)
        exercise(
            "compatibility/presets/unknown-field.json",
            "negative/presets/malformed-store.bin"
        )

        let defaultEncoded = try JSONEncoder().encode(SyntheticWireProbe(date: fixedDate, data: Data([0, 1, 2, 255]), id: requestID))
        let object = try JSONSerialization.jsonObject(with: defaultEncoded) as? [String: Any]
        let expectedReferenceDateSeconds = fixedDate.timeIntervalSinceReferenceDate
        guard let date = object?["date"] as? Double,
              abs(date - expectedReferenceDateSeconds) < 0.001,
              object?["data"] as? String == "AAEC/w==" else {
            throw FixtureError.foundationWireChanged
        }

        let unknownLibrary: CaptureLibraryEnvelope = try decodeJSON(
            at: root,
            relativePath: "compatibility/capture-library/unknown-field.json"
        )
        let unknownDraft: CaptureDraft = try decodeJSON(
            at: root,
            relativePath: "compatibility/drafts/unknown-field.json"
        )
        let unknownJob: RecordingJob = try decodeJSON(
            at: root,
            relativePath: "compatibility/recording-jobs/unknown-field.json"
        )
        let unknownStatus: RecordingStatus = try decodeJSON(
            at: root,
            relativePath: "compatibility/keyboard-ipc/unknown-field.json"
        )
        guard unknownLibrary.schemaVersion == 1,
              unknownDraft.id == requestID,
              unknownJob.id == requestID,
              unknownStatus.phase == .recording else {
            throw FixtureError.semanticMismatch("unknown fields")
        }
        exercise(
            "compatibility/capture-library/unknown-field.json",
            "compatibility/drafts/unknown-field.json",
            "compatibility/recording-jobs/unknown-field.json",
            "compatibility/keyboard-ipc/unknown-field.json"
        )
        for encoded in [
            try JSONEncoder().encode(unknownLibrary),
            try JSONEncoder().encode(unknownDraft),
            try JSONEncoder().encode(unknownJob),
            try JSONEncoder().encode(unknownStatus),
        ] {
            let rewritten = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            guard rewritten?["futureFixtureField"] == nil else {
                throw FixtureError.semanticMismatch("unknown field typed rewrite")
            }
        }

        do {
            _ = try CaptureLibraryEnvelope.decodeValidated(
                from: Data(contentsOf: root.appendingPathComponent("negative/capture-library/future-version.json"))
            )
            throw FixtureError.negativeFixtureAccepted("future library")
        } catch CaptureModelError.unsupportedSchemaVersion(99) {
            // Expected legacy behavior.
        }
        exercise("negative/capture-library/future-version.json")
        try assertDecodeRejected(
            CaptureLibraryEnvelope.self,
            at: root,
            relativePath: "negative/capture-library/unknown-note-target-enum.json",
            name: "unknown library note-target enum"
        )
        exercise("negative/capture-library/unknown-note-target-enum.json")
        do {
            let _: CaptureLibraryEnvelope = try decodeJSON(
                at: root,
                relativePath: "negative/capture-library/malformed-bookmark.json"
            )
            throw FixtureError.negativeFixtureAccepted("malformed bookmark")
        } catch DecodingError.dataCorrupted {
            // Expected Foundation Data decoding behavior.
        }
        exercise("negative/capture-library/malformed-bookmark.json")
        do {
            let _: CaptureDraft = try decodeJSON(at: root, relativePath: "negative/drafts/missing-id.json")
            throw FixtureError.negativeFixtureAccepted("draft missing ID")
        } catch DecodingError.keyNotFound {
            // Expected legacy behavior.
        }
        exercise("negative/drafts/missing-id.json")
        try assertDecodeRejected(
            CaptureDraft.self,
            at: root,
            relativePath: "negative/drafts/unknown-source-enum.json",
            name: "unknown draft source enum"
        )
        exercise("negative/drafts/unknown-source-enum.json")
        try assertDecodeRejected(
            RecordingJob.self,
            at: root,
            relativePath: "negative/recording-jobs/unknown-phase-enum.json",
            name: "unknown recording job phase"
        )
        exercise("negative/recording-jobs/unknown-phase-enum.json")
        try validateFutureRecordingJobFixture(
            at: root,
            jobRelativePath: "negative/recording-jobs/future-job-version.json",
            jobID: requestID
        )
        exercise("negative/recording-jobs/future-job-version.json")
        do {
            let _: SyntheticWatchInboxItem = try decodeJSON(
                at: root,
                relativePath: "negative/watch-inbox/malformed.json"
            )
            throw FixtureError.negativeFixtureAccepted("malformed Watch inbox item")
        } catch DecodingError.typeMismatch {
            // Expected for numeric filename.
        }
        do {
            let _: SyntheticSettingsSnapshot = try decodeJSON(
                at: root,
                relativePath: "negative/settings/wrong-types.json"
            )
            throw FixtureError.negativeFixtureAccepted("wrong settings value type")
        } catch DecodingError.typeMismatch {
            // Expected for a Double encoded where an Int64 value is declared.
        } catch DecodingError.dataCorrupted {
            // Foundation may classify a nonintegral Int64 payload as corrupted.
        }
        exercise("negative/settings/wrong-types.json")
        let futureSettings: SyntheticSettingsSnapshot = try decodeJSON(
            at: root,
            relativePath: "negative/settings/future-version.json"
        )
        guard futureSettings.schemaVersion == 99 else {
            throw FixtureError.semanticMismatch("future settings envelope")
        }
        exercise("negative/settings/future-version.json")
        try assertDecodeRejected(
            CapturePreset.self,
            at: root,
            relativePath: "negative/presets/unknown-kind.json",
            name: "unknown preset kind"
        )
        exercise("negative/presets/unknown-kind.json")
        try assertDecodeRejected(
            RecordingStatus.self,
            at: root,
            relativePath: "negative/keyboard-ipc/unknown-status-phase.json",
            name: "unknown recording status phase"
        )
        try assertDecodeRejected(
            RecordingCommand.self,
            at: root,
            relativePath: "negative/keyboard-ipc/unknown-command-action.json",
            name: "unknown recording command action"
        )
        exercise(
            "negative/keyboard-ipc/unknown-status-phase.json",
            "negative/keyboard-ipc/unknown-command-action.json"
        )
        try validateFutureActivityStatsFixture(at: root)
        exercise("negative/stats/future-version.json")
        try validateCaptureUsageNegativeFixtures(at: root)
        try validateKeyboardIPCCompatibilityFixtures(at: root)
        for name in [
            "request", "response", "status", "command", "listening-state",
            "live-snapshot", "live-delivery-checkpoint"
        ] {
            exercise(
                "compatibility/keyboard-ipc/documents/\(name).json",
                "negative/keyboard-ipc/documents/\(name).json"
            )
        }
        exercise(
            "negative/keyboard-ipc/crash/finalized-text-only.txt",
            "negative/keyboard-ipc/crash/torn-delivery-checkpoint.json",
            "negative/usage/future-version.json",
            "negative/usage/malformed.json"
        )
        try validateFutureCaptureInboxCompletionFixture(
            at: root,
            requestID: requestID,
            receiptRelativePath: "negative/inbox/future-completion-receipt.json"
        )
        exercise("negative/inbox/future-completion-receipt.json")
        try validateFutureCaptureHistoryFixture(
            at: root,
            historyRelativePath: "negative/history/future-version.json"
        )
        exercise("negative/history/future-version.json")

        let unexercisedPackagePaths = packageOwnedPaths.subtracting(exercisedPaths)
        guard unexercisedPackagePaths.isEmpty else {
            throw FixtureError.unexercisedFixtures(unexercisedPackagePaths)
        }
        try assertSyntheticPrivacy(root: root)
    }

    private static func generateWatchDefaultsFixtures(
        at root: URL,
        preset: CapturePreset
    ) throws {
        let confirmed: [String: Any] = [
            "id": preset.id,
            "displayName": preset.displayName,
            "snapshot": try deterministicEncoded(preset).base64EncodedString(),
        ]
        let pending: [String: Any] = [
            "requestID": requestID.uuidString.lowercased(),
            "presetID": preset.id,
            "epoch": Int64(1_700_000_000_000),
            "sequence": Int64(7),
            "sentAt": fixedDate.timeIntervalSince1970,
        ]
        try write(
            try JSONSerialization.data(withJSONObject: confirmed, options: [.sortedKeys]),
            to: root,
            relativePath: "watch-defaults/confirmed-v1.json"
        )
        try write(
            try JSONSerialization.data(withJSONObject: pending, options: [.sortedKeys]),
            to: root,
            relativePath: "watch-defaults/pending-v1.json"
        )
    }

    private static func generateWatchLocalQueueFixtures(
        at root: URL,
        preset: CapturePreset,
        location: CaptureLocationOutcome
    ) throws {
        let snapshot = try deterministicEncoded(preset).base64EncodedString()
        let current: [String: Any] = [
            "id": requestID.uuidString.lowercased(),
            "filename": "watch-\(requestID.uuidString.lowercased()).m4a",
            "createdAt": fixedDate.timeIntervalSinceReferenceDate,
            "duration": 42,
            "transportState": "transferring",
            "remotePhase": "queued",
            "remoteRevision": 3,
            "remoteMessage": "Synthetic queued state",
            "presetID": preset.id,
            "presetName": preset.displayName,
            "presetSnapshot": snapshot,
            "locationOutcome": try JSONSerialization.jsonObject(with: deterministicEncoded(location)),
        ]
        let legacy: [String: Any] = [
            "id": "legacy",
            "filename": "watch-legacy.m4a",
            "createdAt": fixedDate.timeIntervalSinceReferenceDate,
            "duration": 1,
        ]
        let active: [String: Any] = [
            "id": "active",
            "filename": "watch-active.m4a",
            "createdAt": fixedDate.timeIntervalSinceReferenceDate + 1,
            "duration": 2,
            "transportState": "transferring",
            "remoteRevision": 0,
        ]
        for (path, value) in [
            ("watch-local-queue/index-current.json", [current]),
            ("watch-local-queue/index-legacy.json", [legacy]),
            ("watch-local-queue/active-recording.json", active),
        ] as [(String, Any)] {
            try write(
                try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                to: root,
                relativePath: path
            )
        }
        try write(
            Data(repeating: 2, count: 16),
            to: root,
            relativePath: "watch-local-queue/watch-active.m4a"
        )
        try write(
            Data(repeating: 3, count: 16),
            to: root,
            relativePath: "watch-local-queue/watch-orphan.m4a"
        )
    }

    private static func generateExternalDeliveryTransactionFixtures(at root: URL) throws {
        let base = root
            .appendingPathComponent("recording-jobs", isDirectory: true)
            .appendingPathComponent("delivery-journals", isDirectory: true)
        for (artifact, target, payload, preimage) in [
            ("note", "/synthetic/fixture-note.md", Data("Synthetic note".utf8), nil),
            ("audio", "/synthetic/fixture-audio.m4a", Data(repeating: 7, count: 16), nil),
            (
                "noteAudioReference",
                "/synthetic/fixture-note.md",
                Data("Synthetic note\n\nAudio: fixture-audio.m4a\n".utf8),
                Data("Synthetic note".utf8)
            ),
        ] {
            try ExternalFileDeliveryTransaction(
                directoryURL: base.appendingPathComponent(artifact, isDirectory: true)
            ).prepareCompatibilityFixture(
                data: payload,
                targetPath: target,
                expectedExistingData: preimage
            )
        }
    }

    private static func generateExternalDeliveryTransactionNegativeFixtures(at root: URL) throws {
        let base = root
            .appendingPathComponent("negative/recording-jobs/delivery-journals", isDirectory: true)
        let payloadOnly = base.appendingPathComponent("payload-only", isDirectory: true)
        try FileManager.default.createDirectory(at: payloadOnly, withIntermediateDirectories: true)
        try Data("synthetic uncommitted stage".utf8).write(
            to: payloadOnly.appendingPathComponent("payload"),
            options: .atomic
        )

        let source = root.appendingPathComponent("recording-jobs/delivery-journals/note", isDirectory: true)
        for name in ["journal-only", "future-version", "digest-mismatch", "unknown-field"] {
            let destination = base.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: source.appendingPathComponent("journal.json"),
                to: destination.appendingPathComponent("journal.json")
            )
            if name != "journal-only" {
                try FileManager.default.copyItem(
                    at: source.appendingPathComponent("payload"),
                    to: destination.appendingPathComponent("payload")
                )
            }
        }
        let unknownURL = base.appendingPathComponent("unknown-field/journal.json")
        var unknown = try JSONSerialization.jsonObject(with: Data(contentsOf: unknownURL)) as! [String: Any]
        unknown["futureFixtureField"] = ["ignored": true]
        try JSONSerialization.data(withJSONObject: unknown, options: [.prettyPrinted, .sortedKeys])
            .write(to: unknownURL, options: .atomic)
        let futureURL = base.appendingPathComponent("future-version/journal.json")
        var future = try JSONSerialization.jsonObject(
            with: Data(contentsOf: futureURL)
        ) as! [String: Any]
        future["version"] = 99
        try JSONSerialization.data(withJSONObject: future, options: [.prettyPrinted, .sortedKeys])
            .write(to: futureURL, options: .atomic)
        try Data("changed payload".utf8).write(
            to: base.appendingPathComponent("digest-mismatch/payload"),
            options: .atomic
        )
    }

    private static func validateExternalDeliveryTransactionNegativeFixtures(at root: URL) throws {
        let source = root.appendingPathComponent(
            "negative/recording-jobs/delivery-journals",
            isDirectory: true
        )
        let temporary = root.appendingPathComponent(".delivery-journal-negative", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        func copyFixture(_ name: String) throws -> URL {
            let destination = temporary.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(
                at: source.appendingPathComponent(name, isDirectory: true),
                to: destination
            )
            return destination
        }

        let payloadOnly = try copyFixture("payload-only")
        guard try ExternalFileDeliveryTransaction(directoryURL: payloadOnly).resumeIfPrepared() == nil,
              !FileManager.default.fileExists(atPath: payloadOnly.appendingPathComponent("payload").path) else {
            throw FixtureError.semanticMismatch("payload-only delivery journal")
        }
        let journalOnly = try copyFixture("journal-only")
        do {
            _ = try ExternalFileDeliveryTransaction(directoryURL: journalOnly).resumeIfPrepared()
            throw FixtureError.negativeFixtureAccepted("journal-only delivery transaction")
        } catch ExternalFileDeliveryTransaction.TransactionError.incompleteJournal {}
        let unknown = try copyFixture("unknown-field")
        guard try ExternalFileDeliveryTransaction(directoryURL: unknown)
            .validateCompatibilityFixture().byteCount > 0 else {
            throw FixtureError.semanticMismatch("unknown-field delivery transaction")
        }
        let future = try copyFixture("future-version")
        do {
            _ = try ExternalFileDeliveryTransaction(directoryURL: future).resumeIfPrepared()
            throw FixtureError.negativeFixtureAccepted("future delivery transaction")
        } catch ExternalFileDeliveryTransaction.TransactionError.incompleteJournal {}
        let mismatch = try copyFixture("digest-mismatch")
        do {
            _ = try ExternalFileDeliveryTransaction(directoryURL: mismatch).resumeIfPrepared()
            throw FixtureError.negativeFixtureAccepted("changed delivery payload")
        } catch ExternalFileDeliveryTransaction.TransactionError.stagedPayloadChanged {}
    }

    private static func validateExternalDeliveryTransactionFixtures(at root: URL) throws {
        let base = root
            .appendingPathComponent("recording-jobs", isDirectory: true)
            .appendingPathComponent("delivery-journals", isDirectory: true)
        let expected: [(String, String, Int)] = [
            ("note", "/synthetic/fixture-note.md", 14),
            ("audio", "/synthetic/fixture-audio.m4a", 16),
            ("noteAudioReference", "/synthetic/fixture-note.md", 41),
        ]
        for (artifact, target, count) in expected {
            let fixture = try ExternalFileDeliveryTransaction(
                directoryURL: base.appendingPathComponent(artifact, isDirectory: true)
            ).validateCompatibilityFixture()
            guard fixture.targetPath == target, fixture.byteCount == count else {
                throw FixtureError.semanticMismatch("\(artifact) delivery journal")
            }
        }
    }

    private static func generateCaptureLibraryFixture(
        at root: URL,
        library: CaptureLibraryEnvelope,
        libraryRelativePath: String
    ) throws {
        let temporaryURL = root.appendingPathComponent(".capture-library-producer.json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let store = CaptureLibraryStore(
            fileURL: temporaryURL,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        try waitForAsync { try await store.save(library) }
        try write(Data(contentsOf: temporaryURL), to: root, relativePath: libraryRelativePath)
    }

    private static func validateCaptureLibraryFixture(
        at root: URL,
        libraryRelativePath: String
    ) throws -> CaptureLibraryEnvelope {
        let temporaryURL = root.appendingPathComponent(".capture-library-validator.json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Data(contentsOf: root.appendingPathComponent(libraryRelativePath))
            .write(to: temporaryURL, options: .atomic)
        let store = CaptureLibraryStore(
            fileURL: temporaryURL,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        return try waitForAsync { try await store.load() }
    }

    private static func generateCaptureDraftFixtures(
        at root: URL,
        draft: CaptureDraft,
        request: CaptureRequest,
        draftRelativePath: String,
        preparedRelativePath: String
    ) throws {
        let temporaryRoot = root.appendingPathComponent(".capture-draft-producer", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let store = CaptureDraftStore(
            rootDirectoryURL: temporaryRoot,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        _ = try waitForAsync { try await store.save(draft, now: draft.captureStartedAt ?? fixedDate) }
        try waitForAsync { try await store.savePreparedRequest(request, draftID: draft.id) }
        let draftURL = temporaryRoot
            .appendingPathComponent("drafts")
            .appendingPathComponent(draft.id.uuidString.lowercased())
            .appendingPathExtension("json")
        let preparedURL = temporaryRoot
            .appendingPathComponent("prepared-requests")
            .appendingPathComponent(draft.id.uuidString.lowercased())
            .appendingPathExtension("json")
        try write(Data(contentsOf: draftURL), to: root, relativePath: draftRelativePath)
        try write(Data(contentsOf: preparedURL), to: root, relativePath: preparedRelativePath)
    }

    private static func validateCaptureDraftFixtures(
        at root: URL,
        draftRelativePath: String,
        preparedRelativePath: String
    ) throws -> (CaptureDraft, CaptureRequest) {
        let temporaryRoot = root.appendingPathComponent(".capture-draft-validator", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let drafts = temporaryRoot.appendingPathComponent("drafts", isDirectory: true)
        let prepared = temporaryRoot.appendingPathComponent("prepared-requests", isDirectory: true)
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        let filename = requestID.uuidString.lowercased() + ".json"
        try Data(contentsOf: root.appendingPathComponent(draftRelativePath))
            .write(to: drafts.appendingPathComponent(filename), options: .atomic)
        try Data(contentsOf: root.appendingPathComponent(preparedRelativePath))
            .write(to: prepared.appendingPathComponent(filename), options: .atomic)
        let store = CaptureDraftStore(
            rootDirectoryURL: temporaryRoot,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        guard let draft = try waitForAsync({ try await store.load(id: requestID) }),
              let request = try waitForAsync({ try await store.loadPreparedRequest(draftID: requestID) }) else {
            throw FixtureError.semanticMismatch("capture draft store")
        }
        return (draft, request)
    }

    private static func validateCaptureDraftRecoveryFixtures(
        at root: URL,
        draft: CaptureDraft,
        request: CaptureRequest
    ) throws {
        let temporaryRoot = root.appendingPathComponent(".capture-draft-recovery", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let store = CaptureDraftStore(
            rootDirectoryURL: temporaryRoot,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        try waitForAsync {
            _ = try await store.save(draft, now: fixedDate)
            try await store.savePreparedRequest(request, draftID: draft.id)
        }
        let staging = try waitForAsync { await store.stagingDirectoryURL(for: draft.id) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("synthetic staged asset".utf8).write(to: staging.appendingPathComponent("asset.bin"))
        try waitForAsync { try await store.complete(draftID: draft.id) }
        guard try waitForAsync({ try await store.load(id: draft.id) }) == nil,
              try waitForAsync({ try await store.loadPreparedRequest(draftID: draft.id) }) == nil,
              !FileManager.default.fileExists(atPath: staging.path) else {
            throw FixtureError.semanticMismatch("draft staging completion")
        }

        let corruptDraftURL = temporaryRoot
            .appendingPathComponent("drafts", isDirectory: true)
            .appendingPathComponent("corrupt.json")
        try FileManager.default.createDirectory(
            at: corruptDraftURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let corrupt = try Data(contentsOf: root.appendingPathComponent("drafts/corrupt-input.json"))
        try corrupt.write(to: corruptDraftURL)
        let loaded = try waitForAsync { try await store.loadAll() }
        let quarantine = temporaryRoot.appendingPathComponent("drafts-corrupt", isDirectory: true)
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: quarantine,
            includingPropertiesForKeys: nil
        )
        guard loaded.isEmpty,
              quarantined.count == 1,
              try Data(contentsOf: quarantined[0]) == corrupt else {
            throw FixtureError.semanticMismatch("draft quarantine")
        }
    }

    private static func generateRecordingJobRecoveryFixtures(
        at root: URL,
        baseJob: RecordingJob
    ) throws {
        let fixtureDirectory = root
            .appendingPathComponent("recording-jobs", isDirectory: true)
            .appendingPathComponent("recovery", isDirectory: true)
        var processing = baseJob
        processing.id = deterministicUUID(1)
        processing.audioFilename = "processing-with-audio.wav"
        processing.phase = .processing
        processing.failureStage = nil
        processing.statusMessage = "Synthetic processing crash"
        processing.attemptCount = 1
        processing.revision = 2
        try writeJSON(processing, to: root, relativePath: "recording-jobs/recovery/processing-with-audio.json", sorted: true)

        var finalizing = baseJob
        finalizing.id = deterministicUUID(2)
        finalizing.audioFilename = "finalizing-with-audio.wav"
        finalizing.phase = .finalizing
        finalizing.failureStage = nil
        finalizing.statusMessage = "Synthetic finalization crash"
        finalizing.attemptCount = 1
        finalizing.revision = 4
        try writeJSON(finalizing, to: root, relativePath: "recording-jobs/recovery/finalizing-with-audio.json", sorted: true)

        var missingAudio = baseJob
        missingAudio.id = deterministicUUID(3)
        missingAudio.audioFilename = "queued-missing-audio.wav"
        missingAudio.phase = .queued
        missingAudio.failureStage = nil
        missingAudio.statusMessage = nil
        missingAudio.attemptCount = 0
        missingAudio.revision = 1
        try writeJSON(missingAudio, to: root, relativePath: "recording-jobs/recovery/queued-missing-audio.json", sorted: true)

        var completed = baseJob
        completed.id = deterministicUUID(4)
        completed.audioFilename = "completed-deleted-audio.wav"
        completed.phase = .completed
        completed.failureStage = nil
        completed.statusMessage = nil
        completed.completedAt = fixedDate
        completed.audioDeletionDate = fixedDate
        completed.audioDeletedAt = nil
        completed.revision = 5
        try writeJSON(completed, to: root, relativePath: "recording-jobs/recovery/completed-deleted-audio.json", sorted: true)

        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try write(Data(repeating: 1, count: 32), to: root, relativePath: "recording-jobs/recovery/orphan-audio.wav")
    }

    private static func validateRecordingJobRecoveryFixtures(at root: URL) throws {
        let temporaryRoot = root.appendingPathComponent(".recording-job-recovery-validator", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let items = temporaryRoot.appendingPathComponent("items", isDirectory: true)
        let audio = temporaryRoot.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: items, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)

        let cases = [
            ("processing-with-audio.json", deterministicUUID(1), true),
            ("finalizing-with-audio.json", deterministicUUID(2), true),
            ("queued-missing-audio.json", deterministicUUID(3), false),
            ("completed-deleted-audio.json", deterministicUUID(4), false),
        ]
        for (filename, id, hasAudio) in cases {
            let data = try Data(contentsOf: root
                .appendingPathComponent("recording-jobs/recovery")
                .appendingPathComponent(filename))
            try data.write(
                to: items.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("json"),
                options: .atomic
            )
            if hasAudio {
                let job = try JSONDecoder().decode(RecordingJob.self, from: data)
                try Data(repeating: 2, count: 16)
                    .write(to: audio.appendingPathComponent(job.audioFilename), options: .atomic)
            }
        }
        try Data(contentsOf: root.appendingPathComponent("recording-jobs/recovery/orphan-audio.wav"))
            .write(to: audio.appendingPathComponent("orphan-audio.wav"), options: .atomic)

        let store = RecordingJobStore(
            rootDirectoryURL: temporaryRoot,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        let recovered = try waitForAsync { try await store.load(recoverInterrupted: true) }
        let byID = Dictionary(uniqueKeysWithValues: recovered.map { ($0.id, $0) })
        guard byID[deterministicUUID(1)]?.phase == .queued,
              byID[deterministicUUID(2)]?.phase == .queued,
              byID[deterministicUUID(3)]?.phase == .failed,
              byID[deterministicUUID(3)]?.failureStage == .storage,
              byID[deterministicUUID(4)]?.phase == .completed,
              byID[deterministicUUID(4)]?.audioDeletedAt != nil,
              recovered.contains(where: {
                  $0.source == .recovered
                    && $0.delivery == .recovery
                    && $0.audioFilename == "orphan-audio.wav"
                    && $0.phase == .failed
              }) else {
            throw FixtureError.semanticMismatch("recording job recovery matrix")
        }
    }

    private static func deterministicUUID(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }

    private static func runOnMainActor<T>(
        _ operation: @escaping @MainActor () throws -> T
    ) throws -> T {
        if Thread.isMainThread {
            return try MainActor.assumeIsolated(operation)
        }
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>!
        DispatchQueue.main.async {
            result = Result { try MainActor.assumeIsolated(operation) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    private static func waitForAsync<T>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>!
        Task {
            do { result = .success(try await operation()) }
            catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    private static func generateRecordingJobCheckpointFixtures(
        at root: URL,
        baseJob: RecordingJob
    ) throws {
        let temporaryRoot = root.appendingPathComponent(".recording-job-checkpoint-producer", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let items = temporaryRoot.appendingPathComponent("items", isDirectory: true)
        let audio = temporaryRoot.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: items, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        var processing = baseJob
        processing.id = deterministicUUID(10)
        processing.audioFilename = "checkpoint.m4a"
        processing.phase = .processing
        processing.failureStage = nil
        processing.statusMessage = "Transcribing"
        processing.transcriptText = nil
        processing.exportedAudioPath = nil
        processing.exportedNotePath = nil
        processing.audioReferenceAttachedAt = nil
        let seed = try deterministicEncoded(processing)
        try seed.write(
            to: items.appendingPathComponent(processing.id.uuidString.lowercased()).appendingPathExtension("json"),
            options: .atomic
        )
        try Data(repeating: 6, count: 16)
            .write(to: audio.appendingPathComponent(processing.audioFilename), options: .atomic)
        let store = RecordingJobStore(
            rootDirectoryURL: temporaryRoot,
            coordinator: ProcessLocalCaptureFileCoordinator(),
            now: { fixedDate }
        )
        let checkpointID = processing.id
        let transcript = try waitForAsync {
            try await store.recordTranscriptCheckpoint(id: checkpointID, text: "Synthetic checkpoint")
        }
        try writeJSON(transcript, to: root, relativePath: "recording-jobs/checkpoints/transcript.json", sorted: true)
        let audioCheckpoint = try waitForAsync {
            try await store.markExportedAudio(id: checkpointID, path: "/synthetic/checkpoint.m4a")
        }
        try writeJSON(audioCheckpoint, to: root, relativePath: "recording-jobs/checkpoints/audio.json", sorted: true)
        let noteCheckpoint = try waitForAsync {
            try await store.markExportedNote(id: checkpointID, path: "/synthetic/checkpoint.md")
        }
        try writeJSON(noteCheckpoint, to: root, relativePath: "recording-jobs/checkpoints/note.json", sorted: true)
        let referenceCheckpoint = try waitForAsync {
            try await store.markAudioReferenceAttached(id: checkpointID, attachedAt: fixedDate)
        }
        try writeJSON(referenceCheckpoint, to: root, relativePath: "recording-jobs/checkpoints/reference.json", sorted: true)
    }

    private static func validateRecordingJobCheckpointFixtures(at root: URL) throws {
        let transcript: RecordingJob = try decodeJSON(
            at: root,
            relativePath: "recording-jobs/checkpoints/transcript.json"
        )
        let audio: RecordingJob = try decodeJSON(
            at: root,
            relativePath: "recording-jobs/checkpoints/audio.json"
        )
        let note: RecordingJob = try decodeJSON(
            at: root,
            relativePath: "recording-jobs/checkpoints/note.json"
        )
        let reference: RecordingJob = try decodeJSON(
            at: root,
            relativePath: "recording-jobs/checkpoints/reference.json"
        )
        guard transcript.transcriptText == "Synthetic checkpoint",
              audio.exportedAudioPath == "/synthetic/checkpoint.m4a",
              note.exportedAudioPath == audio.exportedAudioPath,
              note.exportedNotePath == "/synthetic/checkpoint.md",
              reference.audioReferenceAttachedAt == fixedDate else {
            throw FixtureError.semanticMismatch("recording job checkpoint matrix")
        }
        let markerArtifactURL = root.appendingPathComponent("recording-jobs/delivered-source.m4a")
        guard RecordingArtifactDeliveryReceipt.exists(for: markerArtifactURL),
              try Data(contentsOf: RecordingArtifactDeliveryReceipt.markerURL(for: markerArtifactURL))
                == Data("voxboard-delivered-v1\n".utf8) else {
            throw FixtureError.semanticMismatch("recording delivery receipt")
        }
    }

    private static func generateSettingsFixture(
        at root: URL,
        preset: CapturePreset,
        settingsRelativePath: String
    ) throws {
        let defaults = try isolatedDefaults(named: "producer")
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName("producer")) }

        CapturePresetStore.saveFlows([preset], defaults: defaults)
        CapturePresetStore.selectFlow(id: preset.id, defaults: defaults)
        RecordingQueuePreferences.save(
            RecordingQueueConfiguration(
                sourceAudioRetention: .timed(SourceAudioRetentionPolicy.defaultTimedRetention),
                processingPolicy: .manual
            ),
            to: defaults
        )
        let tracker = UsageTracker(defaults: defaults)
        tracker.addUsage(seconds: 42, deliveryID: requestID)
        let modelSelection = try runOnMainActor {
            let manager = ModelManager(defaults: UserDefaults(suiteName: defaultsSuiteName("producer")))
            if let model = WhisperModelInfo.availableModels.first {
                manager.selectModel(model)
            }
            manager.selectedLanguage = "en"
            return (manager.selectedModelId, manager.selectedLanguage)
        }
        guard !modelSelection.0.isEmpty, modelSelection.1 == "en" else {
            throw FixtureError.semanticMismatch("model selection fixture producer")
        }
        let analyticsDefaults = SystemOnboardingAnalyticsUserDefaults(defaults: defaults)
        analyticsDefaults.set(
            requestID.uuidString.lowercased(),
            forKey: OnboardingAnalyticsInstallIDStore.defaultKey
        )
        guard OnboardingAnalyticsInstallIDStore(defaults: analyticsDefaults).installID()
            == requestID.uuidString.lowercased() else {
            throw FixtureError.semanticMismatch("analytics install identity producer")
        }
        let assignmentStore = OnboardingExperimentAssignmentStore(
            defaults: analyticsDefaults,
            now: { fixedDate }
        )
        _ = assignmentStore.assignment()
        let analytics = OnboardingAnalyticsClient(
            transport: OfflineOnboardingAnalyticsTransport(),
            defaults: analyticsDefaults,
            isEnabled: true,
            retryDelayNanoseconds: UInt64.max,
            assignmentStore: assignmentStore,
            runtimeContextProvider: { nil },
            eventIDProvider: { requestID.uuidString.lowercased() }
        )
        analytics.track(OnboardingAnalyticsEvent(name: .onboardingStarted))
        defaults.set(
            Data(#"{"hidden":["paste"],"order":["addMedia","currentLocation"]}"#.utf8),
            forKey: "capture.toolbar.configuration.v1"
        )
        defaults.set(Int64(1_700_000_000_000), forKey: "watchPresetSelection.epoch.v1")
        defaults.set(Int64(7), forKey: "watchPresetSelection.sequence.v1")

        let keys = [
            CapturePresetStore.flowsKey,
            CapturePresetStore.selectedFlowIdKey,
            RecordingQueuePreferences.retentionModeKey,
            RecordingQueuePreferences.retentionIntervalKey,
            RecordingQueuePreferences.processingPolicyKey,
            "totalTranscriptionSeconds",
            "transcriptionUsageReceiptBaselineV1",
            "transcriptionUsageReceiptsV1",
            "unlimitedAccessLevelV1",
            "permanentUnlimitedAccessLevelV1",
            "legacyUnlimitedAccessClassificationPendingV1",
            "hasUnlocked",
            AppConstants.selectedModelKey,
            AppConstants.selectedLanguageKey,
            AppConstants.selectedFallbackModelKey,
            OnboardingAnalyticsInstallIDStore.defaultKey,
            OnboardingExperimentAssignmentStore.defaultKey,
            OnboardingAnalyticsClient.defaultQueueKey,
            "capture.toolbar.configuration.v1",
            "watchPresetSelection.epoch.v1",
            "watchPresetSelection.sequence.v1",
        ]
        var values: [String: SyntheticSettingsSnapshot.Value] = [:]
        for key in keys {
            guard let object = defaults.object(forKey: key) else { continue }
            values[key] = try SyntheticSettingsSnapshot.Value(propertyListObject: object)
        }
        try writeJSON(
            SyntheticSettingsSnapshot(schemaVersion: 1, values: values),
            to: root,
            relativePath: settingsRelativePath,
            sorted: true
        )
    }

    private static func generatePresetStoreCompatibilityFixtures(
        at root: URL,
        preset: CapturePreset
    ) throws {
        let current = try deterministicEncoded([CapturePresetStore.defaultFlow, preset])
        guard var array = try JSONSerialization.jsonObject(with: current) as? [[String: Any]] else {
            throw FixtureError.semanticMismatch("preset store compatibility source")
        }
        array[1]["futureFixtureField"] = ["ignored": true]
        try write(
            JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted, .sortedKeys]),
            to: root,
            relativePath: "compatibility/presets/unknown-field.json"
        )
    }

    private static func validatePresetStoreCompatibilityFixtures(at root: URL) throws {
        let defaults = try isolatedDefaults(named: "preset-negative")
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName("preset-negative")) }
        let unknown = try Data(contentsOf: root.appendingPathComponent("compatibility/presets/unknown-field.json"))
        defaults.set(unknown, forKey: CapturePresetStore.flowsKey)
        let decoded = CapturePresetStore.loadFlows(defaults: defaults, persistMigrations: false)
        guard decoded.contains(where: { $0.id == "fixture" }) else {
            throw FixtureError.semanticMismatch("preset store unknown field")
        }
        defaults.set(
            try Data(contentsOf: root.appendingPathComponent("negative/presets/malformed-store.bin")),
            forKey: CapturePresetStore.flowsKey
        )
        guard CapturePresetStore.loadFlows(defaults: defaults, persistMigrations: false) == CapturePresetStore.defaultFlows,
              defaults.data(forKey: CapturePresetStore.flowsKey) == Data("not-json".utf8) else {
            throw FixtureError.semanticMismatch("preset store malformed fallback preservation")
        }
    }

    private static func validateSettingsFixture(
        at root: URL,
        settingsRelativePath: String,
        expectedPresetID: String
    ) throws {
        let snapshot: SyntheticSettingsSnapshot = try decodeJSON(
            at: root,
            relativePath: settingsRelativePath
        )
        guard snapshot.schemaVersion == 1 else {
            throw FixtureError.semanticMismatch("settings schema")
        }
        let defaults = try isolatedDefaults(named: "validator")
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName("validator")) }
        for (key, value) in snapshot.values {
            defaults.set(value.propertyListObject, forKey: key)
        }

        let presets = CapturePresetStore.loadFlows(defaults: defaults, persistMigrations: false)
        guard presets.contains(where: { $0.id == expectedPresetID }),
              presets.contains(where: { $0.id == CapturePresetStore.generalId }) else {
            throw FixtureError.semanticMismatch("preset settings store")
        }
        guard CapturePresetStore.selectedFlowId(defaults: defaults) == expectedPresetID else {
            throw FixtureError.semanticMismatch("selected preset settings store")
        }
        let queue = RecordingQueuePreferences.load(from: defaults)
        guard queue.processingPolicy == .manual,
              queue.sourceAudioRetention == .timed(SourceAudioRetentionPolicy.defaultTimedRetention) else {
            throw FixtureError.semanticMismatch("recording queue settings store")
        }
        let usage = UsageTracker(defaults: defaults)
        guard usage.totalSecondsUsed == 42,
              usage.accessLevel == .free,
              usage.isLegacyAccessClassificationPending == false else {
            throw FixtureError.semanticMismatch("usage settings store")
        }
        let modelSelection = try runOnMainActor {
            let manager = ModelManager(defaults: UserDefaults(suiteName: defaultsSuiteName("validator")))
            return (
                manager.selectedModelId,
                manager.selectedLanguage,
                manager.preferredFallbackModelID
            )
        }
        guard WhisperModelInfo.availableModels.contains(where: {
            $0.id == modelSelection.0
        }), modelSelection.1 == "en", modelSelection.2 == modelSelection.0 else {
            throw FixtureError.semanticMismatch("model selection settings store")
        }
        let analyticsDefaults = SystemOnboardingAnalyticsUserDefaults(defaults: defaults)
        let assignment = OnboardingExperimentAssignmentStore(
            defaults: analyticsDefaults,
            now: { fixedDate }
        ).assignment()
        let analytics = OnboardingAnalyticsClient(
            transport: OfflineOnboardingAnalyticsTransport(),
            defaults: analyticsDefaults,
            isEnabled: true,
            retryDelayNanoseconds: UInt64.max,
            runtimeContextProvider: { nil }
        )
        guard assignment.experimentId == OnboardingExperimentConfig.currentExperimentId,
              OnboardingAnalyticsInstallIDStore(defaults: analyticsDefaults).installID()
                == requestID.uuidString.lowercased(),
              try waitForAsync({ await analytics.queuedPayloads() }).count == 1 else {
            throw FixtureError.semanticMismatch("analytics settings store")
        }
        guard defaults.data(forKey: "capture.toolbar.configuration.v1") != nil,
              (defaults.object(forKey: "watchPresetSelection.epoch.v1") as? NSNumber)?.int64Value == 1_700_000_000_000,
              (defaults.object(forKey: "watchPresetSelection.sequence.v1") as? NSNumber)?.int64Value == 7 else {
            throw FixtureError.semanticMismatch("app-target settings payload")
        }
    }

    private static func defaultsSuiteName(_ role: String) -> String {
        "VoxboardPersistenceFixtures.\(role)"
    }

    private static func isolatedDefaults(named role: String) throws -> UserDefaults {
        let name = defaultsSuiteName(role)
        guard let defaults = UserDefaults(suiteName: name) else {
            throw FixtureError.semanticMismatch("isolated defaults")
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func generateTranscriptFixture(
        at root: URL,
        transcript: Transcript,
        transcriptRelativePath: String
    ) throws {
        let temporaryURL = root.appendingPathComponent(".transcripts-producer.json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let store = TranscriptStore(
            fileURL: temporaryURL,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        store.add(transcript)
        if let error = store.lastPersistenceError { throw error }
        try write(Data(contentsOf: temporaryURL), to: root, relativePath: transcriptRelativePath)
    }

    private static func generateTranscriptCompatibilityFixtures(at root: URL) throws {
        let data = try Data(contentsOf: root.appendingPathComponent("transcripts/transcripts.json"))
        guard var array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], !array.isEmpty else {
            throw FixtureError.semanticMismatch("transcript compatibility source")
        }
        array[0]["futureFixtureField"] = ["ignored": true]
        try write(
            JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted, .sortedKeys]),
            to: root,
            relativePath: "compatibility/transcripts/unknown-field.json"
        )
        try write(
            Data("[{synthetic malformed transcript]".utf8),
            to: root,
            relativePath: "negative/transcripts/malformed.json"
        )
    }

    private static func validateTranscriptCompatibilityFixtures(at root: URL) throws {
        try validateTranscriptFixture(
            at: root,
            transcriptRelativePath: "compatibility/transcripts/unknown-field.json",
            expectedID: requestID
        )
        let temporaryURL = root.appendingPathComponent(".transcript-malformed-validator.json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let source = try Data(contentsOf: root.appendingPathComponent("negative/transcripts/malformed.json"))
        try source.write(to: temporaryURL, options: .atomic)
        let store = TranscriptStore(fileURL: temporaryURL, coordinator: ProcessLocalCaptureFileCoordinator())
        guard store.transcripts.isEmpty,
              store.lastPersistenceError?.operation == .load,
              try Data(contentsOf: temporaryURL) == source else {
            throw FixtureError.semanticMismatch("malformed transcript surfaced and preserved")
        }
    }

    private static func validateTranscriptFixture(
        at root: URL,
        transcriptRelativePath: String,
        expectedID: UUID
    ) throws {
        let temporaryURL = root.appendingPathComponent(".transcripts-validator.json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Data(contentsOf: root.appendingPathComponent(transcriptRelativePath))
            .write(to: temporaryURL, options: .atomic)
        let store = TranscriptStore(
            fileURL: temporaryURL,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        guard store.lastPersistenceError == nil,
              store.transcripts.first?.id == expectedID else {
            throw FixtureError.semanticMismatch("transcript store")
        }
    }

    private static func generateActivityStatsFixture(
        at root: URL,
        recording: RecordingActivityEvent,
        capture: CaptureActivityEvent,
        statsRelativePath: String
    ) throws {
        let temporaryURL = root.appendingPathComponent(".activity-stats-producer.json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let store = ActivityStatsStore(
            fileURL: temporaryURL,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        _ = try store.record(recording)
        _ = try store.record(capture)
        try write(Data(contentsOf: temporaryURL), to: root, relativePath: statsRelativePath)
    }

    private static func generateActivityStatsCompatibilityFixtures(at root: URL) throws {
        let data = try Data(contentsOf: root.appendingPathComponent("stats/activity-stats-v1.json"))
        guard var ledger = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var captures = ledger["captures"] as? [[String: Any]], !captures.isEmpty else {
            throw FixtureError.semanticMismatch("activity stats compatibility source")
        }
        ledger.removeValue(forKey: "schemaVersion")
        try write(
            JSONSerialization.data(withJSONObject: ledger, options: [.prettyPrinted, .sortedKeys]),
            to: root,
            relativePath: "compatibility/stats/missing-schema-version.json"
        )
        ledger["schemaVersion"] = 1
        ledger["futureFixtureField"] = true
        captures[0]["futureEventField"] = ["ignored": true]
        ledger["captures"] = captures
        try write(
            JSONSerialization.data(withJSONObject: ledger, options: [.prettyPrinted, .sortedKeys]),
            to: root,
            relativePath: "compatibility/stats/unknown-field.json"
        )
        captures[0]["source"] = "futureSource"
        ledger["captures"] = captures
        try write(
            JSONSerialization.data(withJSONObject: ledger, options: [.prettyPrinted, .sortedKeys]),
            to: root,
            relativePath: "negative/stats/unknown-source-enum.json"
        )
    }

    private static func validateActivityStatsCompatibilityFixtures(at root: URL) throws {
        for relative in [
            "compatibility/stats/missing-schema-version.json",
            "compatibility/stats/unknown-field.json",
        ] {
            try validateActivityStatsFixture(at: root, statsRelativePath: relative)
        }
        let temporaryRoot = root.appendingPathComponent(".activity-stats-unknown-enum", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let fileURL = temporaryRoot.appendingPathComponent("stats.json")
        let source = try Data(contentsOf: root.appendingPathComponent("negative/stats/unknown-source-enum.json"))
        try source.write(to: fileURL, options: .atomic)
        let store = ActivityStatsStore(fileURL: fileURL, coordinator: ProcessLocalCaptureFileCoordinator())
        guard try store.load() == .empty else {
            throw FixtureError.semanticMismatch("activity stats unknown enum fallback")
        }
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: store.quarantineDirectoryURL,
            includingPropertiesForKeys: nil
        )
        guard quarantined.count == 1, try Data(contentsOf: quarantined[0]) == source else {
            throw FixtureError.semanticMismatch("activity stats unknown enum quarantine")
        }
    }

    private static func validateActivityStatsFixture(
        at root: URL,
        statsRelativePath: String
    ) throws {
        let temporaryURL = root.appendingPathComponent(".activity-stats-validator.json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Data(contentsOf: root.appendingPathComponent(statsRelativePath))
            .write(to: temporaryURL, options: .atomic)
        let store = ActivityStatsStore(
            fileURL: temporaryURL,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        let ledger = try store.load()
        guard ledger.schemaVersion == 1,
              ledger.recordings.count == 1,
              ledger.captures.count == 1 else {
            throw FixtureError.semanticMismatch("activity stats store")
        }
    }

    private static func validateFutureActivityStatsFixture(at root: URL) throws {
        let source = root.appendingPathComponent("negative/stats/future-version.json")
        let temporaryURL = root.appendingPathComponent(".activity-stats-future-validator.json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let data = try Data(contentsOf: source)
        try data.write(to: temporaryURL, options: .atomic)
        let store = ActivityStatsStore(
            fileURL: temporaryURL,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        do {
            _ = try store.load()
            throw FixtureError.negativeFixtureAccepted("future activity stats")
        } catch ActivityStatsStoreError.unsupportedSchemaVersion(99) {
            guard try Data(contentsOf: temporaryURL) == data else {
                throw FixtureError.semanticMismatch("future activity stats preservation")
            }
        }
    }

    private static func generateKeyboardIPCCompatibilityFixtures(at root: URL) throws {
        let documents: [(String, String)] = [
            ("request", "request.json"),
            ("response", "response.json"),
            ("status", "status.json"),
            ("command", "command.json"),
            ("listening-state", "listening-state.json"),
            ("live-snapshot", "live-transcription.json"),
            ("live-delivery-checkpoint", "live-delivery-checkpoint.json"),
        ]
        for (name, sourceName) in documents {
            let source = root.appendingPathComponent("keyboard-ipc/\(sourceName)")
            let data = try Data(contentsOf: source)
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw FixtureError.semanticMismatch("keyboard IPC compatibility source \(name)")
            }
            object["futureFixtureField"] = ["ignored": true]
            try write(
                JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
                to: root,
                relativePath: "compatibility/keyboard-ipc/documents/\(name).json"
            )
            try write(
                Data("{synthetic malformed \(name)".utf8),
                to: root,
                relativePath: "negative/keyboard-ipc/documents/\(name).json"
            )
        }
        try write(
            Data("Synthetic finalized text".utf8),
            to: root,
            relativePath: "negative/keyboard-ipc/crash/finalized-text-only.txt"
        )
        try write(
            Data("{synthetic torn delivery checkpoint".utf8),
            to: root,
            relativePath: "negative/keyboard-ipc/crash/torn-delivery-checkpoint.json"
        )
    }

    private static func validateKeyboardIPCCompatibilityFixtures(at root: URL) throws {
        let documents: [(String, TranscriptionIPC.CompatibilityDocument)] = [
            ("request", .request), ("response", .response), ("status", .status),
            ("command", .command), ("listening-state", .listeningState),
            ("live-snapshot", .liveSnapshot),
            ("live-delivery-checkpoint", .liveDeliveryCheckpoint),
        ]
        for (name, document) in documents {
            let compatible = "compatibility/keyboard-ipc/documents/\(name).json"
            let malformed = "negative/keyboard-ipc/documents/\(name).json"
            guard TranscriptionIPC.decodeCompatibilityFixture(
                try Data(contentsOf: root.appendingPathComponent(compatible)),
                as: document
            ), !TranscriptionIPC.decodeCompatibilityFixture(
                try Data(contentsOf: root.appendingPathComponent(malformed)),
                as: document
            ) else {
                throw FixtureError.semanticMismatch("keyboard IPC document \(name)")
            }
        }
        let torn = try Data(contentsOf: root.appendingPathComponent(
            "negative/keyboard-ipc/crash/torn-delivery-checkpoint.json"
        ))
        guard !TranscriptionIPC.decodeCompatibilityFixture(torn, as: .liveDeliveryCheckpoint),
              String(
                data: try Data(contentsOf: root.appendingPathComponent(
                    "negative/keyboard-ipc/crash/finalized-text-only.txt"
                )),
                encoding: .utf8
              ) == "Synthetic finalized text" else {
            throw FixtureError.semanticMismatch("keyboard IPC crash frontier")
        }
    }

    private static func validateCaptureUsageNegativeFixtures(at root: URL) throws {
        let highWater = FixtureCaptureUsageHighWaterMarkStore()
        for (relativePath, expectedVersion) in [
            ("negative/usage/future-version.json", 99),
            ("negative/usage/malformed.json", nil),
        ] as [(String, Int?)] {
            let directory = root.appendingPathComponent(".capture-usage-negative-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ledgerURL = directory.appendingPathComponent("capture-usage-v1.json")
            let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
            try data.write(to: ledgerURL, options: .atomic)
            let store = CaptureDeliveryUsageStore(
                ledgerURL: ledgerURL,
                freeCaptureLimit: 10,
                coordinator: ProcessLocalCaptureFileCoordinator(),
                highWaterStore: highWater,
                isUnlocked: { false },
                mirrorSuccessfulCount: { _ in }
            )
            if let expectedVersion {
                do {
                    _ = try waitForAsync { try await store.snapshot() }
                    throw FixtureError.negativeFixtureAccepted("future capture usage")
                } catch CaptureDeliveryUsageStoreError.unsupportedSchemaVersion(expectedVersion) {
                    guard try Data(contentsOf: ledgerURL) == data else {
                        throw FixtureError.semanticMismatch("future capture usage preservation")
                    }
                }
            } else {
                let snapshot = try waitForAsync { try await store.snapshot() }
                let quarantined = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                ).filter { $0.lastPathComponent.hasPrefix("capture-usage-corrupt-") }
                guard snapshot.successfulCapturesUsed == 0,
                      quarantined.count == 1,
                      try Data(contentsOf: quarantined[0]) == data else {
                    throw FixtureError.semanticMismatch("malformed capture usage quarantine")
                }
            }
        }
    }

    private static func assertDecodeRejected<T: Decodable>(
        _ type: T.Type,
        at root: URL,
        relativePath: String,
        name: String
    ) throws {
        do {
            let _: T = try decodeJSON(at: root, relativePath: relativePath)
            throw FixtureError.negativeFixtureAccepted(name)
        } catch is DecodingError {
            // Expected strict raw-enum/type behavior.
        }
    }

    private static func generateRecordingOriginFixture(
        at root: URL,
        snapshot: CaptureRecordingOriginSnapshot,
        recordingID: String,
        originRelativePath: String
    ) throws {
        let temporaryRoot = root.appendingPathComponent(".recording-origin-producer", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let store = CaptureRecordingOriginStore(rootDirectoryURL: temporaryRoot)
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>!
        Task {
            do {
                try await store.save(snapshot, recordingID: recordingID)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        try result.get()
        let directory = temporaryRoot.appendingPathComponent("recording-origin-location")
        let producedURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        guard producedURLs.count == 1, let producedURL = producedURLs.first else {
            throw FixtureError.semanticMismatch("recording origin producer")
        }
        try write(Data(contentsOf: producedURL), to: root, relativePath: originRelativePath)
    }

    private static func generateRecordingOriginCompatibilityFixtures(at root: URL) throws {
        let data = try Data(contentsOf: root.appendingPathComponent("recording-origin/origin-v1.json"))
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError.semanticMismatch("recording origin compatibility source")
        }
        object["futureFixtureField"] = ["ignored": true]
        try write(
            JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            to: root,
            relativePath: "compatibility/recording-origin/unknown-field.json"
        )
        object.removeValue(forKey: "futureFixtureField")
        object.removeValue(forKey: "presetID")
        try write(
            JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            to: root,
            relativePath: "negative/recording-origin/missing-preset-id.json"
        )
        object["presetID"] = "fixture"
        object["source"] = "futureSource"
        try write(
            JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            to: root,
            relativePath: "negative/recording-origin/unknown-source-enum.json"
        )
        try write(
            Data("{synthetic malformed origin".utf8),
            to: root,
            relativePath: "negative/recording-origin/malformed.json"
        )
    }

    private static func validateRecordingOriginCompatibilityFixtures(at root: URL) throws {
        try validateRecordingOriginFixture(
            at: root,
            originRelativePath: "compatibility/recording-origin/unknown-field.json",
            recordingID: requestID.uuidString.lowercased(),
            expectedPresetID: "fixture"
        )
        for relative in [
            "negative/recording-origin/missing-preset-id.json",
            "negative/recording-origin/unknown-source-enum.json",
            "negative/recording-origin/malformed.json",
        ] {
            let temporaryRoot = root.appendingPathComponent(".recording-origin-negative-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporaryRoot) }
            let directory = temporaryRoot.appendingPathComponent("recording-origin-location", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let recordingID = requestID.uuidString.lowercased()
            let encodedName = Data(recordingID.utf8).base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "=", with: "")
            let destination = directory.appendingPathComponent(String(encodedName.prefix(180))).appendingPathExtension("json")
            let source = try Data(contentsOf: root.appendingPathComponent(relative))
            try source.write(to: destination, options: .atomic)
            let store = CaptureRecordingOriginStore(rootDirectoryURL: temporaryRoot)
            do {
                _ = try waitForAsync { try await store.load(recordingID: recordingID) }
                throw FixtureError.negativeFixtureAccepted(relative)
            } catch is DecodingError {
                guard try Data(contentsOf: destination) == source else {
                    throw FixtureError.semanticMismatch("recording origin rejection preservation")
                }
            }
        }
    }

    private static func validateRecordingOriginFixture(
        at root: URL,
        originRelativePath: String,
        recordingID: String,
        expectedPresetID: String
    ) throws {
        let temporaryRoot = root.appendingPathComponent(".recording-origin-validator", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let directory = temporaryRoot.appendingPathComponent("recording-origin-location", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encodedName = Data(recordingID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        let destination = directory
            .appendingPathComponent(String(encodedName.prefix(180)))
            .appendingPathExtension("json")
        try Data(contentsOf: root.appendingPathComponent(originRelativePath))
            .write(to: destination, options: .atomic)
        let store = CaptureRecordingOriginStore(rootDirectoryURL: temporaryRoot)
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<CaptureRecordingOriginSnapshot?, Error>!
        Task {
            do {
                result = .success(try await store.load(recordingID: recordingID))
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard try result.get()?.presetID == expectedPresetID else {
            throw FixtureError.semanticMismatch("recording origin store")
        }
    }

    private static func validateFutureRecordingJobFixture(
        at root: URL,
        jobRelativePath: String,
        jobID: UUID
    ) throws {
        let temporaryRoot = root.appendingPathComponent(".recording-job-future-validator", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let items = temporaryRoot.appendingPathComponent("items", isDirectory: true)
        try FileManager.default.createDirectory(at: items, withIntermediateDirectories: true)
        try Data(contentsOf: root.appendingPathComponent(jobRelativePath))
            .write(
                to: items
                    .appendingPathComponent(jobID.uuidString.lowercased())
                    .appendingPathExtension("json"),
                options: .atomic
            )
        let store = RecordingJobStore(
            rootDirectoryURL: temporaryRoot,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[RecordingJob], Error>!
        Task {
            do {
                result = .success(try await store.load(recoverInterrupted: false))
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        do {
            _ = try result.get()
            throw FixtureError.negativeFixtureAccepted("future recording job")
        } catch RecordingJobStoreError.unsupportedSchemaVersion(99) {
            let preserved = items
                .appendingPathComponent(jobID.uuidString.lowercased())
                .appendingPathExtension("json")
            guard try Data(contentsOf: preserved)
                == Data(contentsOf: root.appendingPathComponent(jobRelativePath)) else {
                throw FixtureError.semanticMismatch("future recording job preservation")
            }
        }
    }

    private static func generateCaptureHistoryFixture(
        at root: URL,
        records: [CaptureHistoryRecord],
        historyRelativePath: String
    ) throws {
        let temporaryURL = root.appendingPathComponent(".capture-history-producer.json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let store = CaptureHistoryStore(
            fileURL: temporaryURL,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>!
        Task {
            do {
                try await store.writeCompatibilityFixture(records)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        try result.get()
        try write(Data(contentsOf: temporaryURL), to: root, relativePath: historyRelativePath)
    }

    private static func generateCaptureHistoryCompatibilityFixtures(at root: URL) throws {
        let data = try Data(contentsOf: root.appendingPathComponent("history/history-v1.json"))
        guard var envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var records = envelope["records"] as? [[String: Any]],
              !records.isEmpty else {
            throw FixtureError.semanticMismatch("history compatibility source")
        }
        envelope["futureEnvelopeField"] = true
        records[0]["futureRecordField"] = ["ignored": true]
        envelope["records"] = records
        try write(
            JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys]),
            to: root,
            relativePath: "compatibility/history/unknown-field.json"
        )
        records[0]["source"] = "futureSource"
        envelope["records"] = records
        try write(
            JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys]),
            to: root,
            relativePath: "negative/history/unknown-source-enum.json"
        )
    }

    private static func validateCaptureHistoryCompatibilityFixtures(at root: URL) throws {
        try validateCaptureHistoryFixture(
            at: root,
            historyRelativePath: "compatibility/history/unknown-field.json",
            expectedRequestID: requestID
        )
        let temporaryRoot = root.appendingPathComponent(".history-unknown-enum", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let fileURL = temporaryRoot.appendingPathComponent("history.json")
        let source = try Data(contentsOf: root.appendingPathComponent("negative/history/unknown-source-enum.json"))
        try source.write(to: fileURL, options: .atomic)
        let store = CaptureHistoryStore(fileURL: fileURL, coordinator: ProcessLocalCaptureFileCoordinator())
        let loaded = try waitForAsync { try await store.load() }
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: store.quarantineDirectoryURL,
            includingPropertiesForKeys: nil
        )
        guard loaded.isEmpty, quarantined.count == 1,
              try Data(contentsOf: quarantined[0]) == source else {
            throw FixtureError.semanticMismatch("history unknown enum quarantine")
        }
    }

    private static func validateCaptureHistoryFixture(
        at root: URL,
        historyRelativePath: String,
        expectedRequestID: UUID
    ) throws {
        let temporaryURL = root.appendingPathComponent(".capture-history-validator.json")
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(
                at: temporaryURL.deletingLastPathComponent()
                    .appendingPathComponent(".capture-history-validator-corrupt", isDirectory: true)
            )
        }
        try Data(contentsOf: root.appendingPathComponent(historyRelativePath))
            .write(to: temporaryURL, options: .atomic)
        let store = CaptureHistoryStore(
            fileURL: temporaryURL,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[CaptureHistoryRecord], Error>!
        Task {
            do {
                result = .success(try await store.load())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard try result.get().first?.requestID == expectedRequestID else {
            throw FixtureError.semanticMismatch("capture history")
        }
    }

    private static func validateCaptureHistoryQuarantineFixture(at root: URL) throws {
        let temporaryRoot = root.appendingPathComponent(".capture-history-quarantine", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let fileURL = temporaryRoot.appendingPathComponent("history.json")
        let corrupt = try Data(contentsOf: root.appendingPathComponent("history/corrupt-input.json"))
        try corrupt.write(to: fileURL)
        let store = CaptureHistoryStore(
            fileURL: fileURL,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        let loaded = try waitForAsync { try await store.load() }
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: store.quarantineDirectoryURL,
            includingPropertiesForKeys: nil
        )
        guard loaded.isEmpty,
              quarantined.count == 1,
              try Data(contentsOf: quarantined[0]) == corrupt,
              !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw FixtureError.semanticMismatch("history quarantine")
        }
    }

    private static func validateFutureCaptureHistoryFixture(
        at root: URL,
        historyRelativePath: String
    ) throws {
        let temporaryURL = root.appendingPathComponent(".capture-history-future-validator.json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Data(contentsOf: root.appendingPathComponent(historyRelativePath))
            .write(to: temporaryURL, options: .atomic)
        let store = CaptureHistoryStore(
            fileURL: temporaryURL,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[CaptureHistoryRecord], Error>!
        Task {
            do {
                result = .success(try await store.load())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        do {
            _ = try result.get()
            throw FixtureError.negativeFixtureAccepted("future history")
        } catch CaptureHistoryError.unsupportedFileSchemaVersion(99) {
            // Expected production behavior.
        }
    }

    private static func generateCaptureInboxStateFixtures(
        at root: URL,
        request: CaptureRequest
    ) throws {
        let temporaryRoot = root.appendingPathComponent(".capture-inbox-states-producer", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let inbox = CaptureInbox(
            rootDirectoryURL: temporaryRoot,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        try waitForAsync {
            try await inbox.enqueue(request)
        }
        try write(
            Data(contentsOf: inbox.itemURL(for: request.id, state: .pending)),
            to: root,
            relativePath: "inbox/pending-request.json"
        )
        _ = try waitForAsync {
            try await inbox.claim(requestID: request.id)
        }
        try write(
            Data(contentsOf: inbox.itemURL(for: request.id, state: .processing)),
            to: root,
            relativePath: "inbox/processing-request.json"
        )
        try waitForAsync {
            try await inbox.fail(requestID: request.id)
        }
        try write(
            Data(contentsOf: inbox.itemURL(for: request.id, state: .failed)),
            to: root,
            relativePath: "inbox/failed-request.json"
        )
    }

    private static func generateCaptureInboxCompatibilityFixtures(
        at root: URL,
        request: CaptureRequest
    ) throws {
        try write(
            Data(try addingUnknownField(to: request).utf8),
            to: root,
            relativePath: "compatibility/inbox/pending-unknown-field.json"
        )
        var requestObject = try JSONSerialization.jsonObject(
            with: deterministicEncoded(request)
        ) as! [String: Any]
        for key in [
            "captureSource", "locationOutcome", "locationDecisionOverride",
            "originDraftUpdatedAt", "relativeNotePathOverride", "placementOverride",
            "entryTemplateIDOverride", "attachmentsFolderNameOverride", "voxProfile"
        ] {
            requestObject.removeValue(forKey: key)
        }
        try write(
            JSONSerialization.data(withJSONObject: requestObject, options: [.prettyPrinted, .sortedKeys]),
            to: root,
            relativePath: "negative/inbox/pending-missing-optional-fields.json"
        )
        var missingRequired = requestObject
        missingRequired.removeValue(forKey: "destinationID")
        try write(
            JSONSerialization.data(withJSONObject: missingRequired, options: [.prettyPrinted, .sortedKeys]),
            to: root,
            relativePath: "negative/inbox/pending-missing-required-field.json"
        )
        requestObject["source"] = "futureSource"
        try write(
            JSONSerialization.data(withJSONObject: requestObject, options: [.prettyPrinted, .sortedKeys]),
            to: root,
            relativePath: "negative/inbox/pending-unknown-source-enum.json"
        )
        let receipt = [
            "schemaVersion": 1,
            "requestID": request.id.uuidString.lowercased(),
            "completedAt": fixedDate.timeIntervalSinceReferenceDate,
            "futureFixtureField": ["ignored": true],
        ] as [String: Any]
        try write(
            JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]),
            to: root,
            relativePath: "compatibility/inbox/completed-unknown-field.json"
        )
    }

    private static func validateCaptureInboxCompatibilityFixtures(
        at root: URL,
        requestID: UUID
    ) throws {
        for relative in [
            "compatibility/inbox/pending-unknown-field.json",
            "negative/inbox/pending-missing-optional-fields.json",
        ] {
            let temporaryRoot = root.appendingPathComponent(".inbox-compatible-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporaryRoot) }
            let inbox = CaptureInbox(rootDirectoryURL: temporaryRoot, coordinator: ProcessLocalCaptureFileCoordinator())
            let destination = inbox.itemURL(for: requestID, state: .pending)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: root.appendingPathComponent(relative)).write(to: destination, options: .atomic)
            guard try waitForAsync({ try await inbox.requestIDs(in: .pending) }) == [requestID] else {
                throw FixtureError.semanticMismatch(relative)
            }
        }
        for relative in [
            "negative/inbox/pending-missing-required-field.json",
            "negative/inbox/pending-unknown-source-enum.json",
        ] {
            let temporaryRoot = root.appendingPathComponent(".inbox-rejected-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporaryRoot) }
            let inbox = CaptureInbox(rootDirectoryURL: temporaryRoot, coordinator: ProcessLocalCaptureFileCoordinator())
            let destination = inbox.itemURL(for: requestID, state: .pending)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: root.appendingPathComponent(relative)).write(to: destination, options: .atomic)
            guard try waitForAsync({ try await inbox.requestIDs(in: .pending) }).isEmpty,
                  FileManager.default.fileExists(atPath: destination.path) else {
                throw FixtureError.semanticMismatch("rejected inbox fixture preservation: \(relative)")
            }
        }
        let completedRoot = root.appendingPathComponent(".inbox-completed-unknown")
        defer { try? FileManager.default.removeItem(at: completedRoot) }
        let inbox = CaptureInbox(rootDirectoryURL: completedRoot, coordinator: ProcessLocalCaptureFileCoordinator())
        let receiptURL = inbox.itemURL(for: requestID, state: .completed)
        try FileManager.default.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: root.appendingPathComponent("compatibility/inbox/completed-unknown-field.json"))
            .write(to: receiptURL, options: .atomic)
        guard try waitForAsync({ try await inbox.requestIDs(in: .completed) }) == [requestID] else {
            throw FixtureError.semanticMismatch("completed receipt unknown field")
        }
    }

    private static func validateCaptureInboxStateFixtures(
        at root: URL,
        requestID: UUID
    ) throws {
        for state in [CaptureInboxState.pending, .processing, .failed] {
            let temporaryRoot = root.appendingPathComponent(
                ".capture-inbox-\(state.rawValue)-validator",
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: temporaryRoot) }
            let inbox = CaptureInbox(
                rootDirectoryURL: temporaryRoot,
                coordinator: ProcessLocalCaptureFileCoordinator()
            )
            let destination = inbox.itemURL(for: requestID, state: state)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contentsOf: root.appendingPathComponent("inbox/\(state.rawValue)-request.json"))
                .write(to: destination, options: .atomic)
            let ids = try waitForAsync {
                try await inbox.requestIDs(in: state)
            }
            guard ids == [requestID] else {
                throw FixtureError.semanticMismatch("\(state.rawValue) inbox request")
            }
        }
    }

    private static func generateCaptureInboxCompletionFixture(
        at root: URL,
        request: CaptureRequest,
        completedAt: Date,
        receiptRelativePath: String
    ) throws {
        let temporaryRoot = root.appendingPathComponent(".capture-inbox-producer", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let inbox = CaptureInbox(
            rootDirectoryURL: temporaryRoot,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>!
        Task {
            do {
                try await inbox.enqueue(request)
                _ = try await inbox.claim(requestID: request.id)
                try await inbox.complete(requestID: request.id, completedAt: completedAt)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        try result.get()
        let producedURL = inbox.itemURL(for: request.id, state: .completed)
        try write(Data(contentsOf: producedURL), to: root, relativePath: receiptRelativePath)
    }

    private static func validateCaptureInboxCompletionFixture(
        at root: URL,
        requestID: UUID,
        receiptRelativePath: String
    ) throws {
        let temporaryRoot = root.appendingPathComponent(".capture-inbox-validator", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let inbox = CaptureInbox(
            rootDirectoryURL: temporaryRoot,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        let destination = inbox.itemURL(for: requestID, state: .completed)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contentsOf: root.appendingPathComponent(receiptRelativePath))
            .write(to: destination, options: .atomic)
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[UUID], Error>!
        Task {
            do {
                result = .success(try await inbox.requestIDs(in: .completed))
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard try result.get() == [requestID] else {
            throw FixtureError.semanticMismatch("completion receipt")
        }
    }

    private static func validateFutureCaptureInboxCompletionFixture(
        at root: URL,
        requestID: UUID,
        receiptRelativePath: String
    ) throws {
        let temporaryRoot = root.appendingPathComponent(".capture-inbox-future-validator", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let inbox = CaptureInbox(
            rootDirectoryURL: temporaryRoot,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        let destination = inbox.itemURL(for: requestID, state: .completed)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contentsOf: root.appendingPathComponent(receiptRelativePath))
            .write(to: destination, options: .atomic)
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[UUID], Error>!
        Task {
            do {
                result = .success(try await inbox.requestIDs(in: .completed))
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard try result.get() == [requestID] else {
            throw FixtureError.semanticMismatch("future completion receipt rewrite")
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
        guard object?["schemaVersion"] as? Int == 1 else {
            throw FixtureError.negativeFixtureAccepted("future completion receipt")
        }
    }

    private static func generateCaptureUsageFixture(
        at root: URL,
        request: CaptureRequest,
        ledgerRelativePath: String
    ) throws {
        let ledgerURL = root.appendingPathComponent(ledgerRelativePath)
        let store = CaptureDeliveryUsageStore(
            ledgerURL: ledgerURL,
            freeCaptureLimit: 10,
            coordinator: ProcessLocalCaptureFileCoordinator(),
            highWaterStore: FixtureCaptureUsageHighWaterMarkStore(),
            isUnlocked: { false },
            mirrorSuccessfulCount: { _ in }
        )
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>!
        Task {
            do {
                let reservation = try await store.reserve(for: request)
                try await store.commit(reservation)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        try result.get()
    }

    private static func generateCaptureUsageCompatibilityFixtures(at root: URL) throws {
        try write(
            Data("7".utf8),
            to: root,
            relativePath: "compatibility/usage/legacy-high-water-decimal.txt"
        )
        try write(
            Data(#"{"schemaVersion":1,"committedRequestIDs":[],"reservationTokensByRequestID":[]}"#.utf8),
            to: root,
            relativePath: "compatibility/usage/missing-default-fields.json"
        )
        let data = try Data(contentsOf: root.appendingPathComponent("usage/capture-usage-v1.json"))
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError.semanticMismatch("capture usage compatibility source")
        }
        object["futureFixtureField"] = ["ignored": true]
        try write(
            JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            to: root,
            relativePath: "compatibility/usage/unknown-field.json"
        )
    }

    private static func validateCaptureUsageCompatibilityFixtures(at root: URL) throws {
        let legacyData = try Data(contentsOf: root.appendingPathComponent("compatibility/usage/legacy-high-water-decimal.txt"))
        guard CaptureUsageHighWaterMarkCodec.decode(legacyData) == CaptureUsageHighWaterMark(successfulCaptureCount: 7) else {
            throw FixtureError.semanticMismatch("legacy capture usage high-water codec")
        }
        for relative in [
            "compatibility/usage/missing-default-fields.json",
            "compatibility/usage/unknown-field.json",
        ] {
            let directory = root.appendingPathComponent(".capture-usage-compatible-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ledgerURL = directory.appendingPathComponent("capture-usage-v1.json")
            try Data(contentsOf: root.appendingPathComponent(relative)).write(to: ledgerURL, options: .atomic)
            let store = CaptureDeliveryUsageStore(
                ledgerURL: ledgerURL,
                freeCaptureLimit: 10,
                coordinator: ProcessLocalCaptureFileCoordinator(),
                highWaterStore: FixtureCaptureUsageHighWaterMarkStore(),
                isUnlocked: { false },
                mirrorSuccessfulCount: { _ in }
            )
            let snapshot = try waitForAsync { try await store.snapshot() }
            guard snapshot.successfulCapturesUsed == (relative.contains("unknown") ? 1 : 0) else {
                throw FixtureError.semanticMismatch(relative)
            }
        }
    }

    private static func generateTranscriptionUsageNegativeFixtures(at root: URL) throws {
        try writeJSON(
            SyntheticSettingsSnapshot(schemaVersion: 1, values: [
                "totalTranscriptionSeconds": .string("not-a-number"),
                "transcriptionUsageReceiptBaselineV1": .string("not-a-number"),
                "transcriptionUsageReceiptsV1": .string("not-a-dictionary"),
                "hasUnlocked": .string("not-a-boolean"),
            ]),
            to: root,
            relativePath: "negative/usage-settings/wrong-types.json",
            sorted: true
        )
        try writeJSON(
            SyntheticSettingsSnapshot(schemaVersion: 1, values: [
                "unlimitedAccessLevelV1": .string("futureAccess")
            ]),
            to: root,
            relativePath: "negative/usage-settings/unknown-access-level.json",
            sorted: true
        )
    }

    private static func validateTranscriptionUsageNegativeFixtures(at root: URL) throws {
        for (relative, expectedLevel) in [
            ("negative/usage-settings/wrong-types.json", VoxboardAccessLevel.free),
            ("negative/usage-settings/unknown-access-level.json", VoxboardAccessLevel.free),
        ] {
            let snapshot: SyntheticSettingsSnapshot = try decodeJSON(at: root, relativePath: relative)
            let name = "usage-negative-\(UUID().uuidString)"
            let defaults = try isolatedDefaults(named: name)
            defer { defaults.removePersistentDomain(forName: defaultsSuiteName(name)) }
            for (key, value) in snapshot.values { defaults.set(value.propertyListObject, forKey: key) }
            let tracker = UsageTracker(defaults: defaults)
            guard tracker.totalSecondsUsed == 0,
                  tracker.accessLevel == expectedLevel,
                  defaults.object(forKey: "unlimitedAccessLevelV1") != nil || relative.contains("wrong-types") else {
                throw FixtureError.semanticMismatch(relative)
            }
        }
    }

    private static func generateQueuePreferenceNegativeFixtures(at root: URL) throws {
        try writeJSON(
            SyntheticSettingsSnapshot(schemaVersion: 1, values: [
                RecordingQueuePreferences.retentionModeKey: .int64(42),
                RecordingQueuePreferences.retentionIntervalKey: .string("not-a-duration"),
                RecordingQueuePreferences.processingPolicyKey: .bool(true),
            ]),
            to: root,
            relativePath: "negative/queue-preferences/wrong-types.json",
            sorted: true
        )
        try writeJSON(
            SyntheticSettingsSnapshot(schemaVersion: 1, values: [
                RecordingQueuePreferences.retentionModeKey: .string("futureRetention"),
                RecordingQueuePreferences.processingPolicyKey: .string("futureProcessing"),
            ]),
            to: root,
            relativePath: "negative/queue-preferences/unknown-enums.json",
            sorted: true
        )
    }

    private static func validateQueuePreferenceNegativeFixtures(at root: URL) throws {
        for relative in [
            "negative/queue-preferences/wrong-types.json",
            "negative/queue-preferences/unknown-enums.json",
        ] {
            let snapshot: SyntheticSettingsSnapshot = try decodeJSON(at: root, relativePath: relative)
            let name = "queue-negative-\(UUID().uuidString)"
            let defaults = try isolatedDefaults(named: name)
            defer { defaults.removePersistentDomain(forName: defaultsSuiteName(name)) }
            for (key, value) in snapshot.values { defaults.set(value.propertyListObject, forKey: key) }
            guard RecordingQueuePreferences.load(from: defaults) == .default else {
                throw FixtureError.semanticMismatch(relative)
            }
        }
    }

    private static func generateModelSelectionNegativeFixtures(at root: URL) throws {
        try writeJSON(
            SyntheticSettingsSnapshot(schemaVersion: 1, values: [
                AppConstants.selectedModelKey: .int64(42),
                AppConstants.selectedLanguageKey: .bool(true),
                AppConstants.selectedFallbackModelKey: .data(Data([0, 255])),
            ]),
            to: root,
            relativePath: "negative/models/wrong-types.json",
            sorted: true
        )
        try writeJSON(
            SyntheticSettingsSnapshot(schemaVersion: 1, values: [
                AppConstants.selectedModelKey: .string("futureBackend"),
                AppConstants.selectedFallbackModelKey: .string("futureFallback"),
            ]),
            to: root,
            relativePath: "negative/models/unknown-selection.json",
            sorted: true
        )
    }

    private static func validateModelSelectionNegativeFixtures(at root: URL) throws {
        for relative in ["negative/models/wrong-types.json", "negative/models/unknown-selection.json"] {
            let snapshot: SyntheticSettingsSnapshot = try decodeJSON(at: root, relativePath: relative)
            let name = "model-negative-\(UUID().uuidString)"
            let defaults = try isolatedDefaults(named: name)
            defer { defaults.removePersistentDomain(forName: defaultsSuiteName(name)) }
            for (key, value) in snapshot.values { defaults.set(value.propertyListObject, forKey: key) }
            let selection = try runOnMainActor {
                let manager = ModelManager(defaults: defaults)
                return (manager.selectedModelId, manager.selectedLanguage, manager.preferredFallbackModelID)
            }
            #if os(iOS)
            guard selection.0 == TranscriptionBackendID.automatic,
                  selection.1 == "auto" else {
                throw FixtureError.semanticMismatch(relative)
            }
            #else
            guard selection.0 == AppConstants.defaultModelName,
                  selection.1 == "auto" else {
                throw FixtureError.semanticMismatch(relative)
            }
            #endif
        }
    }

    private static func generateLiveActivityCompatibilityFixtures(at root: URL) throws {
        let data = try Data(contentsOf: root.appendingPathComponent("live-state/live-activity-state.json"))
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError.semanticMismatch("live activity compatibility source")
        }
        object["futureFixtureField"] = ["ignored": true]
        try write(
            JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            to: root,
            relativePath: "compatibility/live-state/unknown-field.json"
        )
        try write(
            Data("{synthetic malformed live state".utf8),
            to: root,
            relativePath: "negative/live-state/malformed.json"
        )
    }

    private static func validateLiveActivityCompatibilityFixtures(at root: URL) throws {
        let compatible: VoxboardLiveActivityState = try decodeJSON(
            at: root,
            relativePath: "compatibility/live-state/unknown-field.json"
        )
        guard compatible.isSegmentActive else {
            throw FixtureError.semanticMismatch("live activity unknown field")
        }
        try assertDecodeRejected(
            VoxboardLiveActivityState.self,
            at: root,
            relativePath: "negative/live-state/malformed.json",
            name: "malformed live activity state"
        )
    }

    private static func generateWatchInboxCompatibilityFixtures(at root: URL) throws {
        let data = try Data(contentsOf: root.appendingPathComponent("watch-inbox/item-current.json"))
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError.semanticMismatch("Watch inbox compatibility source")
        }
        object["futureFixtureField"] = ["ignored": true]
        try write(
            JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            to: root,
            relativePath: "compatibility/watch-inbox/unknown-field.json"
        )
        object.removeValue(forKey: "futureFixtureField")
        object["phase"] = "futurePhase"
        try write(
            JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            to: root,
            relativePath: "negative/watch-inbox/unknown-phase-enum.json"
        )
    }

    private static func validateCaptureUsageFixture(
        at root: URL,
        ledgerRelativePath: String
    ) throws {
        let store = CaptureDeliveryUsageStore(
            ledgerURL: root.appendingPathComponent(ledgerRelativePath),
            freeCaptureLimit: 10,
            coordinator: ProcessLocalCaptureFileCoordinator(),
            highWaterStore: FixtureCaptureUsageHighWaterMarkStore(),
            isUnlocked: { false },
            mirrorSuccessfulCount: { _ in }
        )
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<CaptureDeliveryUsageSnapshot, Error>!
        Task {
            do {
                result = .success(try await store.snapshot())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        let snapshot = try result.get()
        guard snapshot.successfulCapturesUsed == 1,
              snapshot.reservedCaptureSlots == 0 else {
            throw FixtureError.semanticMismatch("capture usage")
        }
    }

    private static func syntheticPreset() -> CapturePreset {
        CapturePreset(
            id: "fixture",
            name: "Synthetic Fixture",
            symbolName: "waveform",
            kind: .custom,
            exportSettings: CapturePresetExportSettings(
                exportEnabled: true,
                format: .md,
                mode: .newFile,
                folderBookmark: Data([4, 5, 6]),
                folderName: "Synthetic Folder",
                newFileNameTemplate: "fixture-{timestamp}",
                markdownTemplateEnabled: false,
                mdObsidianEnabled: true,
                yamlUsesMarkdownExtension: false,
                yamlProperties: Set(ExportYAMLProperty.allCases),
                embedAudioInMarkdown: true,
                audioEmbedPlacement: .bottom
            ),
            staticFrontmatter: ["fixture": "true"],
            locationPolicy: CapturePresetLocationPolicy(
                isEnabled: true,
                precision: .city,
                unavailableBehavior: .ask
            ),
            metadataScope: .document,
            postProcessingMode: .meetingNotes,
            speakerDiarizationEnabled: true,
            captureProcessingEnabled: true,
            capturePrompt: "Synthetic prompt",
            watchOutputMode: .recordingOnly,
            watchRecordingSettings: CapturePresetWatchRecordingSettings(
                folderBookmark: Data([9, 8, 7]),
                folderName: "Synthetic Watch Folder",
                filenameTemplate: "fixture-{timestamp}-{id8}"
            ),
            audioSaveMode: .attachmentsFolder,
            attachmentsFolderName: "fixtures",
            captureDestinationID: destinationID,
            captureEntryTemplateID: templateID,
            capturePlacementOverride: .prepend
        )
    }

    private static func syntheticLibrary() -> CaptureLibraryEnvelope {
        CaptureLibraryEnvelope(
            destinations: [
                CaptureDestination(
                    id: destinationID,
                    name: "Synthetic Vault",
                    rootBookmark: Data([0, 1, 2, 255]),
                    rootName: "Synthetic Root",
                    noteTarget: .existingNote(relativePath: "Fixtures/Inbox.md"),
                    placement: .beneathHeading(
                        CaptureHeadingSelector(title: "Inbox", level: 2),
                        missingHeadingBehavior: .create
                    ),
                    entryPrefix: "- ",
                    entrySuffix: " #fixture",
                    entryTemplateID: templateID,
                    markdownTemplatePath: nil,
                    attachmentsFolderName: "fixtures",
                    retryProtectionEnabled: true
                )
            ],
            defaultDestinationID: destinationID,
            entryTemplates: [
                CaptureEntryTemplate(id: templateID, name: "Synthetic Entry", entryPrefix: "- ", entrySuffix: " #fixture")
            ]
        )
    }

    private static func syntheticWatchContext(preset: CapturePreset) -> [String: Any] {
        [
            "phase": "recording",
            "isQuickRecordEnabled": true,
            "recordingStartedAt": fixedDate.timeIntervalSince1970,
            "recordingDuration": 42.0,
            "message": "Synthetic status",
            "queuedCount": 1,
            "selectedPresetID": preset.id,
            "selectedPresetName": preset.name,
            "selectedPresetSnapshot": try! deterministicEncoded(preset),
            "presetSelectionAvailable": true,
            "presetSelectionEpoch": Int64(1_700_000_000_000),
            "presetSelectionSequence": Int64(7),
            "stateEpoch": Int64(1_700_000_000_000),
            "stateRevision": 3,
            "sentAt": fixedDate.timeIntervalSince1970,
            "recordingStatuses": [[
                "recordingID": requestID.uuidString.lowercased(),
                "phase": "failed",
                "revision": 3,
                "updatedAt": fixedDate.timeIntervalSince1970,
                "message": "Synthetic failure",
            ]],
        ]
    }

    private static func syntheticLegacyWatchContext() -> [String: Any] {
        [
            "phase": "idle",
            "isQuickRecordEnabled": true,
            "sentAt": fixedDate.timeIntervalSince1970,
        ]
    }

    private static func syntheticWatchCommand(_ command: String) -> [String: Any] {
        var payload: [String: Any] = [
            "command": command,
            "sentAt": fixedDate.timeIntervalSince1970,
        ]
        if command == "acknowledge" {
            payload["recordingID"] = requestID.uuidString.lowercased()
            payload["revision"] = 3
        } else if command == "selectPreset" {
            payload["requestedPresetID"] = "fixture"
            payload["presetSelectionRequestID"] = "fixture-selection-request"
            payload["presetSelectionEpoch"] = Int64(1_700_000_000_000)
            payload["presetSelectionSequence"] = Int64(7)
        }
        return payload
    }

    private static func syntheticWatchPresetAcknowledgement(outcome: String) -> [String: Any] {
        var payload: [String: Any] = [
            "presetSelectionRequestID": "fixture-selection-request",
            "requestedPresetID": "fixture",
            "presetSelectionEpoch": Int64(1_700_000_000_000),
            "presetSelectionSequence": Int64(7),
            "presetSelectionResult": outcome,
        ]
        if outcome != "accepted" {
            payload["presetSelectionError"] = "Synthetic \(outcome) response"
        }
        return payload
    }

    private static func syntheticLegacyWatchFileMetadata() -> [String: Any] {
        [
            "kind": "watchAudioRecording",
            "recordingID": requestID.uuidString.lowercased(),
            "createdAt": fixedDate.timeIntervalSince1970,
            "duration": 42.0,
            "originalFilename": "fixture.m4a",
        ]
    }

    private static func syntheticMalformedWatchFileMetadata() -> [String: Any] {
        [
            "kind": "watchAudioRecording",
            "recordingID": requestID.uuidString.lowercased(),
            "createdAt": fixedDate.timeIntervalSince1970,
            "duration": 42.0,
            "originalFilename": "fixture.m4a",
            "presetSnapshot": Data("not-a-preset".utf8),
            "locationOutcome": Data("not-a-location".utf8),
        ]
    }

    private static func syntheticWatchFileMetadata(
        preset: CapturePreset,
        location: CaptureLocationOutcome
    ) -> [String: Any] {
        [
            "kind": "watchAudioRecording",
            "recordingID": requestID.uuidString.lowercased(),
            "createdAt": fixedDate.timeIntervalSince1970,
            "duration": 42.0,
            "originalFilename": "fixture.m4a",
            "presetID": preset.id,
            "presetName": preset.name,
            "presetSnapshot": try! deterministicEncoded(preset),
            "locationOutcome": try! deterministicEncoded(location),
        ]
    }

    private static func replacingJSONValue<T: Encodable>(
        in value: T,
        keyPath: [String],
        with replacement: Any
    ) throws -> String {
        func replacing(_ current: Any, remaining: ArraySlice<String>) throws -> Any {
            guard let component = remaining.first else { return replacement }
            if let index = Int(component), var array = current as? [Any], array.indices.contains(index) {
                array[index] = try replacing(array[index], remaining: remaining.dropFirst())
                return array
            }
            guard var dictionary = current as? [String: Any], let child = dictionary[component] else {
                throw FixtureError.semanticMismatch("JSON fixture key path \(keyPath.joined(separator: "."))")
            }
            dictionary[component] = try replacing(child, remaining: remaining.dropFirst())
            return dictionary
        }
        let data = try deterministicEncoded(value)
        let object = try JSONSerialization.jsonObject(with: data)
        let replaced = try replacing(object, remaining: keyPath[...])
        let encoded = try JSONSerialization.data(
            withJSONObject: replaced,
            options: [.prettyPrinted, .sortedKeys]
        )
        guard let text = String(data: encoded, encoding: .utf8) else {
            throw FixtureError.semanticMismatch("JSON fixture replacement encoding")
        }
        return text
    }

    private static func deterministicEncoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func addingUnknownField<T: Encodable>(to value: T) throws -> String {
        let data = try deterministicEncoded(value)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError.semanticMismatch("unknown field fixture source")
        }
        object["futureFixtureField"] = ["ignored": true]
        let enriched = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        guard let text = String(data: enriched, encoding: .utf8) else {
            throw FixtureError.semanticMismatch("unknown field fixture encoding")
        }
        return text
    }

    private static func writeJSON<T: Encodable>(
        _ value: T,
        to root: URL,
        relativePath: String,
        sorted: Bool
    ) throws {
        let encoder = JSONEncoder()
        if sorted { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        try write(encoder.encode(value), to: root, relativePath: relativePath)
    }

    private static func writePropertyList(
        _ value: [String: Any],
        to root: URL,
        relativePath: String,
        format: PropertyListSerialization.PropertyListFormat
    ) throws {
        // Binary plist serialization is semantically stable but may reorder its
        // object table between processes. Canonicalize through the deterministic
        // XML representation for repository byte fixtures; the `.binary.plist`
        // path is retained as a compatibility input name and production readers
        // detect the actual format from its bytes.
        let canonicalFormat: PropertyListSerialization.PropertyListFormat =
            format == .binary ? .xml : format
        let data = try PropertyListSerialization.data(
            fromPropertyList: value,
            format: canonicalFormat,
            options: 0
        )
        try write(data, to: root, relativePath: relativePath)
    }

    private static func write(_ data: Data, to root: URL, relativePath: String) throws {
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else {
            throw FixtureError.unsafeRelativePath(relativePath)
        }
        let url = root.appendingPathComponent(relativePath)
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw FixtureError.unsafeRelativePath(relativePath)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func decodeJSON<T: Decodable>(at root: URL, relativePath: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: root.appendingPathComponent(relativePath)))
    }

    private static func recursiveFiles(at root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return try enumerator.compactMap { value in
            guard let url = value as? URL,
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            return url
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func assertSyntheticPrivacy(root: URL) throws {
        let forbidden = [
            FileManager.default.homeDirectoryForCurrentUser.path,
            "group.bontecou.Voxboard",
            "security-scoped",
        ]
        for url in try recursiveFiles(at: root) where ["json", "xml"].contains(url.pathExtension) {
            guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else { continue }
            if forbidden.contains(where: text.contains) {
                throw FixtureError.privateDataDetected(url.lastPathComponent)
            }
        }
    }
}

private final class FixtureCaptureUsageHighWaterMarkStore: CaptureUsageHighWaterMarkStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value = CaptureUsageHighWaterMark(successfulCaptureCount: 0)

    func load() throws -> CaptureUsageHighWaterMark {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func raise(to candidate: CaptureUsageHighWaterMark) throws {
        lock.lock()
        defer { lock.unlock() }
        let mergedIDs = value.committedRequestIDs.union(candidate.committedRequestIDs)
        value = CaptureUsageHighWaterMark(
            successfulCaptureCount: max(
                value.successfulCaptureCount,
                candidate.successfulCaptureCount,
                mergedIDs.count
            ),
            committedRequestIDs: mergedIDs
        )
    }
}

private struct SyntheticWatchInboxItem: Codable {
    var id: String
    var requestID: UUID?
    var filename: String
    var originalFilename: String?
    var createdAt: Date?
    var receivedAt: Date?
    var duration: TimeInterval?
    var flowSnapshot: CapturePreset?
    var flowSnapshotPayload: Data?
    var locationOutcome: CaptureLocationOutcome?
    var requiresPresetSelection: Bool?
    var capturesRecordingWithoutTranscript: Bool?
    var reservedOutputFilename: String?
    var reservedOutputFolderBookmark: Data?
    var phase: String?
    var failureStage: String?
    var statusMessage: String?
    var attemptCount: Int?
    var revision: Int?
    var updatedAt: Date?
    var deliveredAt: Date?
    var acknowledgedAt: Date?

    static func fixture(preset: CapturePreset, location: CaptureLocationOutcome) -> Self {
        Self(
            id: VoxboardPersistenceFixtures.requestID.uuidString.lowercased(),
            requestID: VoxboardPersistenceFixtures.requestID,
            filename: "watch-fixture.m4a",
            originalFilename: "fixture.m4a",
            createdAt: VoxboardPersistenceFixtures.fixedDate,
            receivedAt: VoxboardPersistenceFixtures.fixedDate.addingTimeInterval(1),
            duration: 42,
            flowSnapshot: preset,
            flowSnapshotPayload: {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                return try! encoder.encode(preset)
            }(),
            locationOutcome: location,
            requiresPresetSelection: false,
            capturesRecordingWithoutTranscript: true,
            reservedOutputFilename: "fixture-20231114-aaaaaaaa.m4a",
            reservedOutputFolderBookmark: Data([9, 8, 7]),
            phase: "failed",
            failureStage: "delivery",
            statusMessage: "Synthetic failure",
            attemptCount: 2,
            revision: 3,
            updatedAt: VoxboardPersistenceFixtures.fixedDate.addingTimeInterval(2),
            deliveredAt: nil,
            acknowledgedAt: nil
        )
    }

    static let legacy = Self(
        id: "legacy-watch-fixture",
        requestID: nil,
        filename: "legacy-watch.m4a",
        originalFilename: nil,
        createdAt: nil,
        receivedAt: VoxboardPersistenceFixtures.fixedDate,
        duration: nil,
        flowSnapshot: nil,
        flowSnapshotPayload: nil,
        locationOutcome: nil,
        requiresPresetSelection: nil,
        capturesRecordingWithoutTranscript: nil,
        reservedOutputFilename: nil,
        reservedOutputFolderBookmark: nil,
        phase: nil,
        failureStage: nil,
        statusMessage: nil,
        attemptCount: nil,
        revision: nil,
        updatedAt: nil,
        deliveredAt: nil,
        acknowledgedAt: nil
    )
}

private struct SyntheticSettingsSnapshot: Codable, Equatable {
    enum Value: Codable, Equatable {
        case string(String)
        case double(Double)
        case int64(Int64)
        case bool(Bool)
        case data(Data)
        case stringDoubleDictionary([String: Double])

        private enum CodingKeys: String, CodingKey { case type, value }
        private enum Kind: String, Codable { case string, double, int64, bool, data, stringDoubleDictionary }

        init(propertyListObject object: Any) throws {
            switch object {
            case let value as Data: self = .data(value)
            case let value as String: self = .string(value)
            case let value as NSNumber:
                let type = String(cString: value.objCType)
                if type == "c" || type == "B" {
                    self = .bool(value.boolValue)
                } else if type == "f" || type == "d" {
                    self = .double(value.doubleValue)
                } else {
                    self = .int64(value.int64Value)
                }
            case let value as [String: Double]: self = .stringDoubleDictionary(value)
            case let value as [String: NSNumber]:
                self = .stringDoubleDictionary(value.mapValues(\.doubleValue))
            default: throw FixtureError.semanticMismatch("unsupported settings value")
            }
        }

        var propertyListObject: Any {
            switch self {
            case .string(let value): value
            case .double(let value): value
            case .int64(let value): value
            case .bool(let value): value
            case .data(let value): value
            case .stringDoubleDictionary(let value): value
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .type) {
            case .string: self = .string(try container.decode(String.self, forKey: .value))
            case .double: self = .double(try container.decode(Double.self, forKey: .value))
            case .int64: self = .int64(try container.decode(Int64.self, forKey: .value))
            case .bool: self = .bool(try container.decode(Bool.self, forKey: .value))
            case .data: self = .data(try container.decode(Data.self, forKey: .value))
            case .stringDoubleDictionary:
                self = .stringDoubleDictionary(
                    try container.decode([String: Double].self, forKey: .value)
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .string(let value): try container.encode(Kind.string, forKey: .type); try container.encode(value, forKey: .value)
            case .double(let value): try container.encode(Kind.double, forKey: .type); try container.encode(value, forKey: .value)
            case .int64(let value): try container.encode(Kind.int64, forKey: .type); try container.encode(value, forKey: .value)
            case .bool(let value): try container.encode(Kind.bool, forKey: .type); try container.encode(value, forKey: .value)
            case .data(let value): try container.encode(Kind.data, forKey: .type); try container.encode(value, forKey: .value)
            case .stringDoubleDictionary(let value):
                try container.encode(Kind.stringDoubleDictionary, forKey: .type)
                try container.encode(value, forKey: .value)
            }
        }
    }

    var schemaVersion: Int
    var values: [String: Value]
}

private struct FixtureManifest: Codable {
    struct Entry: Codable {
        var path: String
        var byteCount: Int
        var sha256: String
    }

    var schemaVersion: Int
    var planningParentCommit: String
    var producerRevision: String
    var generatorPath: String
    var generatorSHA256: String
    var producer: String
    var privacy: String
    var foundationWire: String
    var entries: [Entry]
}

private struct SyntheticWireProbe: Codable {
    var date: Date
    var data: Data
    var id: UUID
}

private enum FixtureError: Error, LocalizedError {
    case usage
    case unsafeFixtureRoot(String)
    case unsafeRelativePath(String)
    case invalidManifest
    case fixtureSetDrift(expected: Set<String>, actual: Set<String>)
    case fixtureHashMismatch(String)
    case semanticMismatch(String)
    case foundationWireChanged
    case negativeFixtureAccepted(String)
    case unexercisedFixtures(Set<String>)
    case privateDataDetected(String)

    var errorDescription: String? {
        switch self {
        case .usage: return "Use --generate or --validate."
        case .unsafeFixtureRoot(let path): return "Unsafe fixture root: \(path)"
        case .unsafeRelativePath(let path): return "Unsafe fixture path: \(path)"
        case .invalidManifest: return "Fixture manifest provenance is invalid."
        case .fixtureSetDrift(let expected, let actual): return "Fixture set drift. Expected \(expected), actual \(actual)."
        case .fixtureHashMismatch(let path): return "Fixture hash mismatch: \(path)"
        case .semanticMismatch(let name): return "Fixture semantic mismatch: \(name)"
        case .foundationWireChanged: return "Default Foundation JSON wire representation changed."
        case .negativeFixtureAccepted(let name): return "Negative fixture unexpectedly decoded: \(name)"
        case .unexercisedFixtures(let paths): return "Package fixtures lack executable assertions: \(paths.sorted())"
        case .privateDataDetected(let path): return "Fixture may contain private machine/user data: \(path)"
        }
    }
}
