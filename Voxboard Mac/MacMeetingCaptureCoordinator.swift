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

    /// Identity of the capture session currently in flight (preparing,
    /// recording, or finalizing). Recovery scans must skip this session's
    /// directory: its manifest is still live and its chunks are still being
    /// written and finalized.
    struct ActiveSession: Equatable, Sendable {
        let sessionID: UUID
        let directoryURL: URL
    }

    /// The in-flight capture session, or `nil` when no capture is preparing,
    /// recording, or stopping. Directories left over from completed, failed, or
    /// interrupted sessions remain eligible for recovery.
    var activeSession: ActiveSession? {
        guard let directoryURL,
              state == .preparing || state == .recording || state == .stopping else { return nil }
        return ActiveSession(sessionID: sessionID, directoryURL: directoryURL)
    }

    private(set) var state: State = .idle
    private(set) var selectedApplicationName: String?
    private(set) var selectedApplicationBundleIdentifier: String?
    private(set) var microphoneLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var microphoneStatus = String(localized: "Waiting")
    private(set) var systemStatus = String(localized: "Waiting")
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
    /// Per-source one-shot interruption latches. A single shared latch
    /// swallowed the second stem's failure when both interrupted in the stop
    /// window; recording each source independently surfaces every warning.
    private var interruptedSources: Set<MeetingAudioSource> = []
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
        microphoneStatus = String(localized: "Waiting")
        systemStatus = String(localized: "Waiting")
        warnings.removeAll()
        interruptedSources.removeAll()
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
        selectedApplicationName = application?.applicationName ?? String(localized: "Selected application")
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
        systemStatus = String(localized: "Listening")
        microphoneStatus = String(localized: "Listening")
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
                self?.handleMicrophoneInterruption(String(localized: "Microphone capture was interrupted."))
            }
        })
        microphoneObservers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let detail = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
                ?? String(localized: "Unknown AVFoundation error")
            Task { @MainActor [weak self] in
                self?.handleMicrophoneInterruption(String(localized: "Microphone capture stopped: \(detail)"))
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
                self?.handleMicrophoneInterruption(String(localized: "The selected microphone was disconnected."))
            }
        })
    }

    private func clearMicrophoneObservers() {
        let center = NotificationCenter.default
        for observer in microphoneObservers { center.removeObserver(observer) }
        microphoneObservers.removeAll()
    }

    private func handleMicrophoneInterruption(_ message: String) {
        guard lifecycle.state == .recording, !interruptedSources.contains(.microphone) else { return }
        interruptedSources.insert(.microphone)
        appendWarning(message)
        microphoneStatus = String(localized: "Stopped")
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
        guard let directoryURL, var manifest else { state = .failed(String(localized: "Meeting storage is unavailable.")); return nil }
        if manifest.orderedChunks(for: .microphone).isEmpty { appendWarning(String(localized: "Microphone audio was not captured.")) }
        if manifest.orderedChunks(for: .system).isEmpty { appendWarning(String(localized: "The selected application produced no capturable audio.")) }
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
                    self?.appendWarning(String(localized: "Meeting recovery metadata could not be updated: \(error.localizedDescription)"))
                }
            }
        } catch {
            appendWarning(String(localized: "Meeting recovery metadata could not be updated: \(error.localizedDescription)"))
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
            if source == .system { systemLevel = level; systemStatus = String(localized: "Capturing") }
            else { microphoneLevel = level; microphoneStatus = String(localized: "Capturing") }
        }
        do {
            try writerState.writer(for: source)?.append(sampleBuffer)
        } catch {
            Task { @MainActor [weak self] in
                let label = source == .system ? String(localized: "System") : String(localized: "Microphone")
                self?.appendWarning(String(localized: "\(label) audio could not be preserved: \(error.localizedDescription)"))
                if source == .system { self?.systemStatus = String(localized: "Error") } else { self?.microphoneStatus = String(localized: "Error") }
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
            case .storageUnavailable: String(localized: "Meeting storage is unavailable.")
            case .microphoneUnavailable: String(localized: "The microphone could not be started.")
            case .pickerCancelled: String(localized: "Application selection was cancelled.")
            case .invalidState: String(localized: "A meeting capture is already active.")
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
            guard lifecycle.state == .recording, !interruptedSources.contains(.system) else { return }
            interruptedSources.insert(.system)
            let message = String(localized: "System audio capture stopped: \(error.localizedDescription)")
            appendWarning(message)
            systemStatus = String(localized: "Stopped")
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

