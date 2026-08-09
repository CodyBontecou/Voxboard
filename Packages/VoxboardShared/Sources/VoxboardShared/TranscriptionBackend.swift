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

/// A piece of recognized text aligned to the source audio timeline.
///
/// Backends may provide word-level or phrase-level units. Speaker diarization
/// uses the same overlap-based attribution for either granularity.
public struct TimedTranscriptionSegment: Codable, Equatable, Sendable {
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// Text, locale, and optional timestamped units returned by a system-managed
/// transcription backend.
public struct SystemTranscriptionOutput: Equatable, Sendable {
    public let text: String
    public let language: String
    public let segments: [TimedTranscriptionSegment]

    public init(
        text: String,
        language: String,
        segments: [TimedTranscriptionSegment] = []
    ) {
        self.text = text
        self.language = language
        self.segments = segments
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

/// Progress reported by an on-device transcription backend.
///
/// ``preparing`` means the app can confirm that work is active but cannot
/// truthfully calculate a completion percentage. ``exactAudioCoverage`` is
/// emitted only when the backend reports how much source audio it has processed;
/// it does not include model preparation, speaker diarization, enrichment,
/// delivery, or export work.
public struct TranscriptionProgress: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case preparing
        case exactAudioCoverage
    }

    public let kind: Kind
    private let fractionCompleted: Double?

    public static let preparing = TranscriptionProgress(
        kind: .preparing,
        fractionCompleted: nil
    )

    /// Creates truthful source-audio coverage progress. Non-finite values cannot
    /// represent a percentage and are downgraded to ``preparing``.
    public static func exactAudioCoverage(_ fractionCompleted: Double) -> TranscriptionProgress {
        guard fractionCompleted.isFinite else { return .preparing }
        return TranscriptionProgress(
            kind: .exactAudioCoverage,
            fractionCompleted: min(1, max(0, fractionCompleted))
        )
    }

    /// Exact completion in the closed range `0...1`, or `nil` while the backend
    /// only exposes an indeterminate active state.
    public var exactFractionCompleted: Double? {
        kind == .exactAudioCoverage ? fractionCompleted : nil
    }

    /// Whole completed percent for compact UI and throttled cross-process state.
    public var wholePercentCompleted: Int? {
        exactFractionCompleted.map { Int(($0 * 100).rounded(.down)) }
    }

    /// Locale-aware display text using the same floor semantics as
    /// ``wholePercentCompleted``. This never rounds 99.x% up to 100%.
    public var formattedWholePercentCompleted: String? {
        guard let wholePercentCompleted else { return nil }
        return (Double(wholePercentCompleted) / 100).formatted(
            .percent.precision(.fractionLength(0))
        )
    }

    private init(kind: Kind, fractionCompleted: Double?) {
        self.kind = kind
        self.fractionCompleted = fractionCompleted
    }
}

/// May be invoked from a backend-owned executor. UI clients must hop to their
/// owning actor before mutating observable state.
public typealias TranscriptionProgressHandler = @Sendable (TranscriptionProgress) -> Void

/// Mirrors FluidAudio 0.13.4's strict `> 240_000` sample progress branch.
/// Parakeet input has already been normalized to 16 kHz, so exactly 15 seconds
/// remains indeterminate and an unknown duration must not create a cached stream.
struct ParakeetProgressObservationPolicy: Sendable {
    static let minimumAudioDuration: TimeInterval = 15

    static func shouldObserve(audioDuration: TimeInterval?) -> Bool {
        guard let audioDuration,
              audioDuration.isFinite else { return false }
        return audioDuration > minimumAudioDuration
    }
}

/// Filters backend stream values into strictly advancing, finite source
/// coverage. Exact completion is reserved for result validation by the service.
struct MonotonicAudioCoverageProgressRelay: Sendable {
    private var lastFraction = -Double.infinity

    mutating func accept(_ fraction: Double) -> TranscriptionProgress? {
        guard fraction.isFinite,
              fraction >= 0,
              fraction < 1,
              fraction > lastFraction else { return nil }
        lastFraction = fraction
        return .exactAudioCoverage(fraction)
    }
}

/// A transcription plus the backend that actually produced it. Automatic mode
/// may resolve to Apple Speech or to a downloaded local fallback.
public struct OnDeviceTranscriptionResult: Equatable, Sendable {
    public let text: String
    public let backendID: String
    public let backendName: String
    public let backendKind: TranscriptionBackendKind
    public let language: String
    public let segments: [TimedTranscriptionSegment]

    public init(
        text: String,
        backendID: String,
        backendName: String,
        backendKind: TranscriptionBackendKind,
        language: String,
        segments: [TimedTranscriptionSegment] = []
    ) {
        self.text = text
        self.backendID = backendID
        self.backendName = backendName
        self.backendKind = backendKind
        self.language = language
        self.segments = segments
    }
}
