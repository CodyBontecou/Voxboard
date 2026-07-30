#if os(iOS) || os(macOS)
import CoreML
import Foundation
import FluidAudio

/// Metadata and filesystem checks for the small Silero model used to detect
/// speech boundaries during live voice capture.
public enum VoiceActivityModelAsset: Sendable {
    public static let id = "silero-vad"
    public static let displayName = "Voice Pause Detection"
    public static let repositoryFolderName = "silero-vad"
    public static let compiledModelDirectoryName = "silero-vad-unified-256ms-v6.0.0.mlmodelc"
    public static let chunkSize = 4_096
    public static let sampleRate = 16_000.0
    public static let frameDuration = TimeInterval(chunkSize) / sampleRate

    /// FluidAudio starts its silence timer at the end of the first quiet frame.
    /// Subtract one frame so the user-facing pause approximates wall-clock silence.
    public static func stateMachineSilenceDuration(
        forRequestedPause requestedPause: TimeInterval
    ) -> TimeInterval {
        max(0, requestedPause - frameDuration)
    }

    private static let requiredRelativePaths = [
        "coremldata.bin",
        "model.mil",
        "weights/weight.bin",
    ]

    public static func repositoryURL(in modelsDirectory: URL) -> URL {
        modelsDirectory.appendingPathComponent(repositoryFolderName, isDirectory: true)
    }

    public static func modelURL(in modelsDirectory: URL) -> URL {
        repositoryURL(in: modelsDirectory)
            .appendingPathComponent(compiledModelDirectoryName, isDirectory: true)
    }

    public static func isInstalled(in modelsDirectory: URL) -> Bool {
        let modelDirectory = modelURL(in: modelsDirectory)
        return requiredRelativePaths.allSatisfy { relativePath in
            FileManager.default.fileExists(
                atPath: modelDirectory.appendingPathComponent(relativePath).path
            )
        }
    }

    public static var isInstalled: Bool {
        guard let modelsDirectory = AppConstants.modelsDirectoryURL else { return false }
        return isInstalled(in: modelsDirectory)
    }
}

public enum VoiceActivityStreamEvent: Equatable, Sendable {
    case speechStarted(sampleIndex: Int)
    case speechEnded(sampleIndex: Int)
}

/// Testable boundary around FluidAudio's stateful streaming VAD session.
public protocol VoiceActivityStreamingSession: Actor {
    func process(_ samples: [Float]) async throws -> VoiceActivityStreamEvent?
}

public enum VoiceActivityDetectionError: Error, LocalizedError, Sendable {
    case modelUnavailable
    case invalidChunkSize(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "Voice pause detection has not been downloaded."
        case .invalidChunkSize(let expected, let actual):
            return "Voice pause detection expected \(expected) samples but received \(actual)."
        }
    }
}

/// Loads the explicitly downloaded Silero model without allowing FluidAudio to
/// perform an implicit network request, then creates independent stream state
/// for each live recording segment.
public actor VoiceActivityDetectionService {
    private var manager: VadManager?

    public init() {}

    public func makeStreamingSession(
        minimumSilenceDuration: TimeInterval
    ) async throws -> any VoiceActivityStreamingSession {
        guard let modelsDirectory = AppConstants.modelsDirectoryURL,
              VoiceActivityModelAsset.isInstalled(in: modelsDirectory) else {
            throw VoiceActivityDetectionError.modelUnavailable
        }

        let loadedManager: VadManager
        if let manager {
            loadedManager = manager
        } else {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(
                contentsOf: VoiceActivityModelAsset.modelURL(in: modelsDirectory),
                configuration: configuration
            )
            let newManager = VadManager(
                config: VadConfig(computeUnits: .cpuAndNeuralEngine),
                vadModel: model
            )
            manager = newManager
            loadedManager = newManager
        }

        return FluidAudioVoiceActivitySession(
            manager: loadedManager,
            minimumSilenceDuration: VoiceActivityModelAsset.stateMachineSilenceDuration(
                forRequestedPause: minimumSilenceDuration
            )
        )
    }
}

private actor FluidAudioVoiceActivitySession: VoiceActivityStreamingSession {
    private let manager: VadManager
    private let segmentationConfig: VadSegmentationConfig
    private var state = VadStreamState.initial()

    init(manager: VadManager, minimumSilenceDuration: TimeInterval) {
        self.manager = manager
        self.segmentationConfig = VadSegmentationConfig(
            minSilenceDuration: minimumSilenceDuration,
            // Event sample indices drive our minimum-speech gate. Padding would
            // make a single 256 ms noise frame appear longer than 0.3 seconds.
            speechPadding: 0
        )
    }

    func process(_ samples: [Float]) async throws -> VoiceActivityStreamEvent? {
        guard samples.count == VoiceActivityModelAsset.chunkSize else {
            throw VoiceActivityDetectionError.invalidChunkSize(
                expected: VoiceActivityModelAsset.chunkSize,
                actual: samples.count
            )
        }

        let result = try await manager.processStreamingChunk(
            samples,
            state: state,
            config: segmentationConfig
        )
        state = result.state

        switch result.event?.kind {
        case .speechStart:
            guard let event = result.event else { return nil }
            return .speechStarted(sampleIndex: event.sampleIndex)
        case .speechEnd:
            guard let event = result.event else { return nil }
            return .speechEnded(sampleIndex: event.sampleIndex)
        case nil:
            return nil
        }
    }
}

/// Resolves each live recording command to its independently configurable
/// capture path. Transcription backend selection does not affect eligibility.
public enum VoiceAutoStopPolicy: Sendable {
    public static func capturePath(
        for command: RecordingCommand
    ) -> VoiceAutoStopCapturePath? {
        guard command.action == .startSegment else { return nil }

        switch command.origin {
        case .keyboardExtension:
            return .keyboard
        case .inAppDraft:
            return .inAppDraft
        case .inAppImmediate:
            return .inAppImmediate
        case .quickRecord:
            return .quickRecord
        case .liveActivity:
            return .liveActivity
        case .watch:
            return .watch
        case nil:
            return nil
        }
    }
}
#endif
