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
