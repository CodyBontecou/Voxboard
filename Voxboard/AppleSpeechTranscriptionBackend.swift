@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech
import VoxboardShared

private struct AppleSpeechBatchOutput: Sendable {
    var text = AttributedString()
    var segments: [TimedTranscriptionSegment] = []
}

@available(iOS 26.0, *)
actor AppleSpeechTranscriptionBackend: SystemTranscriptionBackend {
    func availability(language: String) async -> SystemTranscriptionAvailability {
        guard SpeechTranscriber.isAvailable,
              let locale = await supportedLocale(for: language) else {
            return .unavailable
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return .ready
        case .supported, .downloading:
            return .supported
        case .unsupported:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    func prepare(language: String) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechSetupError.transcriberUnavailable
        }
        guard let locale = await supportedLocale(for: language) else {
            throw AppleSpeechSetupError.localeUnsupported(language)
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await ensureAssets(for: transcriber, locale: locale)
    }

    func transcribe(audioURL: URL, language: String) async throws -> SystemTranscriptionOutput {
        try Task.checkCancellation()
        try await ensureSpeechAuthorization()
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechSetupError.transcriberUnavailable
        }
        guard let locale = await supportedLocale(for: language) else {
            throw AppleSpeechSetupError.localeUnsupported(language)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        try await ensureAssets(for: transcriber, locale: locale)

        let audioFile = try AVAudioFile(forReading: audioURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        async let collectedOutput: AppleSpeechBatchOutput = transcriber.results.reduce(
            into: AppleSpeechBatchOutput()
        ) { output, result in
            if result.isFinal {
                output.text += result.text
                output.segments.append(contentsOf: Self.timedSegments(from: result))
            }
        }

        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }

            let output = try await collectedOutput
            let text = String(output.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw OnDeviceTranscriptionError.noSpeechDetected
            }
            return SystemTranscriptionOutput(
                text: text,
                language: localeIdentifier(locale),
                segments: output.segments
            )
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    func startLiveTranscription(
        language: String,
        onUpdate: @escaping @concurrent @Sendable (SystemTranscriptionUpdate) async -> Void
    ) async throws -> any SystemLiveTranscriptionSession {
        try Task.checkCancellation()
        try await ensureSpeechAuthorization()
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechSetupError.transcriberUnavailable
        }
        guard let locale = await supportedLocale(for: language) else {
            throw AppleSpeechSetupError.localeUnsupported(language)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        try await ensureAssets(for: transcriber, locale: locale)

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw AppleSpeechSetupError.audioFormatUnavailable
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let stream = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingOldest(32)
        )
        let session = AppleSpeechLiveTranscriptionSession(
            analyzer: analyzer,
            transcriber: transcriber,
            analyzerFormat: analyzerFormat,
            localeIdentifier: localeIdentifier(locale),
            inputContinuation: stream.continuation,
            onUpdate: onUpdate
        )

        do {
            try await session.start(inputSequence: stream.stream)
            return session
        } catch {
            await session.cancel()
            throw error
        }
    }

    private nonisolated static func timedSegments(
        from result: SpeechTranscriber.Result
    ) -> [TimedTranscriptionSegment] {
        let attributedText = result.text
        var attributedSegments: [TimedTranscriptionSegment] = []
        var hasUntimedText = false

        for run in attributedText.runs {
            let text = String(attributedText[run.range].characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard let timeRange = run.audioTimeRange else {
                hasUntimedText = true
                continue
            }
            let start = CMTimeGetSeconds(timeRange.start)
            let duration = CMTimeGetSeconds(timeRange.duration)
            let end = start + duration
            guard start.isFinite, end.isFinite, end > max(0, start) else {
                hasUntimedText = true
                continue
            }
            attributedSegments.append(TimedTranscriptionSegment(
                text: text,
                startTime: max(0, start),
                endTime: end
            ))
        }
        if !attributedSegments.isEmpty, !hasUntimedText {
            return attributedSegments
        }

        // A partially attributed result must never drop untimed words. Fall
        // back to the coarser result range so the full recognition stays intact.
        let text = String(attributedText.characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let start = CMTimeGetSeconds(result.range.start)
        let duration = CMTimeGetSeconds(result.range.duration)
        let end = start + duration
        guard !text.isEmpty, start.isFinite, end.isFinite, end > max(0, start) else { return [] }
        return [TimedTranscriptionSegment(
            text: text,
            startTime: max(0, start),
            endTime: end
        )]
    }

    private func ensureAssets(
        for transcriber: SpeechTranscriber,
        locale: Locale
    ) async throws {
        // Speech assets are shared by the system, but each app still needs its own
        // locale reservation. In particular, an already-installed asset can report
        // `.installed` even though this app has not subscribed to its locale yet.
        // Starting an analyzer in that state fails with an "unallocated locale" or
        // "not subscribed" SFSpeechError.
        try await reserve(locale: locale)

        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return
        case .unsupported:
            throw AppleSpeechSetupError.assetUnsupported(localeIdentifier(locale))
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        @unknown default:
            throw AppleSpeechSetupError.assetStateUnexpected(localeIdentifier(locale))
        }

        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw AppleSpeechAssetPreparationError.installationPending(
                localeIdentifier(locale)
            )
        }
    }

    private func reserve(locale: Locale) async throws {
        let requestedIdentifier = localeIdentifier(locale)
        var reservedLocales = await AssetInventory.reservedLocales
        guard !reservedLocales.contains(where: {
            localeIdentifier($0) == requestedIdentifier
        }) else {
            return
        }

        // Vox.md uses one selected transcription language at a time. If earlier
        // selections consumed every app reservation, release one stale locale so
        // the newly selected language can be prepared.
        if reservedLocales.count >= AssetInventory.maximumReservedLocales,
           let staleLocale = reservedLocales.first(where: {
               localeIdentifier($0) != requestedIdentifier
           }) {
            _ = await AssetInventory.release(reservedLocale: staleLocale)
            reservedLocales = await AssetInventory.reservedLocales
        }

        guard !reservedLocales.contains(where: {
            localeIdentifier($0) == requestedIdentifier
        }) else {
            return
        }
        try await AssetInventory.reserve(locale: locale)
    }

    private func ensureSpeechAuthorization() async throws {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        let status: SFSpeechRecognizerAuthorizationStatus
        if currentStatus == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { resolvedStatus in
                    continuation.resume(returning: resolvedStatus)
                }
            }
        } else {
            status = currentStatus
        }

        switch status {
        case .authorized:
            return
        case .denied:
            throw AppleSpeechSetupError.permissionDenied
        case .restricted:
            throw AppleSpeechSetupError.permissionRestricted
        case .notDetermined:
            throw AppleSpeechSetupError.permissionDenied
        @unknown default:
            throw AppleSpeechSetupError.permissionDenied
        }
    }

    private func supportedLocale(for language: String) async -> Locale? {
        let requested: Locale
        if language == "auto" || language.isEmpty {
            requested = .current
        } else {
            requested = Locale(identifier: language)
        }
        return await SpeechTranscriber.supportedLocale(equivalentTo: requested)
    }

    private nonisolated func localeIdentifier(_ locale: Locale) -> String {
        locale.identifier(.bcp47)
    }
}

@available(iOS 26.0, *)
private enum AppleSpeechSetupError: Error, LocalizedError, Sendable {
    case permissionDenied
    case permissionRestricted
    case transcriberUnavailable
    case localeUnsupported(String)
    case assetUnsupported(String)
    case assetStateUnexpected(String)
    case audioFormatUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "Speech Recognition access is off. Enable it for Vox.md in Settings, then try again.")
        case .permissionRestricted:
            return String(localized: "Speech Recognition is restricted on this iPhone. Check Screen Time or device-management settings.")
        case .transcriberUnavailable:
            return String(localized: "The on-device Apple Speech transcriber is unavailable on this iPhone.")
        case .localeUnsupported(let language):
            let displayLanguage = language == "auto" ? Locale.current.identifier : language
            return String(localized: "Apple Speech does not support the current transcription language (\(displayLanguage)).")
        case .assetUnsupported(let locale):
            return String(localized: "Apple Speech cannot install its \(locale) language model on this iPhone.")
        case .assetStateUnexpected(let locale):
            return String(localized: "Apple Speech reported an unexpected asset state for \(locale).")
        case .audioFormatUnavailable:
            return String(localized: "Apple Speech could not select a compatible live audio format.")
        }
    }
}

@available(iOS 26.0, *)
private enum AppleSpeechAssetPreparationError: Error, LocalizedError, Sendable {
    case installationPending(String)

    var errorDescription: String? {
        switch self {
        case .installationPending(let locale):
            return String(localized: "Apple Speech is still preparing the \(locale) language model. Keep Vox.md open and try again shortly.")
        }
    }
}

@available(iOS 26.0, *)
private enum AppleSpeechLiveTranscriptionError: Error, LocalizedError, Sendable {
    case invalidAudioFormat
    case inputBackpressure
    case inputTerminated
    case analysisFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAudioFormat:
            return String(localized: "Apple Speech could not prepare the live audio format.")
        case .inputBackpressure:
            return String(localized: "Apple Speech could not keep up with the live recording.")
        case .inputTerminated:
            return String(localized: "The Apple Speech live session ended unexpectedly.")
        case .analysisFailed(let message):
            return message
        }
    }
}

/// Owns one progressive SpeechAnalyzer session. All AVAudioConverter and
/// transcript state stays actor-isolated and away from the real-time audio tap.
@available(iOS 26.0, *)
private actor AppleSpeechLiveTranscriptionSession: SystemLiveTranscriptionSession {
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let analyzerFormat: AVAudioFormat
    private let localeIdentifier: String
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let onUpdate: @Sendable (SystemTranscriptionUpdate) async -> Void

    private var converter: AVAudioConverter?
    private var resultTask: Task<Void, Never>?
    private var finalizedTranscript = AttributedString()
    private var volatileTranscript = AttributedString()
    private var revision = 0
    private var terminalFailure: AppleSpeechLiveTranscriptionError?
    private var resultConsumerFinished = false
    private var isFinishing = false
    private var isFinished = false

    init(
        analyzer: SpeechAnalyzer,
        transcriber: SpeechTranscriber,
        analyzerFormat: AVAudioFormat,
        localeIdentifier: String,
        inputContinuation: AsyncStream<AnalyzerInput>.Continuation,
        onUpdate: @escaping @Sendable (SystemTranscriptionUpdate) async -> Void
    ) {
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.analyzerFormat = analyzerFormat
        self.localeIdentifier = localeIdentifier
        self.inputContinuation = inputContinuation
        self.onUpdate = onUpdate
    }

    func start(inputSequence: AsyncStream<AnalyzerInput>) async throws {
        try Task.checkCancellation()
        let transcriber = self.transcriber
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    // Consume a result already yielded by Speech even if cleanup
                    // cancellation arrives concurrently.
                    await self?.consume(text: result.text, isFinal: result.isFinal)
                    if Task.isCancelled { break }
                }
            } catch is CancellationError {
                // Expected when a segment is cancelled or after finalization.
            } catch {
                await self?.recordFailure(error)
            }
            await self?.markResultConsumerFinished()
        }
        try await analyzer.start(inputSequence: inputSequence)
    }

    func append(_ chunk: SystemTranscriptionAudioChunk) async throws {
        try Task.checkCancellation()
        if let terminalFailure { throw terminalFailure }
        guard !isFinished,
              !isFinishing,
              chunk.sampleRate > 0,
              !chunk.samples.isEmpty,
              let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: chunk.sampleRate,
                channels: 1,
                interleaved: false
              ),
              let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(chunk.samples.count)
              ),
              let destination = sourceBuffer.floatChannelData?[0] else {
            throw AppleSpeechLiveTranscriptionError.invalidAudioFormat
        }

        sourceBuffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        chunk.samples.withUnsafeBufferPointer { samples in
            guard let baseAddress = samples.baseAddress else { return }
            destination.update(from: baseAddress, count: samples.count)
        }

        let converted = try convert(sourceBuffer)
        switch inputContinuation.yield(AnalyzerInput(buffer: converted)) {
        case .enqueued:
            return
        case .dropped:
            throw AppleSpeechLiveTranscriptionError.inputBackpressure
        case .terminated:
            throw AppleSpeechLiveTranscriptionError.inputTerminated
        @unknown default:
            throw AppleSpeechLiveTranscriptionError.inputTerminated
        }
    }

    func finish() async throws -> SystemTranscriptionOutput {
        if isFinished {
            let text = finalizedText
            guard !text.isEmpty else { throw OnDeviceTranscriptionError.noSpeechDetected }
            return SystemTranscriptionOutput(text: text, language: localeIdentifier)
        }
        guard !isFinishing else {
            throw AppleSpeechLiveTranscriptionError.inputTerminated
        }
        isFinishing = true
        inputContinuation.finish()

        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            resultTask?.cancel()
            await analyzer.cancelAndFinishNow()
            _ = await resultTask?.value
            isFinishing = false
            isFinished = true
            throw error
        }

        // Speech has produced its final module results, but the independent
        // consumer task may still be queued behind this actor. Give it a short,
        // bounded drain window before cancellation so the last phrase is not lost.
        for _ in 0..<50 where !resultConsumerFinished {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let consumedAllFinalResults = resultConsumerFinished
        resultTask?.cancel()
        _ = await resultTask?.value
        resultTask = nil
        isFinishing = false
        isFinished = true

        guard consumedAllFinalResults else {
            throw AppleSpeechLiveTranscriptionError.analysisFailed(
                String(localized: "Apple Speech final results did not finish in time.")
            )
        }
        if let terminalFailure { throw terminalFailure }
        volatileTranscript = AttributedString()
        revision += 1
        await publishUpdate()

        let text = finalizedText
        guard !text.isEmpty else { throw OnDeviceTranscriptionError.noSpeechDetected }
        return SystemTranscriptionOutput(text: text, language: localeIdentifier)
    }

    func cancel() async {
        guard !isFinished else { return }
        isFinishing = false
        isFinished = true
        inputContinuation.finish()
        resultTask?.cancel()
        await analyzer.cancelAndFinishNow()
        _ = await resultTask?.value
        resultTask = nil
    }

    private func consume(text: AttributedString, isFinal: Bool) async {
        guard !isFinished else { return }
        if isFinal {
            finalizedTranscript += text
            volatileTranscript = AttributedString()
        } else {
            volatileTranscript = text
        }
        revision += 1
        await publishUpdate()
    }

    private func recordFailure(_ error: Error) {
        terminalFailure = .analysisFailed(error.localizedDescription)
    }

    private func markResultConsumerFinished() {
        resultConsumerFinished = true
    }

    private func publishUpdate() async {
        let volatile = String(volatileTranscript.characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        await onUpdate(SystemTranscriptionUpdate(
            revision: revision,
            finalizedText: finalizedText,
            volatileText: volatile.isEmpty ? nil : volatile
        ))
    }

    private var finalizedText: String {
        String(finalizedTranscript.characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard input.format != analyzerFormat else { return input }

        if converter == nil || converter?.outputFormat != analyzerFormat {
            converter = AVAudioConverter(from: input.format, to: analyzerFormat)
            converter?.primeMethod = .none
        }
        guard let converter else {
            throw AppleSpeechLiveTranscriptionError.invalidAudioFormat
        }

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up))
        guard let output = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: max(capacity, 1)
        ) else {
            throw AppleSpeechLiveTranscriptionError.invalidAudioFormat
        }

        var conversionError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error else {
            throw AppleSpeechLiveTranscriptionError.analysisFailed(
                conversionError?.localizedDescription ?? String(localized: "Live audio conversion failed.")
            )
        }
        return output
    }
}

/// Main-app composition root. Other targets receive `OnDeviceTranscriptionService`
/// without a system backend and therefore never link or call iOS 26 Speech APIs.
enum AppTranscriptionServices {
    nonisolated static let shared: OnDeviceTranscriptionService = {
        if #available(iOS 26.0, *) {
            return OnDeviceTranscriptionService(systemBackend: AppleSpeechTranscriptionBackend())
        }
        return OnDeviceTranscriptionService()
    }()
}
