import Darwin
import Foundation
import VoxboardCaptureCore

public enum RecordingJobSource: String, Codable, CaseIterable, Sendable {
    case iOSApp
    case macApp
    case macClipboard
    case iOSKeyboard
    case importedAudio
    case recovered
}

public enum RecordingJobDelivery: Codable, Equatable, Sendable {
    case preset(CapturePreset)
    case captureDraft(attachAudio: Bool)
    case clipboard
    case keyboard(requestID: String)
    case recovery
}

public enum RecordingJobPhase: String, Codable, CaseIterable, Sendable {
    case queued
    case processing
    case finalizing
    case completed
    case failed
    case discarded

    public var isTerminal: Bool {
        self == .completed || self == .discarded
    }
}

public enum RecordingJobFailureStage: String, Codable, Sendable {
    case storage
    case transcription
    case delivery
}

public enum SourceAudioRetentionMode: String, Codable, CaseIterable, Sendable {
    case deleteAfterSuccess
    case timed
    case permanent
}

public struct SourceAudioRetentionPolicy: Codable, Equatable, Sendable {
    public static let defaultTimedRetention: TimeInterval = 7 * 24 * 60 * 60

    public var mode: SourceAudioRetentionMode
    public var retentionInterval: TimeInterval?

    public init(
        mode: SourceAudioRetentionMode,
        retentionInterval: TimeInterval? = nil
    ) {
        self.mode = mode
        if mode == .timed {
            self.retentionInterval = max(60, retentionInterval ?? Self.defaultTimedRetention)
        } else {
            self.retentionInterval = nil
        }
    }

    public static let deleteAfterSuccess = SourceAudioRetentionPolicy(mode: .deleteAfterSuccess)
    public static let permanent = SourceAudioRetentionPolicy(mode: .permanent)

    public static func timed(_ interval: TimeInterval) -> SourceAudioRetentionPolicy {
        SourceAudioRetentionPolicy(mode: .timed, retentionInterval: interval)
    }
}

public enum RecordingJobProcessingPolicy: String, Codable, CaseIterable, Sendable {
    case immediate
    case whenIdle
    case manual
}

public struct RecordingQueueConfiguration: Codable, Equatable, Sendable {
    public var sourceAudioRetention: SourceAudioRetentionPolicy
    public var processingPolicy: RecordingJobProcessingPolicy

    public init(
        sourceAudioRetention: SourceAudioRetentionPolicy = .deleteAfterSuccess,
        processingPolicy: RecordingJobProcessingPolicy = .immediate
    ) {
        self.sourceAudioRetention = sourceAudioRetention
        self.processingPolicy = processingPolicy
    }

    public static let `default` = RecordingQueueConfiguration()
}

/// Durable pre-enqueue metadata for app-owned audio. Recorders write this
/// before awaiting origin resolution or conversion so relaunch recovery can
/// create the exact intended job without consulting mutable app state or
/// acquiring location again.
public enum RecordingJobHandoffReadiness: String, Codable, Sendable {
    case staging
    case ready
}

public struct RecordingJobHandoffIntent: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var readiness: RecordingJobHandoffReadiness
    public var jobID: UUID
    public var audioFilename: String
    public var relatedAudioFilenames: [String]
    public var requestID: String?
    public var draftRequestID: UUID?
    public var liveSessionID: UUID?
    public var captureSource: CaptureSource?
    public var locationOutcome: CaptureLocationOutcome?
    public var createdAt: Date
    public var duration: TimeInterval
    public var source: RecordingJobSource
    public var delivery: RecordingJobDelivery
    /// Immutable voice-only policy captured at the recording/import boundary.
    /// Kept separate from delivery so a draft does not inherit preset export or formatting.
    public var voiceProcessingConfiguration: RecordingVoiceProcessingConfiguration?
    public var modelID: String
    public var fallbackModelID: String?
    public var language: String
    public var configuration: RecordingQueueConfiguration

    public init(
        jobID: UUID = UUID(),
        readiness: RecordingJobHandoffReadiness = .staging,
        audioFilename: String,
        relatedAudioFilenames: [String] = [],
        requestID: String? = nil,
        draftRequestID: UUID? = nil,
        liveSessionID: UUID? = nil,
        captureSource: CaptureSource? = nil,
        locationOutcome: CaptureLocationOutcome? = nil,
        createdAt: Date = Date(),
        duration: TimeInterval,
        source: RecordingJobSource,
        delivery: RecordingJobDelivery,
        voiceProcessingConfiguration: RecordingVoiceProcessingConfiguration? = nil,
        modelID: String,
        fallbackModelID: String? = nil,
        language: String,
        configuration: RecordingQueueConfiguration
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.readiness = readiness
        precondition(Self.isSafeFilename(audioFilename), "Unsafe recording handoff filename")
        precondition(
            relatedAudioFilenames.allSatisfy(Self.isSafeFilename)
                && !relatedAudioFilenames.contains(audioFilename)
                && Set(relatedAudioFilenames).count == relatedAudioFilenames.count,
            "Unsafe or duplicate recording handoff related filename"
        )
        self.jobID = jobID
        self.audioFilename = audioFilename
        self.relatedAudioFilenames = relatedAudioFilenames
        self.requestID = requestID
        self.draftRequestID = draftRequestID
        self.liveSessionID = liveSessionID
        self.captureSource = captureSource
        self.locationOutcome = locationOutcome
        self.createdAt = createdAt
        self.duration = duration
        self.source = source
        self.delivery = delivery
        self.voiceProcessingConfiguration = voiceProcessingConfiguration
        self.modelID = modelID
        self.fallbackModelID = fallbackModelID
        self.language = language
        self.configuration = configuration
    }

    /// Publishes the completed handoff while preserving every producer-boundary
    /// field. Only conversion/location results may change after staging.
    public func finalized(
        audioFilename: String,
        relatedAudioFilenames: [String] = [],
        duration: TimeInterval,
        captureSource: CaptureSource?,
        locationOutcome: CaptureLocationOutcome?
    ) -> Self {
        precondition(Self.isSafeFilename(audioFilename), "Unsafe recording handoff filename")
        precondition(
            relatedAudioFilenames.allSatisfy(Self.isSafeFilename)
                && !relatedAudioFilenames.contains(audioFilename)
                && Set(relatedAudioFilenames).count == relatedAudioFilenames.count,
            "Unsafe or duplicate recording handoff related filename"
        )
        var result = self
        result.readiness = .ready
        result.audioFilename = audioFilename
        result.relatedAudioFilenames = relatedAudioFilenames
        result.duration = duration
        result.captureSource = captureSource
        result.locationOutcome = locationOutcome
        return result
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported recording handoff schema"
            )
        }
        readiness = try container.decode(RecordingJobHandoffReadiness.self, forKey: .readiness)
        jobID = try container.decode(UUID.self, forKey: .jobID)
        audioFilename = try container.decode(String.self, forKey: .audioFilename)
        relatedAudioFilenames = try container.decode([String].self, forKey: .relatedAudioFilenames)
        guard Self.isSafeFilename(audioFilename),
              relatedAudioFilenames.allSatisfy(Self.isSafeFilename),
              !relatedAudioFilenames.contains(audioFilename),
              Set(relatedAudioFilenames).count == relatedAudioFilenames.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .audioFilename,
                in: container,
                debugDescription: "Unsafe or duplicate recording handoff filename"
            )
        }
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        draftRequestID = try container.decodeIfPresent(UUID.self, forKey: .draftRequestID)
        liveSessionID = try container.decodeIfPresent(UUID.self, forKey: .liveSessionID)
        captureSource = try container.decodeIfPresent(CaptureSource.self, forKey: .captureSource)
        locationOutcome = try container.decodeIfPresent(CaptureLocationOutcome.self, forKey: .locationOutcome)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        source = try container.decode(RecordingJobSource.self, forKey: .source)
        delivery = try container.decode(RecordingJobDelivery.self, forKey: .delivery)
        voiceProcessingConfiguration = try container.decodeIfPresent(
            RecordingVoiceProcessingConfiguration.self,
            forKey: .voiceProcessingConfiguration
        )
        modelID = try container.decode(String.self, forKey: .modelID)
        fallbackModelID = try container.decodeIfPresent(String.self, forKey: .fallbackModelID)
        language = try container.decode(String.self, forKey: .language)
        configuration = try container.decode(RecordingQueueConfiguration.self, forKey: .configuration)
    }

    private static func isSafeFilename(_ filename: String) -> Bool {
        !filename.isEmpty
            && filename != "."
            && filename != ".."
            && !filename.contains("/")
            && !filename.contains("\\")
            && URL(fileURLWithPath: filename).lastPathComponent == filename
    }
}

/// Synchronous atomic writer used at the recorder's stop/import boundary. The
/// queue store consumes these files only after its job manifest is durable.
public struct RecordingJobHandoffIntentStore: Sendable {
    public let recordingsDirectoryURL: URL

    public init(recordingsDirectoryURL: URL) {
        self.recordingsDirectoryURL = recordingsDirectoryURL
    }

    public func save(_ intent: RecordingJobHandoffIntent) throws {
        let directory = Self.directoryURL(in: recordingsDirectoryURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(intent).write(to: Self.url(for: intent.jobID, in: directory), options: .atomic)
    }

    public func load(jobID: UUID) throws -> RecordingJobHandoffIntent? {
        let url = Self.url(for: jobID, in: Self.directoryURL(in: recordingsDirectoryURL))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(RecordingJobHandoffIntent.self, from: Data(contentsOf: url))
    }

    static func directoryURL(in recordingsDirectoryURL: URL) -> URL {
        recordingsDirectoryURL.appendingPathComponent(".recording-handoff-intents", isDirectory: true)
    }

    static func url(for jobID: UUID, in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(jobID.uuidString.lowercased()).appendingPathExtension("json")
    }
}

/// Durable receipt written only after an interactive recording was delivered.
/// If source cleanup is interrupted, orphan recovery consumes the marked file
/// instead of presenting an already-delivered transcript as retryable work.
public enum RecordingArtifactDeliveryReceipt {
    public static let markerExtension = "vox-delivered"

    public static func markerURL(for artifactURL: URL) -> URL {
        artifactURL.appendingPathExtension(markerExtension)
    }

    public static func write(for artifactURL: URL) throws {
        let markerURL = markerURL(for: artifactURL)
        try Data("voxboard-delivered-v1\n".utf8).write(to: markerURL, options: .atomic)
    }

    public static func exists(
        for artifactURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(atPath: markerURL(for: artifactURL).path)
    }

    public static func remove(
        for artifactURL: URL,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: markerURL(for: artifactURL))
    }
}

public enum RecordingJobExternalDeliveryArtifact: String, Codable, Sendable {
    case note
    case audio
    case noteAudioReference
}

public enum RecordingQueuePreferences {
    public static let retentionModeKey = "recordingQueue.audioRetention.mode.v1"
    public static let retentionIntervalKey = "recordingQueue.audioRetention.interval.v1"
    public static let processingPolicyKey = "recordingQueue.processingPolicy.v1"

    public static func load(from defaults: UserDefaults? = AppConstants.sharedDefaults) -> RecordingQueueConfiguration {
        guard let defaults else { return .default }
        let retentionMode = defaults.string(forKey: retentionModeKey)
            .flatMap(SourceAudioRetentionMode.init(rawValue:))
            ?? .deleteAfterSuccess
        let retentionInterval: TimeInterval?
        if retentionMode == .timed {
            let stored = defaults.double(forKey: retentionIntervalKey)
            retentionInterval = stored > 0 ? stored : SourceAudioRetentionPolicy.defaultTimedRetention
        } else {
            retentionInterval = nil
        }
        let processingPolicy = defaults.string(forKey: processingPolicyKey)
            .flatMap(RecordingJobProcessingPolicy.init(rawValue:))
            ?? .immediate
        return RecordingQueueConfiguration(
            sourceAudioRetention: SourceAudioRetentionPolicy(
                mode: retentionMode,
                retentionInterval: retentionInterval
            ),
            processingPolicy: processingPolicy
        )
    }

    public static func save(
        _ configuration: RecordingQueueConfiguration,
        to defaults: UserDefaults? = AppConstants.sharedDefaults
    ) {
        guard let defaults else { return }
        defaults.set(configuration.sourceAudioRetention.mode.rawValue, forKey: retentionModeKey)
        if let retentionInterval = configuration.sourceAudioRetention.retentionInterval {
            defaults.set(retentionInterval, forKey: retentionIntervalKey)
        } else {
            defaults.removeObject(forKey: retentionIntervalKey)
        }
        defaults.set(configuration.processingPolicy.rawValue, forKey: processingPolicyKey)
    }
}

public struct RecordingJob: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var id: UUID
    public var requestID: String?
    public var draftRequestID: UUID?
    public var liveSessionID: UUID?
    /// Origin-bound metadata captured before the job enters the durable queue.
    /// Optional for legacy/recovered jobs, which must not synthesize a location.
    public var captureSource: CaptureSource?
    public var locationOutcome: CaptureLocationOutcome?
    public var audioFilename: String
    /// Fixed-role artifacts for schema v2. Legacy schema-v1 jobs decode nil and
    /// are treated as one `.primaryAudio` artifact.
    public var artifacts: [RecordingArtifact]?
    public var originalFilename: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var duration: TimeInterval
    public var source: RecordingJobSource
    public var delivery: RecordingJobDelivery
    /// Immutable voice-only policy for draft delivery. Preset delivery derives
    /// the policy from its own immutable preset snapshot.
    public var voiceProcessingConfiguration: RecordingVoiceProcessingConfiguration?
    public var modelID: String
    public var fallbackModelID: String?
    public var language: String
    public var retentionPolicy: SourceAudioRetentionPolicy
    public var processingPolicy: RecordingJobProcessingPolicy
    public var initialProcessingPolicy: RecordingJobProcessingPolicy?
    public var phase: RecordingJobPhase
    public var failureStage: RecordingJobFailureStage?
    public var statusMessage: String?
    public var attemptCount: Int
    public var revision: Int
    public var transcriptText: String?
    public var automaticClipboardDeliveryAttemptedAt: Date?
    public var exportedNotePath: String?
    public var exportedAudioPath: String?
    public var audioReferenceAttachedAt: Date?
    public var completedAt: Date?
    public var audioDeletionDate: Date?
    public var audioDeletedAt: Date?

    public init(
        id: UUID = UUID(),
        requestID: String? = nil,
        draftRequestID: UUID? = nil,
        liveSessionID: UUID? = nil,
        captureSource: CaptureSource? = nil,
        locationOutcome: CaptureLocationOutcome? = nil,
        audioFilename: String,
        artifacts: [RecordingArtifact]? = nil,
        originalFilename: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        duration: TimeInterval,
        source: RecordingJobSource,
        delivery: RecordingJobDelivery,
        voiceProcessingConfiguration: RecordingVoiceProcessingConfiguration? = nil,
        modelID: String,
        fallbackModelID: String? = nil,
        language: String,
        retentionPolicy: SourceAudioRetentionPolicy,
        processingPolicy: RecordingJobProcessingPolicy,
        initialProcessingPolicy: RecordingJobProcessingPolicy? = nil,
        phase: RecordingJobPhase = .queued,
        failureStage: RecordingJobFailureStage? = nil,
        statusMessage: String? = nil,
        attemptCount: Int = 0,
        revision: Int = 1,
        transcriptText: String? = nil,
        automaticClipboardDeliveryAttemptedAt: Date? = nil,
        exportedNotePath: String? = nil,
        exportedAudioPath: String? = nil,
        audioReferenceAttachedAt: Date? = nil,
        completedAt: Date? = nil,
        audioDeletionDate: Date? = nil,
        audioDeletedAt: Date? = nil
    ) {
        self.schemaVersion = artifacts == nil ? 1 : Self.currentSchemaVersion
        self.id = id
        self.requestID = requestID
        self.draftRequestID = draftRequestID
        self.liveSessionID = liveSessionID
        self.captureSource = captureSource
        self.locationOutcome = locationOutcome
        self.audioFilename = audioFilename
        self.artifacts = artifacts
        self.originalFilename = originalFilename
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.duration = max(0, duration)
        self.source = source
        self.delivery = delivery
        self.voiceProcessingConfiguration = voiceProcessingConfiguration
        self.modelID = modelID
        self.fallbackModelID = fallbackModelID
        self.language = language
        self.retentionPolicy = retentionPolicy
        self.processingPolicy = processingPolicy
        self.initialProcessingPolicy = initialProcessingPolicy ?? processingPolicy
        self.phase = phase
        self.failureStage = failureStage
        self.statusMessage = statusMessage
        self.attemptCount = attemptCount
        self.revision = revision
        self.transcriptText = transcriptText
        self.automaticClipboardDeliveryAttemptedAt = automaticClipboardDeliveryAttemptedAt
        self.exportedNotePath = exportedNotePath
        self.exportedAudioPath = exportedAudioPath
        self.audioReferenceAttachedAt = audioReferenceAttachedAt
        self.completedAt = completedAt
        self.audioDeletionDate = audioDeletionDate
        self.audioDeletedAt = audioDeletedAt
    }

    public var resolvedArtifacts: [RecordingArtifact] {
        if schemaVersion == 1 {
            return [RecordingArtifact(role: .primaryAudio, filename: audioFilename, originalFilename: originalFilename)]
        }
        return artifacts ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, requestID, draftRequestID, liveSessionID, captureSource, locationOutcome
        case audioFilename, artifacts, originalFilename, createdAt, updatedAt, duration, source, delivery
        case voiceProcessingConfiguration, modelID, fallbackModelID, language, retentionPolicy, processingPolicy, initialProcessingPolicy
        case phase, failureStage, statusMessage, attemptCount, revision, transcriptText
        case automaticClipboardDeliveryAttemptedAt, exportedNotePath, exportedAudioPath
        case audioReferenceAttachedAt, completedAt, audioDeletionDate, audioDeletedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 || schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c, debugDescription: "Unsupported recording job schema version \(schemaVersion)")
        }
        id = try c.decode(UUID.self, forKey: .id)
        requestID = try c.decodeIfPresent(String.self, forKey: .requestID)
        draftRequestID = try c.decodeIfPresent(UUID.self, forKey: .draftRequestID)
        liveSessionID = try c.decodeIfPresent(UUID.self, forKey: .liveSessionID)
        captureSource = try c.decodeIfPresent(CaptureSource.self, forKey: .captureSource)
        locationOutcome = try c.decodeIfPresent(CaptureLocationOutcome.self, forKey: .locationOutcome)
        audioFilename = try c.decode(String.self, forKey: .audioFilename)
        artifacts = try c.decodeIfPresent([RecordingArtifact].self, forKey: .artifacts)
        originalFilename = try c.decodeIfPresent(String.self, forKey: .originalFilename)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        source = try c.decode(RecordingJobSource.self, forKey: .source)
        delivery = try c.decode(RecordingJobDelivery.self, forKey: .delivery)
        modelID = try c.decode(String.self, forKey: .modelID)
        fallbackModelID = try c.decodeIfPresent(String.self, forKey: .fallbackModelID)
        language = try c.decode(String.self, forKey: .language)
        retentionPolicy = try c.decode(SourceAudioRetentionPolicy.self, forKey: .retentionPolicy)
        voiceProcessingConfiguration = try c.decodeIfPresent(
            RecordingVoiceProcessingConfiguration.self,
            forKey: .voiceProcessingConfiguration
        )
        processingPolicy = try c.decode(RecordingJobProcessingPolicy.self, forKey: .processingPolicy)
        initialProcessingPolicy = try c.decodeIfPresent(RecordingJobProcessingPolicy.self, forKey: .initialProcessingPolicy)
        phase = try c.decode(RecordingJobPhase.self, forKey: .phase)
        failureStage = try c.decodeIfPresent(RecordingJobFailureStage.self, forKey: .failureStage)
        statusMessage = try c.decodeIfPresent(String.self, forKey: .statusMessage)
        attemptCount = try c.decode(Int.self, forKey: .attemptCount)
        revision = try c.decode(Int.self, forKey: .revision)
        transcriptText = try c.decodeIfPresent(String.self, forKey: .transcriptText)
        automaticClipboardDeliveryAttemptedAt = try c.decodeIfPresent(Date.self, forKey: .automaticClipboardDeliveryAttemptedAt)
        exportedNotePath = try c.decodeIfPresent(String.self, forKey: .exportedNotePath)
        exportedAudioPath = try c.decodeIfPresent(String.self, forKey: .exportedAudioPath)
        audioReferenceAttachedAt = try c.decodeIfPresent(Date.self, forKey: .audioReferenceAttachedAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        audioDeletionDate = try c.decodeIfPresent(Date.self, forKey: .audioDeletionDate)
        audioDeletedAt = try c.decodeIfPresent(Date.self, forKey: .audioDeletedAt)

        guard Self.safeFilename(audioFilename) else {
            throw DecodingError.dataCorruptedError(forKey: .audioFilename, in: c, debugDescription: "Unsafe recording audio filename")
        }
        if schemaVersion == 1 {
            artifacts = nil
        } else {
            guard let artifacts, !artifacts.isEmpty,
                  Set(artifacts.map(\.role)).count == artifacts.count,
                  Set(artifacts.map(\.filename)).count == artifacts.count,
                  artifacts.allSatisfy({ Self.safeFilename($0.filename) }),
                  artifacts.contains(where: { $0.filename == audioFilename }) else {
                throw DecodingError.dataCorruptedError(forKey: .artifacts, in: c, debugDescription: "Malformed recording artifact bundle")
            }
        }
    }

    private static func safeFilename(_ filename: String) -> Bool {
        !filename.isEmpty && filename != "." && filename != ".." && !filename.contains("/")
            && !filename.contains("\\") && URL(fileURLWithPath: filename).lastPathComponent == filename
    }

    public var effectiveVoiceProcessingConfiguration: RecordingVoiceProcessingConfiguration? {
        if case .preset(let preset) = delivery {
            return RecordingVoiceProcessingConfiguration(preset: preset)
        }
        return voiceProcessingConfiguration
    }
}

struct RecordingBundleEnqueueIntent: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    struct Source: Codable, Equatable, Sendable {
        var role: RecordingArtifactRole
        var sourcePath: String
        var expectedByteCount: Int64
        var filename: String
        var originalFilename: String
    }

    var schemaVersion = currentSchemaVersion
    var job: RecordingJob
    var sources: [Source]
    var removeSourcesAfterCommit: Bool
}

public enum RecordingJobStoreError: Error, Equatable, LocalizedError, Sendable {
    case sourceMissing
    case sourceEmpty
    case copyVerificationFailed
    case jobNotFound(UUID)
    case audioMissing(UUID)
    case invalidTransition(UUID, RecordingJobPhase, RecordingJobPhase)
    case unsupportedSchemaVersion(Int)
    case jobIsActive(UUID)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing:
            return "The source recording could not be found."
        case .sourceEmpty:
            return "The source recording is empty."
        case .copyVerificationFailed:
            return "The durable recording copy could not be verified."
        case .jobNotFound(let id):
            return "Recording job \(id.uuidString) could not be found."
        case .audioMissing(let id):
            return "Recording job \(id.uuidString) no longer has source audio."
        case .invalidTransition(let id, let from, let to):
            return "Recording job \(id.uuidString) cannot move from \(from.rawValue) to \(to.rawValue)."
        case .unsupportedSchemaVersion(let version):
            return "Recording job schema version \(version) is not supported."
        case .jobIsActive(let id):
            return "Recording job \(id.uuidString) is currently processing."
        }
    }
}

public actor RecordingJobStore {
    public nonisolated static let didChangeNotification = Notification.Name("RecordingJobStoreDidChange")
    public nonisolated let rootDirectoryURL: URL

    private let coordinator: any CaptureFileCoordinating
    private let fileManager: FileManager
    private var workerLockFileDescriptor: Int32?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let now: @Sendable () -> Date

    private var itemsDirectoryURL: URL {
        rootDirectoryURL.appendingPathComponent("items", isDirectory: true)
    }

    public nonisolated func ownsChangeNotification(_ notification: Notification) -> Bool {
        (notification.object as? URL)?.standardizedFileURL
            == rootDirectoryURL.standardizedFileURL
    }

    public nonisolated func externalDeliveryTransactionDirectoryURL(
        for id: UUID,
        artifact: RecordingJobExternalDeliveryArtifact
    ) -> URL {
        rootDirectoryURL
            .appendingPathComponent("delivery-intents", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(artifact.rawValue, isDirectory: true)
    }

    private var audioDirectoryURL: URL {
        rootDirectoryURL.appendingPathComponent("audio", isDirectory: true)
    }

    private var bundleIntentsDirectoryURL: URL {
        rootDirectoryURL.appendingPathComponent("bundle-intents", isDirectory: true)
    }

    public init(
        rootDirectoryURL: URL,
        coordinator: any CaptureFileCoordinating = NSFileCoordinatorCaptureFileCoordinator.shared,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rootDirectoryURL = rootDirectoryURL
        self.coordinator = coordinator
        self.fileManager = fileManager
        self.now = now
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public init?() {
        guard let rootDirectoryURL = AppConstants.recordingJobsDirectoryURL else { return nil }
        self.init(rootDirectoryURL: rootDirectoryURL)
    }

    @discardableResult
    public func enqueueBundle(
        sources: [(role: RecordingArtifactRole, url: URL)],
        id: UUID = UUID(),
        requestID: String? = nil,
        draftRequestID: UUID? = nil,
        liveSessionID: UUID? = nil,
        captureSource: CaptureSource? = nil,
        locationOutcome: CaptureLocationOutcome? = nil,
        createdAt: Date = Date(),
        duration: TimeInterval,
        source: RecordingJobSource,
        delivery: RecordingJobDelivery,
        modelID: String,
        fallbackModelID: String? = nil,
        language: String,
        configuration: RecordingQueueConfiguration,
        removeSourcesAfterCommit: Bool = true
    ) throws -> RecordingJob {
        guard !sources.isEmpty, Set(sources.map(\.role)).count == sources.count else {
            throw RecordingJobStoreError.sourceMissing
        }
        let job = try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            _ = recoverPendingBundleEnqueues()
            if let existing = try loadItem(id: id) { return existing }
            // A valid but temporarily unrecoverable transaction owns this ID
            // and its deterministic destinations; never overwrite its journal.
            if fileManager.fileExists(atPath: bundleIntentURL(id: id).path) {
                throw RecordingJobStoreError.copyVerificationFailed
            }

            // Validate every source before publishing the durable transaction.
            // A missing member must not leave a partial bundle or intent behind.
            let entries: [RecordingBundleEnqueueIntent.Source] = try sources.map { source in
                guard fileManager.fileExists(atPath: source.url.path) else { throw RecordingJobStoreError.sourceMissing }
                let size = try fileSize(at: source.url)
                guard size > 0 else { throw RecordingJobStoreError.sourceEmpty }
                let ext = sanitizedExtension(source.url.pathExtension)
                let filename = "\(id.uuidString.lowercased())-\(source.role.rawValue)\(ext.isEmpty ? "" : ".\(ext)")"
                return .init(
                    role: source.role,
                    sourcePath: source.url.path,
                    expectedByteCount: size,
                    filename: filename,
                    originalFilename: source.url.lastPathComponent
                )
            }
            let artifacts = entries.map {
                RecordingArtifact(role: $0.role, filename: $0.filename, originalFilename: $0.originalFilename)
            }
            guard let primary = artifacts.first(where: { $0.role == .playbackMix })
                ?? artifacts.first(where: { $0.role == .meetingSystem })
                ?? artifacts.first else {
                throw RecordingJobStoreError.sourceMissing
            }
            let job = RecordingJob(
                id: id, requestID: requestID, draftRequestID: draftRequestID, liveSessionID: liveSessionID,
                captureSource: captureSource, locationOutcome: locationOutcome,
                audioFilename: primary.filename, artifacts: artifacts, originalFilename: primary.originalFilename,
                createdAt: createdAt, duration: duration, source: source, delivery: delivery,
                modelID: modelID, fallbackModelID: fallbackModelID, language: language,
                retentionPolicy: configuration.sourceAudioRetention, processingPolicy: configuration.processingPolicy,
                statusMessage: queuedMessage(for: configuration.processingPolicy)
            )
            let intent = RecordingBundleEnqueueIntent(
                job: job,
                sources: entries,
                removeSourcesAfterCommit: removeSourcesAfterCommit
            )
            let intentURL = bundleIntentURL(id: id)
            do {
                try encoder.encode(intent).write(to: intentURL, options: .atomic)
                try materializeBundle(intent)
                try persist(job)
                finishBundleCommit(intent, intentURL: intentURL)
                return job
            } catch {
                // A thrown in-process operation retains the previous rollback
                // contract. A process exit does not execute this path, leaving
                // the intent to be reconciled before generic orphan recovery.
                for entry in entries {
                    try? fileManager.removeItem(at: bundleTemporaryURL(filename: entry.filename))
                    try? fileManager.removeItem(at: audioDirectoryURL.appendingPathComponent(entry.filename))
                }
                try? fileManager.removeItem(at: intentURL)
                throw error
            }
        }
        notifyChanged()
        return job
    }

    public func enqueue(
        sourceURL: URL,
        id: UUID = UUID(),
        requestID: String? = nil,
        draftRequestID: UUID? = nil,
        liveSessionID: UUID? = nil,
        captureSource: CaptureSource? = nil,
        locationOutcome: CaptureLocationOutcome? = nil,
        originalFilename: String? = nil,
        createdAt: Date = Date(),
        duration: TimeInterval,
        source: RecordingJobSource,
        delivery: RecordingJobDelivery,
        voiceProcessingConfiguration: RecordingVoiceProcessingConfiguration? = nil,
        modelID: String,
        fallbackModelID: String? = nil,
        language: String,
        configuration: RecordingQueueConfiguration,
        removeSourceAfterCommit: Bool = true
    ) throws -> RecordingJob {
        let job = try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            if let existing = try loadItem(id: id) { return existing }
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw RecordingJobStoreError.sourceMissing
            }
            let sourceSize = try fileSize(at: sourceURL)
            guard sourceSize > 0 else { throw RecordingJobStoreError.sourceEmpty }

            let ext = sanitizedExtension(sourceURL.pathExtension)
            let audioFilename = ext.isEmpty
                ? id.uuidString.lowercased()
                : "\(id.uuidString.lowercased()).\(ext)"
            let destinationURL = audioDirectoryURL.appendingPathComponent(audioFilename)
            let temporaryURL = audioDirectoryURL.appendingPathComponent(".\(audioFilename).partial")

            if sourceURL.standardizedFileURL != destinationURL.standardizedFileURL,
               !fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
                do {
                    try fileManager.copyItem(at: sourceURL, to: temporaryURL)
                    guard try fileSize(at: temporaryURL) == sourceSize else {
                        throw RecordingJobStoreError.copyVerificationFailed
                    }
                    try fileManager.moveItem(at: temporaryURL, to: destinationURL)
                } catch {
                    try? fileManager.removeItem(at: temporaryURL)
                    throw error
                }
            }
            guard fileManager.fileExists(atPath: destinationURL.path),
                  try fileSize(at: destinationURL) == sourceSize else {
                throw RecordingJobStoreError.copyVerificationFailed
            }

            let job = RecordingJob(
                id: id,
                requestID: requestID,
                draftRequestID: draftRequestID,
                liveSessionID: liveSessionID,
                captureSource: captureSource,
                locationOutcome: locationOutcome,
                audioFilename: audioFilename,
                originalFilename: originalFilename ?? sourceURL.lastPathComponent,
                createdAt: createdAt,
                duration: duration,
                source: source,
                delivery: delivery,
                voiceProcessingConfiguration: voiceProcessingConfiguration,
                modelID: modelID,
                fallbackModelID: fallbackModelID,
                language: language,
                retentionPolicy: configuration.sourceAudioRetention,
                processingPolicy: configuration.processingPolicy,
                statusMessage: queuedMessage(for: configuration.processingPolicy)
            )
            try persist(job)

            // Suppress the primary source before consuming the handoff intent.
            // If the process stops between these steps, either the intent or the
            // delivery receipt still prevents legacy orphan recovery from
            // creating a duplicate job.
            if removeSourceAfterCommit,
               sourceURL.standardizedFileURL != destinationURL.standardizedFileURL {
                suppressAndRemoveExternalArtifact(sourceURL)
            }
            try? consumeHandoffIntent(
                jobID: id,
                recordingsDirectoryURL: sourceURL.deletingLastPathComponent()
            )
            return job
        }
        notifyChanged()
        return job
    }

    /// Acquires the process-wide queue worker lock. The caller must release it
    /// after its drain loop. This prevents another app process from treating a
    /// live `.processing` claim as an interrupted relaunch job.
    public func tryAcquireWorkerLease() throws -> Bool {
        try acquireWorkerLockIfAvailable()
    }

    public func releaseWorkerLease() {
        releaseWorkerLock()
    }

    public func load(recoverInterrupted: Bool = true) throws -> [RecordingJob] {
        let alreadyHeldWorkerLock = workerLockFileDescriptor != nil
        let mayRecoverInterrupted = try recoverInterrupted && acquireWorkerLockIfAvailable()
        defer {
            if !alreadyHeldWorkerLock, mayRecoverInterrupted {
                releaseWorkerLock()
            }
        }
        let jobs = try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            let pendingBundleArtifacts = recoverPendingBundleEnqueues()
            var jobs = try loadItems()
            var changed = false

            if mayRecoverInterrupted {
                for index in jobs.indices where jobs[index].phase == .processing || jobs[index].phase == .finalizing {
                    jobs[index].phase = .queued
                    jobs[index].failureStage = nil
                    jobs[index].statusMessage = "Recovered after Vox.md was interrupted"
                    touch(&jobs[index])
                    try persist(jobs[index])
                    changed = true
                }
            }

            for index in jobs.indices {
                let audioExists = artifactURLs(for: jobs[index]).allSatisfy { fileManager.fileExists(atPath: $0.path) }
                guard !audioExists, jobs[index].phase != .discarded else { continue }
                if jobs[index].phase == .completed,
                   jobs[index].audioDeletedAt != nil
                    || (jobs[index].audioDeletionDate.map { $0 <= Date() } == true) {
                    if jobs[index].audioDeletedAt == nil {
                        jobs[index].audioDeletedAt = jobs[index].audioDeletionDate ?? Date()
                        touch(&jobs[index])
                        try persist(jobs[index])
                        changed = true
                    }
                    continue
                }
                jobs[index].phase = .failed
                jobs[index].failureStage = .storage
                jobs[index].statusMessage = "The source recording could not be found"
                touch(&jobs[index])
                try persist(jobs[index])
                changed = true
            }

            let referenced = Set(jobs.flatMap { $0.resolvedArtifacts.map(\.filename) })
                .union(pendingBundleArtifacts)
            let audioURLs = try fileManager.contentsOfDirectory(
                at: audioDirectoryURL,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            for url in audioURLs where !referenced.contains(url.lastPathComponent) {
                guard (try? fileSize(at: url)) ?? 0 > 0 else { continue }
                let recovered = RecordingJob(
                    audioFilename: url.lastPathComponent,
                    originalFilename: url.lastPathComponent,
                    createdAt: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date(),
                    duration: 0,
                    source: .recovered,
                    delivery: .recovery,
                    modelID: "",
                    language: "auto",
                    retentionPolicy: .permanent,
                    processingPolicy: .manual,
                    phase: .failed,
                    failureStage: .storage,
                    statusMessage: "Recovered an interrupted recording; choose how to process it"
                )
                try persist(recovered)
                jobs.append(recovered)
                changed = true
            }

            if changed {
                jobs.sort(by: Self.sortJobs)
            }
            return jobs
        }
        if mayRecoverInterrupted { notifyChanged() }
        return jobs
    }

    /// Imports source files left by pre-queue releases or an interrupted direct
    /// keyboard transcription. Durable handoff intents are recovered first and
    /// preserve the original identity, delivery, preset, and location result.
    /// Legacy files without an intent retain the generic manual recovery path.
    @discardableResult
    public func recoverExternalOrphans(
        recordingsDirectoryURL: URL,
        olderThan cutoff: Date = Date().addingTimeInterval(-60)
    ) throws -> [RecordingJob] {
        var recovered = try recoverHandoffIntents(
            recordingsDirectoryURL: recordingsDirectoryURL,
            olderThan: cutoff
        )
        let recoveredFilenames = Set(recovered.compactMap(\.originalFilename))
        let claimedFilenames = try handoffClaimedFilenames(recordingsDirectoryURL: recordingsDirectoryURL)
            .union(recoveredFilenames)
        let allowedPrefixes = [
            "recording_",
            "segment_",
            "import_",
            "import_source_",
            "mac_import_",
            "mac_import_source_",
        ]
        let supportedExtensions = Set(["wav", "m4a", "mp3", "mp4", "caf", "aif", "aiff", "mov"])
        let contents = try fileManager.contentsOfDirectory(
            at: recordingsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for markerURL in contents
            where markerURL.pathExtension == RecordingArtifactDeliveryReceipt.markerExtension {
            let artifactURL = markerURL.deletingPathExtension()
            if !fileManager.fileExists(atPath: artifactURL.path) {
                try? fileManager.removeItem(at: markerURL)
            }
        }

        var candidates: [URL] = []
        for url in contents {
            guard url.deletingLastPathComponent().standardizedFileURL
                    == recordingsDirectoryURL.standardizedFileURL,
                  supportedExtensions.contains(url.pathExtension.lowercased()),
                  allowedPrefixes.contains(where: { prefix in
                      url.lastPathComponent.hasPrefix(prefix)
                  }),
                  !claimedFilenames.contains(url.lastPathComponent) else {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true,
                  (values?.contentModificationDate ?? .distantPast) <= cutoff else {
                continue
            }
            if RecordingArtifactDeliveryReceipt.exists(for: url, fileManager: fileManager) {
                do {
                    try fileManager.removeItem(at: url)
                    RecordingArtifactDeliveryReceipt.remove(for: url, fileManager: fileManager)
                } catch {
                    // Keep both artifact and receipt. A later launch retries
                    // cleanup, but this delivered source is never reprocessed.
                }
                continue
            }
            candidates.append(url)
        }

        for url in candidates {
            let job = try enqueue(
                sourceURL: url,
                originalFilename: url.lastPathComponent,
                createdAt: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date(),
                duration: 0,
                source: .recovered,
                delivery: .recovery,
                modelID: "",
                language: "auto",
                configuration: RecordingQueueConfiguration(
                    sourceAudioRetention: .permanent,
                    processingPolicy: .manual
                )
            )
            let failed = try mutate(id: job.id) { item in
                item.phase = .failed
                item.failureStage = .storage
                item.statusMessage = "Recovered an interrupted recording; choose how to process it"
            }
            recovered.append(failed)
        }
        if !recovered.isEmpty { notifyChanged() }
        return recovered
    }

    private func recoverHandoffIntents(
        recordingsDirectoryURL: URL,
        olderThan cutoff: Date
    ) throws -> [RecordingJob] {
        let directoryURL = RecordingJobHandoffIntentStore.directoryURL(in: recordingsDirectoryURL)
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let intents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter({ $0.pathExtension == "json" }).compactMap { intentURL in
            try? decoder.decode(
                RecordingJobHandoffIntent.self,
                from: Data(contentsOf: intentURL)
            )
        }
        return try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            var recovered: [RecordingJob] = []
            for intent in intents {
                // Ready publication is atomic. A staging intent belongs to a
                // live producer until its frozen creation time crosses the
                // caller's orphan cutoff, at which point crash recovery may
                // safely use its placeholder location without reacquisition.
                guard intent.readiness == .ready
                    ? intent.createdAt <= cutoff
                    : intent.createdAt < cutoff else { continue }
                if let existing = try loadItem(id: intent.jobID) {
                    try consumeHandoffIntent(
                        jobID: intent.jobID,
                        recordingsDirectoryURL: recordingsDirectoryURL
                    )
                    recovered.append(existing)
                    continue
                }
                let sourceURL = recordingsDirectoryURL.appendingPathComponent(intent.audioFilename)
                guard fileManager.fileExists(atPath: sourceURL.path) else {
                    // A conversion may have replaced the source name. Preserve
                    // the intent until its named artifact exists again.
                    continue
                }
                let sourceSize = try fileSize(at: sourceURL)
                guard sourceSize > 0 else { continue }
                let ext = sanitizedExtension(sourceURL.pathExtension)
                let audioFilename = ext.isEmpty
                    ? intent.jobID.uuidString.lowercased()
                    : "\(intent.jobID.uuidString.lowercased()).\(ext)"
                let destinationURL = audioDirectoryURL.appendingPathComponent(audioFilename)
                let temporaryURL = audioDirectoryURL.appendingPathComponent(".\(audioFilename).partial")
                if sourceURL.standardizedFileURL != destinationURL.standardizedFileURL,
                   !fileManager.fileExists(atPath: destinationURL.path) {
                    try? fileManager.removeItem(at: temporaryURL)
                    do {
                        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
                        guard try fileSize(at: temporaryURL) == sourceSize else {
                            throw RecordingJobStoreError.copyVerificationFailed
                        }
                        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
                    } catch {
                        try? fileManager.removeItem(at: temporaryURL)
                        throw error
                    }
                }
                let job = RecordingJob(
                    id: intent.jobID,
                    requestID: intent.requestID,
                    draftRequestID: intent.draftRequestID,
                    liveSessionID: intent.liveSessionID,
                    captureSource: intent.captureSource,
                    locationOutcome: intent.locationOutcome,
                    audioFilename: audioFilename,
                    originalFilename: intent.audioFilename,
                    createdAt: intent.createdAt,
                    duration: intent.duration,
                    source: intent.source,
                    delivery: intent.delivery,
                    voiceProcessingConfiguration: intent.voiceProcessingConfiguration,
                    modelID: intent.modelID,
                    fallbackModelID: intent.fallbackModelID,
                    language: intent.language,
                    retentionPolicy: intent.configuration.sourceAudioRetention,
                    processingPolicy: intent.configuration.processingPolicy,
                    statusMessage: queuedMessage(for: intent.configuration.processingPolicy)
                )
                try persist(job)
                try consumeHandoffIntent(
                    jobID: intent.jobID,
                    recordingsDirectoryURL: recordingsDirectoryURL
                )
                recovered.append(job)
            }
            return recovered
        }
    }

    private func handoffClaimedFilenames(recordingsDirectoryURL: URL) throws -> Set<String> {
        let directoryURL = RecordingJobHandoffIntentStore.directoryURL(in: recordingsDirectoryURL)
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        var result = Set<String>()
        for url in try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
            guard let intent = try? decoder.decode(
                RecordingJobHandoffIntent.self,
                from: Data(contentsOf: url)
            ) else { continue }
            result.insert(intent.audioFilename)
            result.formUnion(intent.relatedAudioFilenames)
        }
        return result
    }

    private func consumeHandoffIntent(jobID: UUID, recordingsDirectoryURL: URL) throws {
        let directoryURL = RecordingJobHandoffIntentStore.directoryURL(in: recordingsDirectoryURL)
        let intentURL = RecordingJobHandoffIntentStore.url(for: jobID, in: directoryURL)
        guard fileManager.fileExists(atPath: intentURL.path) else { return }
        let intent = try decoder.decode(RecordingJobHandoffIntent.self, from: Data(contentsOf: intentURL))
        // The job manifest and queue-owned copy are durable before the primary
        // source and related fallbacks are suppressed. Remove the intent last:
        // every crash boundary therefore retains either the intent or a receipt.
        for filename in [intent.audioFilename] + intent.relatedAudioFilenames {
            suppressAndRemoveExternalArtifact(recordingsDirectoryURL.appendingPathComponent(filename))
        }
        try fileManager.removeItem(at: intentURL)
    }

    private func suppressAndRemoveExternalArtifact(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try RecordingArtifactDeliveryReceipt.write(for: url)
            try fileManager.removeItem(at: url)
            RecordingArtifactDeliveryReceipt.remove(for: url, fileManager: fileManager)
        } catch {
            // Keep the receipt. Orphan scanning suppresses this queue-owned
            // source and retries cleanup on a later recovery pass.
        }
    }

    public func job(id: UUID) throws -> RecordingJob? {
        try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            return try loadItem(id: id)
        }
    }

    public nonisolated func audioURL(for job: RecordingJob) -> URL {
        // Treat persisted metadata as untrusted. A malformed relative path must
        // never escape the queue-owned audio directory during cleanup/discard.
        let safeFilename = URL(fileURLWithPath: job.audioFilename).lastPathComponent
        return rootDirectoryURL
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent(safeFilename)
    }

    public func claimNext(includeIdle: Bool) throws -> RecordingJob? {
        let claimed: RecordingJob? = try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            var jobs = try loadItems().filter { job in
                guard job.phase == .queued else { return false }
                switch job.processingPolicy {
                case .immediate:
                    return true
                case .whenIdle:
                    return includeIdle
                case .manual:
                    return false
                }
            }
            jobs.sort(by: Self.sortJobs)
            guard var job = jobs.first else { return nil }
            try ensureAudioExists(for: job)
            job.phase = .processing
            job.failureStage = nil
            job.statusMessage = "Transcribing"
            job.attemptCount += 1
            touch(&job)
            try persist(job)
            return job
        }
        if claimed != nil { notifyChanged() }
        return claimed
    }

    public func claim(id: UUID) throws -> RecordingJob {
        let claimed = try mutate(id: id) { job in
            guard job.phase == .queued || job.phase == .failed else {
                throw RecordingJobStoreError.invalidTransition(job.id, job.phase, .processing)
            }
            try ensureAudioExists(for: job)
            job.phase = .processing
            job.failureStage = nil
            job.statusMessage = "Transcribing"
            job.attemptCount += 1
        }
        notifyChanged()
        return claimed
    }

    public func returnInterruptedJobToQueue(
        id: UUID,
        message: String = "Paused for interactive transcription"
    ) throws -> RecordingJob {
        let updated = try mutate(id: id) { job in
            guard job.phase == .processing || job.phase == .finalizing else {
                throw RecordingJobStoreError.invalidTransition(job.id, job.phase, .queued)
            }
            job.phase = .queued
            job.failureStage = nil
            job.statusMessage = message
        }
        notifyChanged()
        return updated
    }

    public func markFinalizing(id: UUID, message: String? = nil) throws -> RecordingJob {
        let updated = try mutate(id: id) { job in
            guard job.phase == .processing else {
                throw RecordingJobStoreError.invalidTransition(job.id, job.phase, .finalizing)
            }
            job.phase = .finalizing
            job.statusMessage = message ?? "Saving transcript"
        }
        notifyChanged()
        return updated
    }

    public func markFailed(
        id: UUID,
        stage: RecordingJobFailureStage,
        message: String
    ) throws -> RecordingJob {
        let updated = try mutate(id: id) { job in
            guard job.phase == .processing || job.phase == .finalizing || job.phase == .queued else {
                throw RecordingJobStoreError.invalidTransition(job.id, job.phase, .failed)
            }
            job.phase = .failed
            job.failureStage = stage
            job.statusMessage = message
            job.audioDeletionDate = nil
        }
        notifyChanged()
        return updated
    }

    public func markCompleted(
        id: UUID,
        transcriptText: String? = nil,
        completedAt: Date = Date()
    ) throws -> RecordingJob {
        var completed = try mutate(id: id) { job in
            guard job.phase == .processing || job.phase == .finalizing else {
                throw RecordingJobStoreError.invalidTransition(job.id, job.phase, .completed)
            }
            job.phase = .completed
            job.failureStage = nil
            job.statusMessage = "Completed"
            job.transcriptText = transcriptText
            job.completedAt = completedAt
            if transcriptText != nil {
                // Deferred clipboard delivery is not terminal until the user
                // explicitly copies it from the queue.
                job.audioDeletionDate = nil
                return
            }
            switch job.retentionPolicy.mode {
            case .deleteAfterSuccess:
                job.audioDeletionDate = completedAt
            case .timed:
                job.audioDeletionDate = completedAt.addingTimeInterval(
                    job.retentionPolicy.retentionInterval
                        ?? SourceAudioRetentionPolicy.defaultTimedRetention
                )
            case .permanent:
                job.audioDeletionDate = nil
            }
        }
        do {
            completed = try cleanupAudioIfDue(for: completed, now: completedAt)
            notifyChanged()
            return completed
        } catch {
            // Delivery is already durable, so a source-cleanup problem must not
            // turn the job back into a retry that repeats transcription/export.
            // Keep the due date so a later retention pass can try again.
            completed = (try? mutate(id: id) { job in
                job.phase = .completed
                job.failureStage = nil
                job.statusMessage = "Completed; source-audio cleanup is pending: \(error.localizedDescription)"
            }) ?? completed
            notifyChanged()
            return completed
        }
    }

    public func retry(
        id: UUID,
        modelID: String? = nil,
        fallbackModelID: String? = nil,
        replaceFallbackModelID: Bool = false,
        language: String? = nil,
        delivery: RecordingJobDelivery? = nil
    ) throws -> RecordingJob {
        let updated = try mutate(id: id) { job in
            guard job.phase == .failed else {
                throw RecordingJobStoreError.invalidTransition(job.id, job.phase, .queued)
            }
            try ensureAudioExists(for: job)
            if let modelID { job.modelID = modelID }
            if replaceFallbackModelID {
                job.fallbackModelID = fallbackModelID
            } else if let fallbackModelID {
                job.fallbackModelID = fallbackModelID
            }
            if let language { job.language = language }
            if let delivery { job.delivery = delivery }
            job.phase = .queued
            job.failureStage = nil
            job.statusMessage = queuedMessage(for: job.processingPolicy)
        }
        notifyChanged()
        return updated
    }

    public func processNow(id: UUID) throws -> RecordingJob {
        let updated = try mutate(id: id) { job in
            guard job.phase == .queued || job.phase == .failed else {
                throw RecordingJobStoreError.invalidTransition(job.id, job.phase, .queued)
            }
            try ensureAudioExists(for: job)
            job.processingPolicy = .immediate
            job.phase = .queued
            job.failureStage = nil
            job.statusMessage = "Queued to process now"
        }
        notifyChanged()
        return updated
    }

    public func recordTranscriptCheckpoint(id: UUID, text: String) throws -> RecordingJob {
        let updated = try mutate(id: id) { job in
            guard job.phase == .processing || job.phase == .finalizing else {
                throw RecordingJobStoreError.jobIsActive(job.id)
            }
            job.transcriptText = text
        }
        notifyChanged()
        return updated
    }

    public func markExportedAudio(id: UUID, path: String) throws -> RecordingJob {
        let updated = try mutate(id: id) { job in
            guard job.phase == .processing || job.phase == .finalizing else {
                throw RecordingJobStoreError.jobIsActive(job.id)
            }
            if job.exportedAudioPath != path {
                // A repaired attachment URL invalidates any reference checkpoint
                // tied to the prior path. If reference publication then fails,
                // the next retry must attempt it again rather than trusting stale
                // completion state.
                job.audioReferenceAttachedAt = nil
            }
            job.exportedAudioPath = path
        }
        try? fileManager.removeItem(
            at: externalDeliveryTransactionDirectoryURL(for: id, artifact: .audio)
        )
        notifyChanged()
        return updated
    }

    public func markExportedNote(id: UUID, path: String) throws -> RecordingJob {
        let updated = try mutate(id: id) { job in
            guard job.phase == .processing || job.phase == .finalizing else {
                throw RecordingJobStoreError.jobIsActive(job.id)
            }
            job.exportedNotePath = path
        }
        try? fileManager.removeItem(
            at: externalDeliveryTransactionDirectoryURL(for: id, artifact: .note)
        )
        notifyChanged()
        return updated
    }

    public func markAudioReferenceAttached(
        id: UUID,
        attachedAt: Date = Date()
    ) throws -> RecordingJob {
        let updated = try mutate(id: id) { job in
            guard job.phase == .processing || job.phase == .finalizing else {
                throw RecordingJobStoreError.jobIsActive(job.id)
            }
            job.audioReferenceAttachedAt = job.audioReferenceAttachedAt ?? attachedAt
        }
        try? fileManager.removeItem(
            at: externalDeliveryTransactionDirectoryURL(
                for: id,
                artifact: .noteAudioReference
            )
        )
        notifyChanged()
        return updated
    }

    public func markAutomaticClipboardDeliveryAttempted(id: UUID) throws -> RecordingJob {
        let updated = try mutate(id: id) { job in
            guard job.phase == .processing || job.phase == .finalizing else {
                throw RecordingJobStoreError.jobIsActive(job.id)
            }
            if job.automaticClipboardDeliveryAttemptedAt == nil {
                job.automaticClipboardDeliveryAttemptedAt = Date()
            }
        }
        notifyChanged()
        return updated
    }

    public func clearCompletedTranscriptText(id: UUID, copiedAt: Date = Date()) throws -> RecordingJob {
        var updated = try mutate(id: id) { job in
            guard job.phase == .completed || job.phase == .failed,
                  job.transcriptText != nil else {
                throw RecordingJobStoreError.invalidTransition(job.id, job.phase, .completed)
            }
            job.phase = .completed
            job.failureStage = nil
            job.statusMessage = "Completed"
            job.completedAt = job.completedAt ?? copiedAt
            job.transcriptText = nil
            switch job.retentionPolicy.mode {
            case .deleteAfterSuccess:
                job.audioDeletionDate = copiedAt
            case .timed:
                job.audioDeletionDate = (job.completedAt ?? copiedAt).addingTimeInterval(
                    job.retentionPolicy.retentionInterval
                        ?? SourceAudioRetentionPolicy.defaultTimedRetention
                )
            case .permanent:
                job.audioDeletionDate = nil
            }
        }
        updated = try cleanupAudioIfDue(for: updated, now: copiedAt)
        notifyChanged()
        return updated
    }

    public func updateRetention(
        id: UUID,
        policy: SourceAudioRetentionPolicy,
        now: Date = Date()
    ) throws -> RecordingJob {
        var updated = try mutate(id: id) { job in
            job.retentionPolicy = policy
            guard let completedAt = job.completedAt else { return }
            if job.transcriptText != nil {
                // A deferred clipboard result is not delivered until Copy.
                // Retention overrides may change the eventual policy but cannot
                // bypass that delivery gate.
                job.audioDeletionDate = nil
                return
            }
            switch policy.mode {
            case .deleteAfterSuccess:
                job.audioDeletionDate = now
            case .timed:
                job.audioDeletionDate = completedAt.addingTimeInterval(
                    policy.retentionInterval ?? SourceAudioRetentionPolicy.defaultTimedRetention
                )
            case .permanent:
                job.audioDeletionDate = nil
            }
        }
        updated = try cleanupAudioIfDue(for: updated, now: now)
        notifyChanged()
        return updated
    }

    @discardableResult
    public func performRetentionCleanup(now: Date = Date()) throws -> [UUID] {
        var cleaned: [UUID] = []
        let jobs = try load(recoverInterrupted: false)
        for job in jobs where job.phase == .completed {
            let updated = try cleanupAudioIfDue(for: job, now: now)
            if job.audioDeletedAt == nil, updated.audioDeletedAt != nil {
                cleaned.append(job.id)
            }
        }
        if !cleaned.isEmpty { notifyChanged() }
        return cleaned
    }

    public func discard(id: UUID) throws -> RecordingJob {
        var discarded = try mutate(id: id) { job in
            guard job.phase != .processing && job.phase != .finalizing else {
                throw RecordingJobStoreError.jobIsActive(job.id)
            }
            job.phase = .discarded
            job.failureStage = nil
            job.statusMessage = "Discarded"
            job.audioDeletionDate = Date()
        }
        let urls = artifactURLs(for: discarded)
        do {
            for url in urls where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            discarded = try mutate(id: id) { job in
                job.audioDeletedAt = Date()
            }
            for artifact in [
                RecordingJobExternalDeliveryArtifact.note,
                .audio,
                .noteAudioReference,
            ] {
                try? fileManager.removeItem(
                    at: externalDeliveryTransactionDirectoryURL(for: id, artifact: artifact)
                )
            }
            notifyChanged()
            return discarded
        } catch {
            _ = try? mutate(id: id) { job in
                job.phase = .failed
                job.failureStage = .storage
                job.statusMessage = "The recording could not be deleted: \(error.localizedDescription)"
                job.audioDeletionDate = nil
            }
            notifyChanged()
            throw error
        }
    }

    private func acquireWorkerLockIfAvailable() throws -> Bool {
        if workerLockFileDescriptor != nil { return true }
        try ensureDirectories()
        let lockURL = rootDirectoryURL.appendingPathComponent("worker.lock", isDirectory: false)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            Darwin.close(descriptor)
            if lockError == EWOULDBLOCK { return false }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(lockError))
        }
        workerLockFileDescriptor = descriptor
        return true
    }

    private func releaseWorkerLock() {
        guard let descriptor = workerLockFileDescriptor else { return }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        workerLockFileDescriptor = nil
    }

    private func mutate(
        id: UUID,
        _ mutation: (inout RecordingJob) throws -> Void
    ) throws -> RecordingJob {
        try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            guard var job = try loadItem(id: id) else {
                throw RecordingJobStoreError.jobNotFound(id)
            }
            try mutation(&job)
            touch(&job)
            try persist(job)
            return job
        }
    }

    private func cleanupAudioIfDue(for job: RecordingJob, now: Date) throws -> RecordingJob {
        try coordinator.coordinateWriting(at: rootDirectoryURL) { _ in
            try ensureDirectories()
            guard var latest = try loadItem(id: job.id) else {
                throw RecordingJobStoreError.jobNotFound(job.id)
            }
            // Revalidate under the same cross-process coordination that covers
            // deletion. A simultaneous “Keep permanently” change must win
            // before an older cleanup snapshot can remove the source.
            guard latest.phase == .completed,
                  latest.audioDeletedAt == nil,
                  let deletionDate = latest.audioDeletionDate,
                  deletionDate <= now else { return latest }
            for url in artifactURLs(for: latest) where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            latest.audioDeletedAt = now
            touch(&latest)
            try persist(latest)
            return latest
        }
    }

    private func loadItems() throws -> [RecordingJob] {
        let urls = try fileManager.contentsOfDirectory(
            at: itemsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        var jobs: [RecordingJob] = []
        for url in urls {
            let data = try Data(contentsOf: url)
            do {
                let job = try decoder.decode(RecordingJob.self, from: data)
                guard job.schemaVersion <= RecordingJob.currentSchemaVersion else {
                    throw RecordingJobStoreError.unsupportedSchemaVersion(job.schemaVersion)
                }
                guard job.audioFilename == URL(fileURLWithPath: job.audioFilename).lastPathComponent,
                      !job.audioFilename.isEmpty,
                      job.resolvedArtifacts.allSatisfy({ artifact in
                          !artifact.filename.isEmpty && artifact.filename == URL(fileURLWithPath: artifact.filename).lastPathComponent
                      }) else { continue }
                jobs.append(job)
            } catch let DecodingError.dataCorrupted(context)
                where context.debugDescription.hasPrefix("Unsupported recording job schema version ") {
                let version = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["schemaVersion"] as? Int
                    ?? RecordingJob.currentSchemaVersion + 1
                throw RecordingJobStoreError.unsupportedSchemaVersion(version)
            } catch let error as RecordingJobStoreError {
                throw error
            } catch {
                // Preserve malformed or malicious manifests for manual diagnosis,
                // but do not let them hide compatible jobs in the queue.
                continue
            }
        }
        return jobs.sorted(by: Self.sortJobs)
    }

    private func loadItem(id: UUID) throws -> RecordingJob? {
        let url = itemURL(id: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let job = try decoder.decode(RecordingJob.self, from: Data(contentsOf: url))
        guard job.schemaVersion <= RecordingJob.currentSchemaVersion,
              job.audioFilename == URL(fileURLWithPath: job.audioFilename).lastPathComponent,
              !job.audioFilename.isEmpty,
              job.resolvedArtifacts.allSatisfy({ !$0.filename.isEmpty && $0.filename == URL(fileURLWithPath: $0.filename).lastPathComponent }) else {
            return nil
        }
        return job
    }

    private func persist(_ job: RecordingJob) throws {
        try encoder.encode(job).write(to: itemURL(id: job.id), options: .atomic)
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: itemsDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: audioDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bundleIntentsDirectoryURL, withIntermediateDirectories: true)
    }

    /// Completes bundle transactions before generic queue-orphan recovery can
    /// reinterpret individual meeting members as unrelated schema-v1 jobs.
    /// Failed but valid intents continue to claim their destination filenames.
    private func recoverPendingBundleEnqueues() -> Set<String> {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: bundleIntentsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter({ $0.pathExtension == "json" }) else { return [] }
        var claimed: Set<String> = []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let intent = try? decoder.decode(RecordingBundleEnqueueIntent.self, from: data),
                  isValidBundleIntent(intent, at: url) else { continue }
            claimed.formUnion(intent.sources.map(\.filename))
            do {
                try materializeBundle(intent)
                if try loadItem(id: intent.job.id) == nil { try persist(intent.job) }
                finishBundleCommit(intent, intentURL: url)
            } catch {
                for source in intent.sources {
                    try? fileManager.removeItem(at: bundleTemporaryURL(filename: source.filename))
                }
                // Preserve both the journal and its claimed final artifacts for
                // a later retry; never downgrade them to generic v1 recovery.
            }
        }
        return claimed
    }

    private func materializeBundle(_ intent: RecordingBundleEnqueueIntent) throws {
        for source in intent.sources {
            let destination = audioDirectoryURL.appendingPathComponent(source.filename)
            if fileManager.fileExists(atPath: destination.path) {
                guard isRegularNonSymlinkFile(destination),
                      try fileSize(at: destination) == source.expectedByteCount else {
                    throw RecordingJobStoreError.copyVerificationFailed
                }
                continue
            }
            let sourceURL = URL(fileURLWithPath: source.sourcePath)
            guard isRegularNonSymlinkFile(sourceURL) else {
                throw RecordingJobStoreError.sourceMissing
            }
            let temporary = bundleTemporaryURL(filename: source.filename)
            try? fileManager.removeItem(at: temporary)
            try fileManager.copyItem(at: sourceURL, to: temporary)
            guard try fileSize(at: temporary) == source.expectedByteCount else {
                throw RecordingJobStoreError.copyVerificationFailed
            }
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private func finishBundleCommit(_ intent: RecordingBundleEnqueueIntent, intentURL: URL) {
        if intent.removeSourcesAfterCommit {
            for source in intent.sources {
                let sourceURL = URL(fileURLWithPath: source.sourcePath)
                let destination = audioDirectoryURL.appendingPathComponent(source.filename)
                if sourceURL.standardizedFileURL != destination.standardizedFileURL {
                    suppressAndRemoveExternalArtifact(sourceURL)
                }
            }
        }
        try? fileManager.removeItem(at: intentURL)
    }

    private func isValidBundleIntent(_ intent: RecordingBundleEnqueueIntent, at url: URL) -> Bool {
        guard intent.schemaVersion == RecordingBundleEnqueueIntent.currentSchemaVersion,
              intent.job.schemaVersion == RecordingJob.currentSchemaVersion,
              url.lastPathComponent == "\(intent.job.id.uuidString.lowercased()).json",
              intent.sources.count == intent.job.resolvedArtifacts.count,
              !intent.sources.isEmpty,
              Set(intent.sources.map(\.role)).count == intent.sources.count,
              Set(intent.sources.map(\.filename)).count == intent.sources.count,
              intent.sources.allSatisfy({ source in
                  source.expectedByteCount > 0
                      && !source.filename.isEmpty
                      && source.filename == URL(fileURLWithPath: source.filename).lastPathComponent
                      && intent.job.resolvedArtifacts.contains(where: {
                          $0.role == source.role
                              && $0.filename == source.filename
                              && $0.originalFilename == source.originalFilename
                      })
              }) else { return false }
        return intent.job.resolvedArtifacts.contains(where: { $0.filename == intent.job.audioFilename })
    }

    private func bundleIntentURL(id: UUID) -> URL {
        bundleIntentsDirectoryURL.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    private func bundleTemporaryURL(filename: String) -> URL {
        audioDirectoryURL.appendingPathComponent(".\(filename).partial")
    }

    private func ensureAudioExists(for job: RecordingJob) throws {
        guard artifactURLs(for: job).allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
            throw RecordingJobStoreError.audioMissing(job.id)
        }
    }

    public nonisolated func artifactURLs(for job: RecordingJob) -> [URL] {
        job.resolvedArtifacts.map { artifact in
            rootDirectoryURL.appendingPathComponent("audio", isDirectory: true)
                .appendingPathComponent(URL(fileURLWithPath: artifact.filename).lastPathComponent)
        }
    }

    private func itemURL(id: UUID) -> URL {
        itemsDirectoryURL.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private func isRegularNonSymlinkFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func sanitizedExtension(_ ext: String) -> String {
        String(ext.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(12))
    }

    private func queuedMessage(for policy: RecordingJobProcessingPolicy) -> String {
        switch policy {
        case .immediate:
            return "Queued to process now"
        case .whenIdle:
            return "Queued until Vox.md is idle"
        case .manual:
            return "Waiting for you to start processing"
        }
    }

    private func touch(_ job: inout RecordingJob) {
        job.updatedAt = now()
        job.revision += 1
    }

    private nonisolated static func sortJobs(_ lhs: RecordingJob, _ rhs: RecordingJob) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.createdAt < rhs.createdAt
    }

    private nonisolated func notifyChanged() {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: rootDirectoryURL.standardizedFileURL
        )
    }
}
