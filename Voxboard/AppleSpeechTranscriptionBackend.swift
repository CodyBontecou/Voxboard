import AVFoundation
import Foundation
import Speech
import VoxboardShared

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
        guard SpeechTranscriber.isAvailable,
              let locale = await supportedLocale(for: language) else {
            throw OnDeviceTranscriptionError.systemBackendUnavailable
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await ensureAssets(for: transcriber)
    }

    func transcribe(audioURL: URL, language: String) async throws -> SystemTranscriptionOutput {
        try Task.checkCancellation()
        guard SpeechTranscriber.isAvailable,
              let locale = await supportedLocale(for: language) else {
            throw OnDeviceTranscriptionError.systemBackendUnavailable
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await ensureAssets(for: transcriber)

        let audioFile = try AVAudioFile(forReading: audioURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        async let collectedText: AttributedString = transcriber.results.reduce(into: AttributedString()) {
            transcript, result in
            if result.isFinal {
                transcript += result.text
            }
        }

        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }

            let attributedText = try await collectedText
            let text = String(attributedText.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw OnDeviceTranscriptionError.noSpeechDetected
            }
            return SystemTranscriptionOutput(
                text: text,
                language: localeIdentifier(locale)
            )
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private func ensureAssets(for transcriber: SpeechTranscriber) async throws {
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return
        case .unsupported:
            throw OnDeviceTranscriptionError.systemBackendUnavailable
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        @unknown default:
            throw OnDeviceTranscriptionError.systemBackendUnavailable
        }

        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw OnDeviceTranscriptionError.systemBackendUnavailable
        }
    }

    private func supportedLocale(for language: String) async -> Locale? {
        let requested: Locale
        if language == "auto" || language.isEmpty {
            requested = .autoupdatingCurrent
        } else {
            requested = Locale(identifier: language)
        }
        return await SpeechTranscriber.supportedLocale(equivalentTo: requested)
    }

    private nonisolated func localeIdentifier(_ locale: Locale) -> String {
        locale.identifier(.bcp47)
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
