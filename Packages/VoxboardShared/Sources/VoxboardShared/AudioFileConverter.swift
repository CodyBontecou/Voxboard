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
        // Sniff the container header before opening the file. Some Apple
        // audio stacks (ExtAudioFile/FFR) execute crashy teardown paths when
        // handed malformed data, and recovery flows probe arbitrary orphaned
        // `.m4a` files — garbage bytes must never reach `AVAudioFile`.
        guard hasAudioContainerHeader(url) else { return nil }
        if let file = try? AVAudioFile(forReading: url) {
            return Double(file.length) / file.processingFormat.sampleRate
        }
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// Cheap container check that rejects obviously non-audio bytes without
    /// invoking any audio framework. Recognizes the leading signatures of
    /// every container `AVAudioFile` can open in this app's flows: MP4/M4A
    /// (`ftyp` at offset 4), CAF, WAV/RIFF, AIFF/FORM, Ogg, FLAC, ID3-tagged
    /// streams, and bare MPEG audio (MP3 without an ID3 tag, matched via the
    /// 11-bit sync word).
    static func hasAudioContainerHeader(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count == 12 else { return false }
        let bytes = [UInt8](head)
        if bytes[4...7].elementsEqual("ftyp".utf8) { return true }
        if ["caff", "RIFF", "FORM", "OggS", "fLaC", "ID3"]
            .contains(where: { bytes.starts(with: $0.utf8) }) { return true }
        // Bare MPEG audio sync word (MP3 without an ID3 tag): 11 set bits.
        return bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0
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
