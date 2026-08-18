import AVFoundation
import CoreMedia
import Foundation

/// Outcome of handing a sample buffer to a chunk's asset-writer session.
public enum MeetingChunkAppendOutcome: Equatable, Sendable {
    /// The buffer was appended to the current chunk.
    case appended
    /// The session was not ready for more media data; the caller records a
    /// dropped-audio timeline event.
    case notReady
    /// The session rejected the buffer (its `error` carries the failure).
    case failed
}

/// One per-chunk asset writer session. Abstracting `AVAssetWriter` behind
/// this seam keeps the queue-confined rollover/drain/stop interleavings in
/// `ChunkedSampleBufferWriter` deterministic to test with a fake while the
/// concrete implementation remains a thin AVFoundation wrapper.
public protocol MeetingChunkAssetWriting: AnyObject {
    /// Whether the underlying writer can accept more media data right now.
    var isReadyForMoreMediaData: Bool { get }
    /// The underlying failure when appends are rejected.
    var error: Error? { get }
    /// Whether the writer finished the chunk successfully.
    var completedSuccessfully: Bool { get }
    /// Appends a buffer, reporting readiness and failure distinctly.
    func append(_ buffer: CMSampleBuffer) -> MeetingChunkAppendOutcome
    /// No further buffers will arrive for this chunk.
    func markAsFinished()
    /// Finalizes the chunk; the completion fires exactly once on any queue
    /// and the recorder re-serializes it onto its own callback queue.
    func finishWriting(_ completion: @escaping @Sendable () -> Void)
}

/// Concrete `AVAssetWriter`-backed chunk session. Construction performs the
/// full `add`/`startWriting`/`startSession` sequence and throws on failure.
public final class AVAssetWriterMeetingChunkSession: MeetingChunkAssetWriting, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput

    public var isReadyForMoreMediaData: Bool { input.isReadyForMoreMediaData }
    public var error: Error? { writer.error }
    public var completedSuccessfully: Bool { writer.status == .completed }

    public init(url: URL, sourceFormatHint: CMFormatDescription?) throws {
        guard let asbd = sourceFormatHint.flatMap(CMAudioFormatDescriptionGetStreamBasicDescription)?.pointee else {
            throw NSError(domain: "VoxMeetingWriter", code: 2)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: asbd.mSampleRate,
            AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame),
            AVEncoderBitRateKey: 128_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: sourceFormatHint)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw NSError(domain: "VoxMeetingWriter", code: 3) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "VoxMeetingWriter", code: 4) }
        self.writer = writer
        self.input = input
    }

    public func startSession(atSourceTime time: CMTime) {
        writer.startSession(atSourceTime: time)
    }

    public func append(_ buffer: CMSampleBuffer) -> MeetingChunkAppendOutcome {
        guard input.isReadyForMoreMediaData else { return .notReady }
        return input.append(buffer) ? .appended : .failed
    }

    public func markAsFinished() {
        input.markAsFinished()
    }

    public func finishWriting(_ completion: @escaping @Sendable () -> Void) {
        writer.finishWriting { completion() }
    }
}

/// Builds a started chunk session for a new chunk file. The default factory
/// produces `AVAssetWriter`-backed sessions; tests inject fakes to drive the
/// rollover/drain/stop interleavings deterministically.
public typealias MeetingChunkAssetWriterFactory = @Sendable (
    _ url: URL,
    _ sourceFormatHint: CMFormatDescription?,
    _ sessionStartTime: CMTime
) throws -> any MeetingChunkAssetWriting

public func defaultMeetingChunkAssetWriterFactory(
    url: URL,
    sourceFormatHint: CMFormatDescription?,
    sessionStartTime: CMTime
) throws -> any MeetingChunkAssetWriting {
    let session = try AVAssetWriterMeetingChunkSession(url: url, sourceFormatHint: sourceFormatHint)
    session.startSession(atSourceTime: sessionStartTime)
    return session
}

/// The finalized-chunk payload crossing the writer seam: the durable chunk
/// descriptor, its timeline events, and any warnings accumulated while the
/// chunk was being written.
public struct MeetingWriterFinalizationResult: @unchecked Sendable {
    public let chunk: MeetingCaptureChunk
    public let events: [MeetingTimelineEvent]
    public let warnings: [String]

    public init(chunk: MeetingCaptureChunk, events: [MeetingTimelineEvent], warnings: [String]) {
        self.chunk = chunk
        self.events = events
        self.warnings = warnings
    }
}

/// Exactly-once mailbox for finalized chunks: writer callbacks enqueue from
/// queue contexts and the main actor takes each delivery by identifier, so a
/// duplicate take (or a delivery raced by stop's drain) can never publish the
/// same chunk twice.
public final class MeetingWriterFinalizationMailbox: @unchecked Sendable {
    private struct Entry {
        let identifier: UUID
        let result: MeetingWriterFinalizationResult
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    public init() {}

    public func enqueue(_ result: MeetingWriterFinalizationResult) -> UUID {
        let identifier = UUID()
        lock.withLock { entries.append(.init(identifier: identifier, result: result)) }
        return identifier
    }

    /// Removes and returns the delivery for `identifier`; a second take of the
    /// same identifier returns `nil`, which is how duplicate publishes are
    /// suppressed.
    public func take(_ identifier: UUID) -> MeetingWriterFinalizationResult? {
        lock.withLock {
            guard let index = entries.firstIndex(where: { $0.identifier == identifier }) else { return nil }
            return entries.remove(at: index).result
        }
    }

    /// Returns and clears every undelivered entry (used at stop so late
    /// finalizations are not lost).
    public func drain() -> [MeetingWriterFinalizationResult] {
        lock.withLock {
            let results = entries.map(\.result)
            entries.removeAll()
            return results
        }
    }

    public func reset() { lock.withLock { entries.removeAll() } }
}

nonisolated func meetingSampleDuration(_ buffer: CMSampleBuffer) -> CMTime {
    let reported = CMSampleBufferGetDuration(buffer)
    let reportedSeconds = CMTimeGetSeconds(reported)
    if reported.isValid, !reported.isIndefinite, reportedSeconds.isFinite, reportedSeconds > 0 {
        return reported
    }
    guard let format = CMSampleBufferGetFormatDescription(buffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
          asbd.mSampleRate > 0 else { return .zero }
    return CMTime(
        seconds: Double(CMSampleBufferGetNumSamples(buffer)) / asbd.mSampleRate,
        preferredTimescale: 1_000_000_000
    )
}

public struct UncheckedSendableValue<Value>: @unchecked Sendable {
    public let value: Value

    public init(_ value: Value) { self.value = value }
}

/// Queue-confined writer. All mutable state, including the asset-writer
/// session's async completion, is consumed on `callbackQueue`. A bounded
/// rollover buffer keeps audio arriving during finalization without allowing
/// stop to start an orphan chunk.
public final class ChunkedSampleBufferWriter: @unchecked Sendable {
    private struct AudioFormatSignature: Equatable {
        let formatID: AudioFormatID
        let formatFlags: AudioFormatFlags
        let sampleRate: Double
        let channelCount: UInt32
        let bitsPerChannel: UInt32
        let bytesPerFrame: UInt32
    }

    private let source: MeetingAudioSource
    private let directoryURL: URL
    private let callbackQueue: DispatchQueue
    private let timelineOrigin: @Sendable () -> CMTime?
    private let finalized: @Sendable (MeetingCaptureChunk, [MeetingTimelineEvent], [String]) -> Void
    private let assetWriterFactory: MeetingChunkAssetWriterFactory
    private let chunkDuration: Double = 30
    private let maximumRolloverBufferCount = 512
    private var session: (any MeetingChunkAssetWriting)?
    private var chunkURL: URL?
    private var chunkStart: CMTime?
    private var currentFormatSignature: AudioFormatSignature?
    private var lastStartedFormatSignature: AudioFormatSignature?
    private var lastPTS: CMTime?
    private var lastDuration: CMTime = .zero
    private var hasAppendedSamples = false
    private var index = 0
    private var pendingEvents: [MeetingTimelineEvent] = []
    private var pendingWarnings: [String] = []
    private var rolloverBuffers: [UncheckedSendableValue<CMSampleBuffer>] = []
    private var rolloverDroppedStart: CMTime?
    private var rolloverDroppedDuration: TimeInterval = 0
    private var lifecycle = MeetingChunkWriterLifecycle()
    private var stopCompletions: [@Sendable (MeetingWriterFinalizationResult?) -> Void] = []

    public init(
        source: MeetingAudioSource,
        directoryURL: URL,
        callbackQueue: DispatchQueue,
        timelineOrigin: @escaping @Sendable () -> CMTime?,
        finalized: @escaping @Sendable (MeetingCaptureChunk, [MeetingTimelineEvent], [String]) -> Void,
        assetWriterFactory: @escaping MeetingChunkAssetWriterFactory = defaultMeetingChunkAssetWriterFactory
    ) {
        self.source = source
        self.directoryURL = directoryURL
        self.callbackQueue = callbackQueue
        self.timelineOrigin = timelineOrigin
        self.finalized = finalized
        self.assetWriterFactory = assetWriterFactory
    }

    public func append(_ buffer: CMSampleBuffer) throws {
        switch lifecycle.state {
        case .rotating:
            bufferForRollover(buffer)
            return
        case .stopping, .stopped:
            return
        case .accepting:
            break
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        if session == nil {
            try start(buffer, at: pts)
        } else if let signature = formatSignature(for: buffer),
                  let currentFormatSignature,
                  signature != currentFormatSignature {
            bufferForRollover(buffer)
            guard lifecycle.beginRotation() else { return }
            finishCurrent { [weak self] _ in self?.rotationDidFinish() }
            return
        }
        if chunkStart.map({ CMTimeGetSeconds(pts - $0) >= chunkDuration }) == true {
            bufferForRollover(buffer)
            guard lifecycle.beginRotation() else { return }
            finishCurrent { [weak self] _ in self?.rotationDidFinish() }
            return
        }
        try appendToCurrent(buffer)
    }

    private func appendToCurrent(_ buffer: CMSampleBuffer) throws {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        let duration = meetingSampleDuration(buffer)
        if let previous = lastPTS {
            let gap = CMTimeGetSeconds(pts - (previous + lastDuration))
            let relative = relativeTime(pts)
            if gap > 0.05 { pendingEvents.append(.init(source: source, kind: .gap, presentationTime: relative, duration: gap)) }
            else if gap < -0.05 { pendingEvents.append(.init(source: source, kind: .discontinuity, presentationTime: relative)) }
        } else {
            pendingEvents.append(.init(source: source, kind: .started, presentationTime: relativeTime(pts)))
        }
        guard let session else { return }
        switch session.append(buffer) {
        case .appended:
            hasAppendedSamples = true
            lastPTS = pts
            lastDuration = duration
        case .notReady:
            let dropped = max(0, CMTimeGetSeconds(duration))
            pendingEvents.append(.init(source: source, kind: .dropped, presentationTime: relativeTime(pts), duration: dropped))
            appendPendingWarning(String(localized: "\(sourceLabel) audio dropped because the writer could not keep up."))
            lastPTS = pts
            lastDuration = duration
        case .failed:
            throw session.error ?? NSError(domain: "VoxMeetingWriter", code: 1)
        }
    }

    private func bufferForRollover(_ buffer: CMSampleBuffer) {
        if rolloverBuffers.count < maximumRolloverBufferCount {
            rolloverBuffers.append(UncheckedSendableValue(buffer))
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        if rolloverDroppedStart == nil { rolloverDroppedStart = pts }
        rolloverDroppedDuration += max(0, CMTimeGetSeconds(meetingSampleDuration(buffer)))
    }

    private func start(_ buffer: CMSampleBuffer, at pts: CMTime) throws {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let signature = formatSignature(for: buffer) else { throw NSError(domain: "VoxMeetingWriter", code: 2) }
        let url = directoryURL.appendingPathComponent("\(source.artifactRole.rawValue)-\(String(format: "%04d", index)).m4a")
        index += 1
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: chunkReceiptURL(for: url))
        session = try assetWriterFactory(url, format, pts)
        chunkURL = url
        chunkStart = pts
        currentFormatSignature = signature
        let previousFormat = lastStartedFormatSignature
        lastStartedFormatSignature = signature
        lastPTS = nil; lastDuration = .zero; hasAppendedSamples = false
        pendingEvents.removeAll(); pendingWarnings.removeAll()
        if let previousFormat, previousFormat != signature {
            pendingEvents.append(.init(
                source: source,
                kind: .formatChange,
                presentationTime: relativeTime(pts),
                sampleRate: signature.sampleRate,
                channelCount: Int(signature.channelCount)
            ))
        }
    }

    private func finishCurrent(
        publishesFinalizedChunk: Bool = true,
        completion: @escaping @Sendable (MeetingWriterFinalizationResult?) -> Void
    ) {
        guard let session, let chunkURL, let chunkStart else { completion(nil); return }
        let endPTS = (lastPTS ?? chunkStart) + lastDuration
        let events = pendingEvents
        let warnings = pendingWarnings
        let hasAppendedSamples = hasAppendedSamples
        let provisionalChunk = MeetingCaptureChunk(
            source: source,
            filename: chunkURL.lastPathComponent,
            startTime: relativeTime(chunkStart),
            endTime: relativeTime(endPTS),
            byteCount: 0
        )
        let receiptPreparationError: String?
        do {
            try writeChunkReceipt(.init(chunk: provisionalChunk, events: events, warnings: warnings), for: chunkURL)
            receiptPreparationError = nil
        } catch {
            receiptPreparationError = error.localizedDescription
        }
        session.markAsFinished()
        let finishingSession = UncheckedSendableValue(session)
        let callbackQueue = callbackQueue
        session.finishWriting { [weak self] in
            callbackQueue.async { [weak self] in
                guard let self else { completion(nil); return }
                let result: MeetingWriterFinalizationResult
                if finishingSession.value.completedSuccessfully,
                   hasAppendedSamples,
                   receiptPreparationError == nil,
                   let size = (try? FileManager.default.attributesOfItem(atPath: chunkURL.path)[.size] as? NSNumber)?.uint64Value,
                   size > 0 {
                    var completedChunk = provisionalChunk
                    completedChunk.byteCount = size
                    let completed = MeetingWriterFinalizationResult(
                        chunk: completedChunk,
                        events: events,
                        warnings: warnings
                    )
                    do {
                        try self.writeChunkReceipt(.init(
                            chunk: completed.chunk,
                            events: completed.events,
                            warnings: completed.warnings
                        ), for: chunkURL)
                        result = completed
                    } catch {
                        try? FileManager.default.removeItem(at: chunkURL)
                        try? FileManager.default.removeItem(at: self.chunkReceiptURL(for: chunkURL))
                        result = MeetingWriterFinalizationResult(
                            chunk: .init(source: self.source, filename: chunkURL.lastPathComponent, startTime: 0, endTime: 0, byteCount: 0),
                            events: events,
                            warnings: warnings + [String(localized: "\(self.sourceLabel) audio chunk recovery metadata could not be finalized.")]
                        )
                    }
                } else {
                    try? FileManager.default.removeItem(at: chunkURL)
                    try? FileManager.default.removeItem(at: self.chunkReceiptURL(for: chunkURL))
                    let failure: String
                    if let receiptPreparationError {
                        failure = String(localized: "\(self.sourceLabel) audio chunk recovery metadata could not be prepared: \(receiptPreparationError).")
                    } else {
                        failure = String(localized: "\(self.sourceLabel) audio chunk could not be finalized.")
                    }
                    result = MeetingWriterFinalizationResult(
                        chunk: .init(source: self.source, filename: chunkURL.lastPathComponent, startTime: 0, endTime: 0, byteCount: 0),
                        events: events,
                        warnings: warnings + [failure]
                    )
                }
                self.session = nil
                self.chunkURL = nil
                self.chunkStart = nil
                self.currentFormatSignature = nil
                self.lastPTS = nil; self.lastDuration = .zero; self.hasAppendedSamples = false
                if publishesFinalizedChunk {
                    self.finalized(result.chunk, result.events, result.warnings)
                }
                completion(result)
            }
        }
    }

    private func rotationDidFinish() {
        switch lifecycle.didFinishRotation(hasBufferedSamples: !rolloverBuffers.isEmpty) {
        case .startNextChunk:
            drainRolloverBuffers(finalizeAfterDraining: false)
        case .finalizeBufferedChunk:
            drainRolloverBuffers(finalizeAfterDraining: true)
        case .completeStop:
            resolveStop(with: nil)
        case .none:
            break
        }
    }

    private func drainRolloverBuffers(finalizeAfterDraining: Bool) {
        guard let first = rolloverBuffers.first else {
            if finalizeAfterDraining {
                lifecycle.didFinishStop()
                resolveStop(with: nil)
            }
            return
        }

        // A route change can produce another format while the prior writer is
        // still finalizing. Drain one format/time-bounded prefix at a time so
        // no chunk session receives incompatible sample buffers.
        let firstPTS = CMSampleBufferGetPresentationTimeStamp(first.value)
        let firstFormat = formatSignature(for: first.value)
        var prefixCount = 1
        for candidate in rolloverBuffers.dropFirst() {
            let pts = CMSampleBufferGetPresentationTimeStamp(candidate.value)
            guard formatSignature(for: candidate.value) == firstFormat,
                  CMTimeGetSeconds(pts - firstPTS) < chunkDuration else { break }
            prefixCount += 1
        }
        let buffers = Array(rolloverBuffers.prefix(prefixCount))
        rolloverBuffers.removeFirst(prefixCount)
        let consumedAllBufferedSamples = rolloverBuffers.isEmpty
        let droppedStart = consumedAllBufferedSamples ? rolloverDroppedStart : nil
        let droppedDuration = consumedAllBufferedSamples ? rolloverDroppedDuration : 0
        if consumedAllBufferedSamples {
            rolloverDroppedStart = nil
            rolloverDroppedDuration = 0
        }

        var drainFailed = false
        do {
            try start(first.value, at: firstPTS)
            for buffer in buffers { try appendToCurrent(buffer.value) }
            if let droppedStart, droppedDuration > 0 {
                pendingEvents.append(.init(
                    source: source,
                    kind: .dropped,
                    presentationTime: relativeTime(droppedStart),
                    duration: droppedDuration
                ))
                appendPendingWarning(String(localized: "\(sourceLabel) audio exceeded the bounded rollover buffer and was dropped."))
            }
        } catch {
            drainFailed = true
            appendPendingWarning(String(localized: "\(sourceLabel) audio could not start its next chunk: \(error.localizedDescription)"))
            if session == nil {
                let result = failedResult(warnings: pendingWarnings)
                if !rolloverBuffers.isEmpty {
                    finalized(result.chunk, result.events, result.warnings)
                    drainRolloverBuffers(finalizeAfterDraining: finalizeAfterDraining)
                } else if finalizeAfterDraining {
                    lifecycle.didFinishStop()
                    resolveStop(with: result)
                } else {
                    finalized(result.chunk, result.events, result.warnings)
                }
                return
            }
        }

        if !rolloverBuffers.isEmpty {
            if finalizeAfterDraining {
                finishCurrent { [weak self] _ in
                    self?.drainRolloverBuffers(finalizeAfterDraining: true)
                }
            } else {
                guard lifecycle.beginRotation() else { return }
                finishCurrent { [weak self] _ in self?.rotationDidFinish() }
            }
            return
        }

        if finalizeAfterDraining {
            finishCurrent(publishesFinalizedChunk: false) { [weak self] result in
                guard let self else { return }
                self.lifecycle.didFinishStop()
                self.resolveStop(with: result)
            }
        } else if drainFailed {
            guard lifecycle.beginRotation() else { return }
            finishCurrent { [weak self] _ in self?.rotationDidFinish() }
        }
    }

    public func finish(completion: @escaping @Sendable (MeetingWriterFinalizationResult?) -> Void) {
        stopCompletions.append(completion)
        switch lifecycle.requestStop(hasCurrentChunk: session != nil) {
        case .finalizeCurrent:
            finishCurrent(publishesFinalizedChunk: false) { [weak self] result in
                guard let self else { return }
                self.lifecycle.didFinishStop()
                self.resolveStop(with: result)
            }
        case .waitForRotation:
            break
        case .completeStop:
            resolveStop(with: nil)
        case .alreadyStopping:
            if lifecycle.state == .stopped { resolveStop(with: nil) }
        }
    }

    private func resolveStop(with result: MeetingWriterFinalizationResult?) {
        let completions = stopCompletions
        stopCompletions.removeAll()
        for completion in completions { completion(result) }
    }

    private func failedResult(warnings: [String]) -> MeetingWriterFinalizationResult {
        MeetingWriterFinalizationResult(
            chunk: .init(source: source, filename: "", startTime: 0, endTime: 0, byteCount: 0),
            events: pendingEvents,
            warnings: warnings
        )
    }

    private func appendPendingWarning(_ warning: String) {
        if !pendingWarnings.contains(warning) { pendingWarnings.append(warning) }
    }

    private func chunkReceiptURL(for chunkURL: URL) -> URL {
        chunkURL.appendingPathExtension("chunk.json")
    }

    private func writeChunkReceipt(_ receipt: MeetingCaptureChunkReceipt, for chunkURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: chunkReceiptURL(for: chunkURL), options: .atomic)
    }

    private func formatSignature(for buffer: CMSampleBuffer) -> AudioFormatSignature? {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return nil }
        return AudioFormatSignature(
            formatID: asbd.mFormatID,
            formatFlags: asbd.mFormatFlags,
            sampleRate: asbd.mSampleRate,
            channelCount: asbd.mChannelsPerFrame,
            bitsPerChannel: asbd.mBitsPerChannel,
            bytesPerFrame: asbd.mBytesPerFrame
        )
    }

    private var sourceLabel: String {
        String(localized: source == .system ? "System" : "Microphone")
    }

    private func relativeTime(_ time: CMTime) -> TimeInterval {
        guard let origin = timelineOrigin() else { return 0 }
        let seconds = CMTimeGetSeconds(time - origin)
        return seconds.isFinite ? max(0, seconds) : 0
    }
}
