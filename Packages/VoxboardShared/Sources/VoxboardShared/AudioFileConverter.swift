#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// Audio conversion helpers shared by live recording and imported-file flows.
/// Whisper expects 16 kHz mono 16-bit PCM WAV; arbitrary imports are converted
/// to that format before local transcription.
public enum AudioFileConverter {
    public enum ConversionError: Error {
        case couldNotOpenInput
        case couldNotCreateFormat
        case couldNotCreateConverter
        case couldNotCreateBuffer
        case noAudioSamples
    }

    public static let whisperSampleRate: Double = 16_000

    @discardableResult
    public static func convertToWhisperWAV(
        inputURL: URL,
        outputURL: URL,
        targetSampleRate: Double = whisperSampleRate
    ) throws -> URL {
        try Task.checkCancellation()
        let inputFile = try AVAudioFile(forReading: inputURL)
        let sourceFormat = inputFile.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { throw ConversionError.couldNotCreateFormat }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(inputFile.length)
        ) else { throw ConversionError.couldNotCreateBuffer }
        try inputFile.read(into: inputBuffer)
        try Task.checkCancellation()

        let allSamples: [Float]
        if sourceFormat.sampleRate == targetSampleRate, sourceFormat.channelCount == 1,
           let floatData = inputBuffer.floatChannelData?[0] {
            allSamples = Array(UnsafeBufferPointer(start: floatData, count: Int(inputBuffer.frameLength)))
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw ConversionError.couldNotCreateConverter
            }
            let ratio = targetSampleRate / sourceFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 8
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
                throw ConversionError.couldNotCreateBuffer
            }

            var consumed = false
            var conversionError: NSError?
            converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            if let conversionError { throw conversionError }
            try Task.checkCancellation()
            guard let floatData = outputBuffer.floatChannelData?[0] else {
                throw ConversionError.noAudioSamples
            }
            allSamples = Array(UnsafeBufferPointer(start: floatData, count: Int(outputBuffer.frameLength)))
        }

        guard !allSamples.isEmpty else { throw ConversionError.noAudioSamples }
        try Task.checkCancellation()
        try writeWAV(samples: allSamples, to: outputURL, sampleRate: targetSampleRate)
        return outputURL
    }

    /// Converts without allocating a buffer for the complete recording. This is
    /// the meeting path used for multi-hour stems.
    @discardableResult
    public static func convertToWhisperWAVStreaming(
        inputURL: URL,
        outputURL: URL,
        targetSampleRate: Double = whisperSampleRate,
        inputFramesPerChunk: AVAudioFrameCount = 16_384
    ) throws -> URL {
        try Task.checkCancellation()
        let input = try AVAudioFile(forReading: inputURL)
        let sourceFormat = input.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { throw ConversionError.couldNotCreateFormat }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw ConversionError.couldNotCreateConverter
        }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: outputURL)
        let output = try AVAudioFile(
            forWriting: outputURL,
            settings: targetFormat.settings,
            commonFormat: targetFormat.commonFormat,
            interleaved: targetFormat.isInterleaved
        )
        var wroteFrames = false

        while input.framePosition < input.length {
            try Task.checkCancellation()
            let remaining = AVAudioFrameCount(min(Int64(inputFramesPerChunk), input.length - input.framePosition))
            guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: remaining) else {
                throw ConversionError.couldNotCreateBuffer
            }
            try input.read(into: source, frameCount: remaining)
            if source.frameLength == 0 { break }
            let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * targetSampleRate / sourceFormat.sampleRate)) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                throw ConversionError.couldNotCreateBuffer
            }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return source
            }
            if let conversionError { throw conversionError }
            guard status != .error else { throw ConversionError.noAudioSamples }
            if converted.frameLength > 0 {
                try output.write(from: converted)
                wroteFrames = true
            }
        }
        guard wroteFrames else { throw ConversionError.noAudioSamples }
        return outputURL
    }

    /// Places finalized chunks on the common meeting timeline. Silence is
    /// inserted for first-source offsets and inter-chunk gaps. Overlapping or
    /// discontinuous chunks are clipped at the already published frontier.
    @discardableResult
    public static func normalizeMeetingStem(
        chunks: [(url: URL, startTime: TimeInterval, endTime: TimeInterval)],
        outputURL: URL,
        targetSampleRate: Double = whisperSampleRate
    ) throws -> URL {
        guard !chunks.isEmpty else { throw ConversionError.noAudioSamples }
        let ordered = chunks.sorted { $0.startTime == $1.startTime ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.startTime < $1.startTime }
        let temporaryDirectory = outputURL.deletingLastPathComponent().appendingPathComponent(".meeting-timeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: targetSampleRate, channels: 1, interleaved: false) else {
            throw ConversionError.couldNotCreateFormat
        }
        try? FileManager.default.removeItem(at: outputURL)
        let destination = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        var frontier: AVAudioFramePosition = 0
        var wrote = false

        func writeSilence(_ count: AVAudioFramePosition) throws {
            var remaining = count
            while remaining > 0 {
                let frames = AVAudioFrameCount(min(16_384, remaining))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                      let samples = buffer.int16ChannelData?[0] else { throw ConversionError.couldNotCreateBuffer }
                buffer.frameLength = frames
                memset(samples, 0, Int(frames) * MemoryLayout<Int16>.size)
                try destination.write(from: buffer)
                remaining -= AVAudioFramePosition(frames)
            }
        }

        for (index, chunk) in ordered.enumerated() {
            try Task.checkCancellation()
            let normalized = temporaryDirectory.appendingPathComponent("\(index).wav")
            try convertToWhisperWAVStreaming(inputURL: chunk.url, outputURL: normalized, targetSampleRate: targetSampleRate)
            let source = try AVAudioFile(forReading: normalized)
            let desiredStart = AVAudioFramePosition(max(0, (chunk.startTime * targetSampleRate).rounded()))
            let desiredEnd = AVAudioFramePosition(max(
                Double(desiredStart),
                (chunk.endTime * targetSampleRate).rounded()
            ))
            if desiredStart > frontier {
                try writeSilence(desiredStart - frontier)
                frontier = desiredStart
            }
            let framesToSkip = max(0, frontier - desiredStart)
            source.framePosition = min(source.length, framesToSkip)
            while source.framePosition < source.length, frontier < desiredEnd {
                let count = AVAudioFrameCount(min(
                    16_384,
                    min(source.length - source.framePosition, desiredEnd - frontier)
                ))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: count) else { throw ConversionError.couldNotCreateBuffer }
                try source.read(into: buffer, frameCount: count)
                guard buffer.frameLength > 0 else { break }
                try destination.write(from: buffer)
                frontier += AVAudioFramePosition(buffer.frameLength)
                wrote = true
            }
            if frontier < desiredEnd {
                try writeSilence(desiredEnd - frontier)
                frontier = desiredEnd
            }
        }
        guard wrote else { throw ConversionError.noAudioSamples }
        return outputURL
    }

    @discardableResult
    public static func concatenateToWhisperWAVStreaming(
        inputURLs: [URL],
        outputURL: URL,
        targetSampleRate: Double = whisperSampleRate
    ) throws -> URL {
        guard !inputURLs.isEmpty else { throw ConversionError.noAudioSamples }
        let temporaryDirectory = outputURL.deletingLastPathComponent().appendingPathComponent(".meeting-normalize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: targetSampleRate, channels: 1, interleaved: false)!
        try? FileManager.default.removeItem(at: outputURL)
        let destination = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        var wrote = false
        for (index, url) in inputURLs.enumerated() {
            let normalized = temporaryDirectory.appendingPathComponent("\(index).wav")
            try convertToWhisperWAVStreaming(inputURL: url, outputURL: normalized, targetSampleRate: targetSampleRate)
            let source = try AVAudioFile(forReading: normalized)
            while source.framePosition < source.length {
                let count = AVAudioFrameCount(min(16_384, source.length - source.framePosition))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: count) else { throw ConversionError.couldNotCreateBuffer }
                try source.read(into: buffer, frameCount: count)
                if buffer.frameLength > 0 { try destination.write(from: buffer); wrote = true }
            }
        }
        guard wrote else { throw ConversionError.noAudioSamples }
        return outputURL
    }

    public static func mixWhisperWAVStreaming(
        microphoneURL: URL?,
        systemURL: URL?,
        outputURL: URL,
        framesPerChunk: AVAudioFrameCount = 16_384
    ) throws -> URL {
        guard microphoneURL != nil || systemURL != nil else { throw ConversionError.noAudioSamples }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: whisperSampleRate, channels: 1, interleaved: false)!
        let mic = try microphoneURL.map { try AVAudioFile(forReading: $0) }
        let system = try systemURL.map { try AVAudioFile(forReading: $0) }
        let gain: Float = mic != nil && system != nil ? 0.5 : 1.0
        try? FileManager.default.removeItem(at: outputURL)
        let output = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let total = max(mic?.length ?? 0, system?.length ?? 0)
        var position: AVAudioFramePosition = 0
        while position < total {
            let count = AVAudioFrameCount(min(Int64(framesPerChunk), total - position))
            guard let mixed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count), let values = mixed.floatChannelData?[0] else { throw ConversionError.couldNotCreateBuffer }
            mixed.frameLength = count
            for i in 0..<Int(count) { values[i] = 0 }
            for file in [mic, system].compactMap({ $0 }) {
                guard file.framePosition < file.length, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { continue }
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(count), file.length - file.framePosition)))
                if let source = buffer.floatChannelData?[0] {
                    for i in 0..<Int(buffer.frameLength) { values[i] += source[i] * gain }
                }
            }
            for i in 0..<Int(count) { values[i] = max(-0.98, min(0.98, values[i])) }
            try output.write(from: mixed); position += AVAudioFramePosition(count)
        }
        return outputURL
    }

    public static func duration(of url: URL) -> TimeInterval? {
        if let file = try? AVAudioFile(forReading: url) {
            return Double(file.length) / file.processingFormat.sampleRate
        }
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    public static func writeWAV(samples: [Float], to url: URL, sampleRate: Double = whisperSampleRate) throws {
        let int16Samples = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * 32767.0)
        }
        try writeWAV(int16Samples: int16Samples, to: url, sampleRate: sampleRate)
    }

    public static func writeWAV(int16Samples: [Int16], to url: URL, sampleRate: Double = whisperSampleRate) throws {
        let dataSize = int16Samples.count * 2
        let fileSize = 36 + dataSize

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(uint32LE: UInt32(fileSize))
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(uint32LE: 16)
        header.append(uint16LE: 1)
        header.append(uint16LE: 1)
        header.append(uint32LE: UInt32(sampleRate))
        header.append(uint32LE: UInt32(sampleRate) * 2)
        header.append(uint16LE: 2)
        header.append(uint16LE: 16)
        header.append(contentsOf: "data".utf8)
        header.append(uint32LE: UInt32(dataSize))

        var fileData = header
        int16Samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            fileData.append(UnsafeBufferPointer(
                start: UnsafeRawPointer(baseAddress).assumingMemoryBound(to: UInt8.self),
                count: dataSize
            ))
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileData.write(to: url, options: .atomic)
    }
}

private extension Data {
    mutating func append(uint16LE value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func append(uint32LE value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
#endif
