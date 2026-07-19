import Foundation

/// Stable identifiers shared by the app, keyboard extension, and IPC payloads.
public enum TranscriptionBackendID {
    /// Lets the host app prefer Apple's native speech recognizer and use an
    /// explicitly-downloaded local model only as a fallback.
    public static let automatic = "automatic"

    /// The system backend that uses SpeechAnalyzer/SpeechTranscriber on iOS 26+.
    public static let appleSpeech = "apple-speech"
}

/// Coarse readiness for a system-managed speech recognizer.
public enum SystemTranscriptionAvailability: String, Equatable, Sendable {
    case unavailable
    case supported
    case ready
}

/// Text and locale returned by a system-managed transcription backend.
public struct SystemTranscriptionOutput: Equatable, Sendable {
    public let text: String
    public let language: String

    public init(text: String, language: String) {
        self.text = text
        self.language = language
    }
}

/// A cumulative update from a live system transcription session.
///
/// `finalizedText` only grows and is safe to insert into a host text field.
/// `volatileText` is a replaceable, tentative tail intended for display only.
public struct SystemTranscriptionUpdate: Equatable, Sendable {
    public let revision: Int
    public let finalizedText: String
    public let volatileText: String?

    public init(revision: Int, finalizedText: String, volatileText: String? = nil) {
        self.revision = revision
        self.finalizedText = finalizedText
        self.volatileText = volatileText
    }
}

/// Owned mono Float32 PCM passed to a live system transcription session.
/// Keeping AVFoundation out of this type prevents Speech.framework from being
/// linked into the keyboard, widgets, Watch, or shared package clients.
public struct SystemTranscriptionAudioChunk: Sendable {
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

public protocol SystemLiveTranscriptionSession: Sendable {
    func append(_ chunk: SystemTranscriptionAudioChunk) async throws
    func finish() async throws -> SystemTranscriptionOutput
    func cancel() async
}

/// Implemented by the main app's iOS 26 Speech framework adapter. Keeping this
/// protocol in the shared package lets the package route transcription without
/// linking Speech.framework into the keyboard, widgets, Watch, or macOS app.
public protocol SystemTranscriptionBackend: Sendable {
    func availability(language: String) async -> SystemTranscriptionAvailability
    func prepare(language: String) async throws
    func transcribe(audioURL: URL, language: String) async throws -> SystemTranscriptionOutput
    func startLiveTranscription(
        language: String,
        onUpdate: @escaping @concurrent @Sendable (SystemTranscriptionUpdate) async -> Void
    ) async throws -> any SystemLiveTranscriptionSession
}

public enum TranscriptionBackendKind: String, Equatable, Sendable {
    case appleSpeech
    case whisper
    case parakeet
}

/// A transcription plus the backend that actually produced it. Automatic mode
/// may resolve to Apple Speech or to a downloaded local fallback.
public struct OnDeviceTranscriptionResult: Equatable, Sendable {
    public let text: String
    public let backendID: String
    public let backendName: String
    public let backendKind: TranscriptionBackendKind
    public let language: String

    public init(
        text: String,
        backendID: String,
        backendName: String,
        backendKind: TranscriptionBackendKind,
        language: String
    ) {
        self.text = text
        self.backendID = backendID
        self.backendName = backendName
        self.backendKind = backendKind
        self.language = language
    }
}
