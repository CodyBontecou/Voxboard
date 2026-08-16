import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import VoxboardShared

@MainActor
protocol MacMeetingCaptureCoordinating: AnyObject {
    var state: MacMeetingCaptureCoordinator.State { get }
    var selectedApplicationName: String? { get }
    var selectedApplicationBundleIdentifier: String? { get }
    var microphoneLevel: Float { get }
    var systemLevel: Float { get }
    var microphoneStatus: String { get }
    var systemStatus: String { get }
    var warnings: [String] { get }
    var interruptionHandler: (@MainActor @Sendable (String) -> Void)? { get set }
    func presentApplicationPicker(delivery: RecordingJobDelivery, modelID: String, fallbackModelID: String?, language: String, draftRequestID: UUID?) async throws
    func stop() async -> MacMeetingCaptureCoordinator.Result?
}

@Observable
@MainActor
final class MacMeetingCaptureCoordinator: NSObject, MacMeetingCaptureCoordinating {
    enum State: Equatable { case idle, presentingPicker, preparing, recording, stopping, completed, interrupted, failed(String) }
    struct Result: Sendable {
        let sessionID: UUID
        let directoryURL: URL
        let manifestURL: URL
        let manifest: MeetingCaptureManifest
    }

    private(set) var state: State = .idle
    private(set) var selectedApplicationName: String?
    private(set) var selectedApplicationBundleIdentifier: String?
    private(set) var microphoneLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var microphoneStatus = "Waiting"
    private(set) var systemStatus = "Waiting"
    private(set) var warnings: [String] = []
    var interruptionHandler: (@MainActor @Sendable (String) -> Void)?

    private let picker = SCContentSharingPicker.shared
    private let systemQueue = DispatchQueue(label: "VoxMeeting.system", qos: .userInitiated)
    private let microphoneQueue = DispatchQueue(label: "VoxMeeting.microphone", qos: .userInitiated)
    private let finalizationQueue = DispatchQueue(label: "VoxMeeting.finalization", qos: .utility)
    private nonisolated let manifestPersistence = MeetingManifestPersistence()
    private var continuation: CheckedContinuation<Void, Error>?
    private var stream: SCStream?
    private var micSession: AVCaptureSession?
    private var sessionID = UUID()
    private var directoryURL: URL?
    private var manifest: MeetingCaptureManifest?
    private nonisolated let writerState = MeetingWriterState()
    private nonisolated let finalizationMailbox = MeetingWriterFinalizationMailbox()
    private nonisolated let timelineClock = MeetingTimelineClock()
    private var lifecycle = MeetingCaptureLifecycle()
    private var stopTask: Task<Result?, Never>?
    private var didNotifyInterruption = false
    private var microphoneObservers: [NSObjectProtocol] = []

    override init() {
        super.init()
        picker.add(self)
    }

    deinit { picker.remove(self) }

    private var pendingDelivery: RecordingJobDelivery?
    private var pendingModelID: String?
    private var pendingFallbackModelID: String?
    private var pendingLanguage: String?
    private var pendingDraftRequestID: UUID?

    func presentApplicationPicker(
        delivery: RecordingJobDelivery,
        modelID: String,
        fallbackModelID: String?,
        language: String,
        draftRequestID: UUID?
    ) async throws {
        do { try lifecycle.beginSelection() } catch { throw CaptureError.invalidState }
        resetForNewSession()
        state = .presentingPicker
        pendingDelivery = delivery
        pendingModelID = modelID
        pendingFallbackModelID = fallbackModelID
        pendingLanguage = language
        pendingDraftRequestID = draftRequestID
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = .singleApplication
        configuration.allowsChangingSelectedContent = false
        if let bundleID = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [bundleID] }
        picker.defaultConfiguration = configuration
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            picker.isActive = true
            picker.present()
        }
    }

    func stop() async -> Result? {
        if let stopTask { return await stopTask.value }
        guard lifecycle.requestStop() else { return nil }
        let task = Task { @MainActor [weak self] in await self?.performStop() }
        stopTask = task
        let result = await task.value
        stopTask = nil
        return result
    }

    private func resetForNewSession() {
        sessionID = UUID()
        directoryURL = nil
        manifest = nil
        writerState.reset()
        finalizationMailbox.reset()
        stream = nil
        micSession = nil
        timelineClock.reset()
        selectedApplicationName = nil
        selectedApplicationBundleIdentifier = nil
        microphoneLevel = 0
        systemLevel = 0
        microphoneStatus = "Waiting"
        systemStatus = "Waiting"
        warnings.removeAll()
        didNotifyInterruption = false
        clearMicrophoneObservers()
    }

    private func begin(filter: SCContentFilter) async throws {
        try lifecycle.beginPreparing()
        state = .preparing
        guard let root = AppConstants.recordingsDirectoryURL else { throw CaptureError.storageUnavailable }
        let directory = root.appendingPathComponent("meeting-\(sessionID.uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directoryURL = directory
        let application = try await resolveApplication(for: filter)
        selectedApplicationName = application?.applicationName ?? "Selected application"
        selectedApplicationBundleIdentifier = application?.bundleIdentifier
        let manifest = MeetingCaptureManifest(
            sessionID: sessionID,
            state: .preparing,
            selectedApplicationName: selectedApplicationName,
            selectedApplicationBundleIdentifier: selectedApplicationBundleIdentifier,
            delivery: pendingDelivery,
            modelID: pendingModelID,
            fallbackModelID: pendingFallbackModelID,
            language: pendingLanguage,
            draftRequestID: pendingDraftRequestID
        )
        self.manifest = manifest
        try await persistManifestSnapshot(manifest)

        let finalized: @Sendable (MeetingCaptureChunk, [MeetingTimelineEvent], [String]) -> Void = { [weak self] chunk, events, warnings in
            guard let self else { return }
            let identifier = self.finalizationMailbox.enqueue(.init(chunk: chunk, events: events, warnings: warnings))
            Task { @MainActor [weak self] in
                guard let self, let result = self.finalizationMailbox.take(identifier) else { return }
                self.publishFinalized(chunk: result.chunk, events: result.events, warnings: result.warnings)
            }
        }
        writerState.install(
            system: ChunkedSampleBufferWriter(
                source: .system,
                directoryURL: directory,
                callbackQueue: systemQueue,
                timelineOrigin: { [timelineClock] in timelineClock.value },
                finalized: finalized
            ),
            microphone: ChunkedSampleBufferWriter(
                source: .microphone,
                directoryURL: directory,
                callbackQueue: microphoneQueue,
                timelineOrigin: { [timelineClock] in timelineClock.value },
                finalized: finalized
            )
        )

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        self.stream = stream
        try configureMicrophone()
        timelineClock.set(CMClockGetTime(CMClockGetHostTimeClock()))
        try await stream.startCapture()
        guard await startMicrophoneCapture() else {
            try? await stream.stopCapture()
            throw CaptureError.microphoneUnavailable
        }
        try lifecycle.didStart()
        var started = manifest
        started.state = .recording
        self.manifest = started
        try await persistManifestSnapshot(started)
        picker.isActive = false
        guard lifecycle.state == .recording else { return }
        state = .recording
        systemStatus = "Listening"
        microphoneStatus = "Listening"
    }

    private func resolveApplication(for filter: SCContentFilter) async throws -> SCRunningApplication? {
        guard #available(macOS 15.2, *) else {
            // macOS 14 does not expose a picker's included application. Do not
            // guess from the frontmost process; the filter remains authoritative.
            return nil
        }
        return filter.includedApplications.first
    }

    private func configureMicrophone() throws {
        guard let device = AVCaptureDevice.default(for: .audio) else { throw CaptureError.microphoneUnavailable }
        let session = AVCaptureSession()
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.microphoneUnavailable }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: microphoneQueue)
        guard session.canAddOutput(output) else { throw CaptureError.microphoneUnavailable }
        session.addOutput(output)
        session.commitConfiguration()
        micSession = session
        observeMicrophoneSession(session, device: device)
    }

    private func observeMicrophoneSession(_ session: AVCaptureSession, device: AVCaptureDevice) {
        clearMicrophoneObservers()
        let center = NotificationCenter.default
        microphoneObservers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMicrophoneInterruption("Microphone capture was interrupted.")
            }
        })
        microphoneObservers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let detail = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
                ?? "Unknown AVFoundation error"
            Task { @MainActor [weak self] in
                self?.handleMicrophoneInterruption("Microphone capture stopped: \(detail)")
            }
        })
        let deviceID = device.uniqueID
        microphoneObservers.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard (notification.object as? AVCaptureDevice)?.uniqueID == deviceID else { return }
            Task { @MainActor [weak self] in
                self?.handleMicrophoneInterruption("The selected microphone was disconnected.")
            }
        })
    }

    private func clearMicrophoneObservers() {
        let center = NotificationCenter.default
        for observer in microphoneObservers { center.removeObserver(observer) }
        microphoneObservers.removeAll()
    }

    private func handleMicrophoneInterruption(_ message: String) {
        guard lifecycle.state == .recording, !didNotifyInterruption else { return }
        didNotifyInterruption = true
        appendWarning(message)
        microphoneStatus = "Stopped"
        interruptionHandler?(message)
    }

    private func startMicrophoneCapture() async -> Bool {
        guard let micSession else { return false }
        let session = UncheckedSendableValue(micSession)
        return await withCheckedContinuation { continuation in
            microphoneQueue.async {
                session.value.startRunning()
                continuation.resume(returning: session.value.isRunning)
            }
        }
    }

    private func stopMicrophoneCapture() async {
        guard let micSession else { return }
        let session = UncheckedSendableValue(micSession)
        await withCheckedContinuation { continuation in
            microphoneQueue.async {
                if session.value.isRunning { session.value.stopRunning() }
                continuation.resume()
            }
        }
    }

    private func cleanupAfterFailedBegin() async {
        if let stream { try? await stream.stopCapture() }
        await stopMicrophoneCapture()
        clearMicrophoneObservers()
        writerState.reset()
        finalizationMailbox.reset()
        stream = nil
        micSession = nil
        manifest = nil
        if let directoryURL { try? FileManager.default.removeItem(at: directoryURL) }
        directoryURL = nil
    }

    private func performStop() async -> Result? {
        state = .stopping
        if let stream { try? await stream.stopCapture() }
        await stopMicrophoneCapture()
        clearMicrophoneObservers()
        let finalization: [MeetingAudioSource: MeetingWriterFinalizationResult] = await withCheckedContinuation { continuation in
            let group = DispatchGroup()
            let results = MeetingWriterFinalizationResults()
            let writers = writerState.snapshot()
            if let systemWriter = writers.system {
                group.enter()
                systemQueue.async { systemWriter.finish { results.set($0, for: .system); group.leave() } }
            }
            if let microphoneWriter = writers.microphone {
                group.enter()
                microphoneQueue.async { microphoneWriter.finish { results.set($0, for: .microphone); group.leave() } }
            }
            group.notify(queue: finalizationQueue) { continuation.resume(returning: results.snapshot()) }
        }
        writerState.reset()
        for result in finalizationMailbox.drain() {
            publishFinalized(chunk: result.chunk, events: result.events, warnings: result.warnings)
        }
        for source in MeetingAudioSource.allCases {
            guard let result = finalization[source] else { continue }
            publishFinalized(chunk: result.chunk, events: result.events, warnings: result.warnings)
        }
        guard let directoryURL, var manifest else { state = .failed("Meeting storage is unavailable."); return nil }
        if manifest.orderedChunks(for: .microphone).isEmpty { appendWarning("Microphone audio was not captured.") }
        if manifest.orderedChunks(for: .system).isEmpty { appendWarning("The selected application produced no capturable audio.") }
        manifest = self.manifest ?? manifest
        manifest.duration = max(
            manifest.duration,
            manifest.chunks.map(\.endTime).max() ?? 0
        )
        manifest.warnings = warnings
        manifest.state = warnings.isEmpty ? .captured : .interrupted
        self.manifest = manifest
        try? await persistManifestSnapshot(manifest)
        lifecycle.didFinish()
        state = warnings.isEmpty ? .completed : .interrupted
        picker.isActive = false
        return Result(
            sessionID: sessionID,
            directoryURL: directoryURL,
            manifestURL: directoryURL.appendingPathComponent("manifest.json"),
            manifest: manifest
        )
    }

    private func publishFinalized(chunk: MeetingCaptureChunk, events: [MeetingTimelineEvent], warnings newWarnings: [String]) {
        guard var manifest else { return }
        if chunk.byteCount > 0, !manifest.chunks.contains(where: { $0.filename == chunk.filename }) { manifest.chunks.append(chunk) }
        manifest.events.append(contentsOf: events)
        for warning in newWarnings where !manifest.warnings.contains(warning) { manifest.warnings.append(warning) }
        manifest.duration = max(manifest.duration, chunk.endTime)
        self.manifest = manifest
        warnings = manifest.warnings
        persistManifestSnapshotWithoutWaiting(manifest)
    }

    private func appendWarning(_ warning: String) {
        guard !warnings.contains(warning) else { return }
        warnings.append(warning)
        manifest?.warnings = warnings
    }

    private func persistManifestSnapshotWithoutWaiting(_ snapshot: MeetingCaptureManifest) {
        guard let directoryURL else { return }
        do {
            try manifestPersistence.submit(
                snapshot,
                to: directoryURL.appendingPathComponent("manifest.json")
            ) { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    self?.appendWarning("Meeting recovery metadata could not be updated: \(error.localizedDescription)")
                }
            }
        } catch {
            appendWarning("Meeting recovery metadata could not be updated: \(error.localizedDescription)")
        }
    }

    private func persistManifestSnapshot(_ snapshot: MeetingCaptureManifest) async throws {
        guard let directoryURL else { return }
        try await manifestPersistence.write(
            snapshot,
            to: directoryURL.appendingPathComponent("manifest.json")
        )
    }

    nonisolated private func receive(_ sampleBuffer: CMSampleBuffer, source: MeetingAudioSource) {
        guard CMSampleBufferDataIsReady(sampleBuffer), CMSampleBufferIsValid(sampleBuffer) else { return }
        let level = Self.level(sampleBuffer)
        Task { @MainActor [weak self] in
            guard let self, lifecycle.state == .recording else { return }
            if source == .system { systemLevel = level; systemStatus = "Capturing" }
            else { microphoneLevel = level; microphoneStatus = "Capturing" }
        }
        do {
            try writerState.writer(for: source)?.append(sampleBuffer)
        } catch {
            Task { @MainActor [weak self] in
                let label = source == .system ? "System" : "Microphone"
                self?.appendWarning("\(label) audio could not be preserved: \(error.localizedDescription)")
                if source == .system { self?.systemStatus = "Error" } else { self?.microphoneStatus = "Error" }
            }
        }
    }

    nonisolated private static func level(_ buffer: CMSampleBuffer) -> Float {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return 0 }
        var block: CMBlockBuffer?
        var size = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: &size, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &block
        ) == kCMSampleBufferError_ArrayTooSmall else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        let list = memory.assumingMemoryBound(to: AudioBufferList.self)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block
        ) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        var sum: Double = 0
        var count = 0
        for audioBuffer in buffers {
            guard let data = audioBuffer.mData else { continue }
            if (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && asbd.mBitsPerChannel == 32 {
                let samples = data.assumingMemoryBound(to: Float.self)
                let n = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                for i in stride(from: 0, to: n, by: max(1, n / 256)) { let v = Double(samples[i]); sum += v * v; count += 1 }
            } else if asbd.mBitsPerChannel == 16 {
                let samples = data.assumingMemoryBound(to: Int16.self)
                let n = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                for i in stride(from: 0, to: n, by: max(1, n / 256)) { let v = Double(samples[i]) / Double(Int16.max); sum += v * v; count += 1 }
            }
        }
        return count == 0 ? 0 : Float(min(1, sqrt(sum / Double(count)) * 4))
    }

    enum CaptureError: LocalizedError {
        case storageUnavailable, microphoneUnavailable, pickerCancelled, invalidState
        var errorDescription: String? {
            switch self {
            case .storageUnavailable: "Meeting storage is unavailable."
            case .microphoneUnavailable: "The microphone could not be started."
            case .pickerCancelled: "Application selection was cancelled."
            case .invalidState: "A meeting capture is already active."
            }
        }
    }
}

extension MacMeetingCaptureCoordinator: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            guard let continuation else { return }
            self.continuation = nil
            picker.isActive = false
            lifecycle.reset()
            state = .idle
            continuation.resume(throwing: CaptureError.pickerCancelled)
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            // Consume the one-shot continuation before `begin` suspends so a
            // second picker callback cannot start another capture concurrently.
            guard let continuation else { return }
            self.continuation = nil
            do {
                try await begin(filter: filter)
                continuation.resume()
            } catch {
                picker.isActive = false
                await cleanupAfterFailedBegin()
                state = .failed(error.localizedDescription)
                lifecycle.reset()
                continuation.resume(throwing: error)
            }
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            guard let continuation else { return }
            self.continuation = nil
            picker.isActive = false
            state = .failed(error.localizedDescription)
            lifecycle.reset()
            continuation.resume(throwing: error)
        }
    }
}

extension MacMeetingCaptureCoordinator: SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        receive(sampleBuffer, source: .system)
    }
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        receive(sampleBuffer, source: .microphone)
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard lifecycle.state == .recording, !didNotifyInterruption else { return }
            didNotifyInterruption = true
            let message = "System audio capture stopped: \(error.localizedDescription)"
            appendWarning(message)
            systemStatus = "Stopped"
            interruptionHandler?(message)
        }
    }
}

/// Owns writer references behind a lock because callbacks arrive on dedicated
/// queues while installation and teardown happen on the main actor.
private nonisolated final class MeetingTimelineClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CMTime?

    var value: CMTime? { lock.withLock { stored } }
    func set(_ value: CMTime) {
        lock.withLock {
            guard value.isValid, !value.isIndefinite else { return }
            stored = value
        }
    }
    func reset() { lock.withLock { stored = nil } }
}

private nonisolated func meetingSampleDuration(_ buffer: CMSampleBuffer) -> CMTime {
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

private nonisolated struct UncheckedSendableValue<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) { self.value = value }
}

private nonisolated struct MeetingWriterFinalizationResult: @unchecked Sendable {
    let chunk: MeetingCaptureChunk
    let events: [MeetingTimelineEvent]
    let warnings: [String]
}

private nonisolated final class MeetingManifestPersistence: @unchecked Sendable {
    private let queue = DispatchQueue(label: "VoxMeeting.manifest", qos: .utility)

    func submit(
        _ snapshot: MeetingCaptureManifest,
        to url: URL,
        completion: @escaping @Sendable (Error?) -> Void
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        queue.async {
            do {
                try data.write(to: url, options: .atomic)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func write(_ snapshot: MeetingCaptureManifest, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try submit(snapshot, to: url) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private nonisolated final class MeetingWriterFinalizationMailbox: @unchecked Sendable {
    private struct Entry {
        let identifier: UUID
        let result: MeetingWriterFinalizationResult
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func enqueue(_ result: MeetingWriterFinalizationResult) -> UUID {
        let identifier = UUID()
        lock.withLock { entries.append(.init(identifier: identifier, result: result)) }
        return identifier
    }

    func take(_ identifier: UUID) -> MeetingWriterFinalizationResult? {
        lock.withLock {
            guard let index = entries.firstIndex(where: { $0.identifier == identifier }) else { return nil }
            return entries.remove(at: index).result
        }
    }

    func drain() -> [MeetingWriterFinalizationResult] {
        lock.withLock {
            let results = entries.map(\.result)
            entries.removeAll()
            return results
        }
    }

    func reset() { lock.withLock { entries.removeAll() } }
}

private nonisolated final class MeetingWriterFinalizationResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MeetingAudioSource: MeetingWriterFinalizationResult] = [:]

    func set(_ value: MeetingWriterFinalizationResult?, for source: MeetingAudioSource) {
        guard let value else { return }
        lock.withLock { values[source] = value }
    }

    func snapshot() -> [MeetingAudioSource: MeetingWriterFinalizationResult] {
        lock.withLock { values }
    }
}

private nonisolated final class MeetingWriterState: @unchecked Sendable {
    private let lock = NSLock()
    private var system: ChunkedSampleBufferWriter?
    private var microphone: ChunkedSampleBufferWriter?

    func install(system: ChunkedSampleBufferWriter, microphone: ChunkedSampleBufferWriter) {
        lock.withLock { self.system = system; self.microphone = microphone }
    }

    func writer(for source: MeetingAudioSource) -> ChunkedSampleBufferWriter? {
        lock.withLock { source == .system ? system : microphone }
    }

    func snapshot() -> (system: ChunkedSampleBufferWriter?, microphone: ChunkedSampleBufferWriter?) {
        lock.withLock { (system, microphone) }
    }

    func reset() { lock.withLock { system = nil; microphone = nil } }
}

/// Queue-confined writer. All mutable state, including AVAssetWriter's async
/// completion, is consumed on `callbackQueue`. A bounded rollover buffer keeps
/// audio arriving during finalization without allowing stop to start an orphan
/// chunk.
private nonisolated final class ChunkedSampleBufferWriter: @unchecked Sendable {
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
    private let chunkDuration: Double = 30
    private let maximumRolloverBufferCount = 512
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
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

    init(
        source: MeetingAudioSource,
        directoryURL: URL,
        callbackQueue: DispatchQueue,
        timelineOrigin: @escaping @Sendable () -> CMTime?,
        finalized: @escaping @Sendable (MeetingCaptureChunk, [MeetingTimelineEvent], [String]) -> Void
    ) {
        self.source = source
        self.directoryURL = directoryURL
        self.callbackQueue = callbackQueue
        self.timelineOrigin = timelineOrigin
        self.finalized = finalized
    }

    func append(_ buffer: CMSampleBuffer) throws {
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
        if writer == nil {
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
        guard let input else { return }
        guard input.isReadyForMoreMediaData else {
            let dropped = max(0, CMTimeGetSeconds(duration))
            pendingEvents.append(.init(source: source, kind: .dropped, presentationTime: relativeTime(pts), duration: dropped))
            appendPendingWarning("\(sourceLabel) audio dropped because the writer could not keep up.")
            lastPTS = pts; lastDuration = duration
            return
        }
        if !input.append(buffer) { throw writer?.error ?? NSError(domain: "VoxMeetingWriter", code: 1) }
        hasAppendedSamples = true
        lastPTS = pts
        lastDuration = duration
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
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              let signature = formatSignature(for: buffer) else { throw NSError(domain: "VoxMeetingWriter", code: 2) }
        let url = directoryURL.appendingPathComponent("\(source.artifactRole.rawValue)-\(String(format: "%04d", index)).m4a")
        index += 1
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: chunkReceiptURL(for: url))
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: asbd.mSampleRate, AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame), AVEncoderBitRateKey: 128_000]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw NSError(domain: "VoxMeetingWriter", code: 3) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "VoxMeetingWriter", code: 4) }
        writer.startSession(atSourceTime: pts)
        let previousFormat = lastStartedFormatSignature
        self.writer = writer; self.input = input; chunkURL = url; chunkStart = pts
        currentFormatSignature = signature
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
        guard let writer, let input, let chunkURL, let chunkStart else { completion(nil); return }
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
        input.markAsFinished()
        let finalizingWriter = UncheckedSendableValue(writer)
        let callbackQueue = callbackQueue
        writer.finishWriting { [weak self] in
            callbackQueue.async { [weak self] in
                guard let self else { completion(nil); return }
                let writer = finalizingWriter.value
                let result: MeetingWriterFinalizationResult
                if writer.status == .completed,
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
                            warnings: warnings + ["\(self.sourceLabel) audio chunk recovery metadata could not be finalized."]
                        )
                    }
                } else {
                    try? FileManager.default.removeItem(at: chunkURL)
                    try? FileManager.default.removeItem(at: self.chunkReceiptURL(for: chunkURL))
                    let failure: String
                    if let receiptPreparationError {
                        failure = "\(self.sourceLabel) audio chunk recovery metadata could not be prepared: \(receiptPreparationError)."
                    } else {
                        failure = "\(self.sourceLabel) audio chunk could not be finalized."
                    }
                    result = MeetingWriterFinalizationResult(
                        chunk: .init(source: self.source, filename: chunkURL.lastPathComponent, startTime: 0, endTime: 0, byteCount: 0),
                        events: events,
                        warnings: warnings + [failure]
                    )
                }
                self.writer = nil; self.input = nil; self.chunkURL = nil; self.chunkStart = nil
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
        // no AVAssetWriterInput receives incompatible sample buffers.
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
                appendPendingWarning("\(sourceLabel) audio exceeded the bounded rollover buffer and was dropped.")
            }
        } catch {
            drainFailed = true
            appendPendingWarning("\(sourceLabel) audio could not start its next chunk: \(error.localizedDescription)")
            if writer == nil {
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

    func finish(completion: @escaping @Sendable (MeetingWriterFinalizationResult?) -> Void) {
        stopCompletions.append(completion)
        switch lifecycle.requestStop(hasCurrentChunk: writer != nil) {
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

    private var sourceLabel: String { source == .system ? "System" : "Microphone" }

    private func relativeTime(_ time: CMTime) -> TimeInterval {
        guard let origin = timelineOrigin() else { return 0 }
        let seconds = CMTimeGetSeconds(time - origin)
        return seconds.isFinite ? max(0, seconds) : 0
    }
}
