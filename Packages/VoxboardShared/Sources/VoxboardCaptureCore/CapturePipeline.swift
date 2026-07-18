import Foundation

public enum CapturePipelineError: Error, Equatable, LocalizedError, Sendable {
    case destinationMismatch(expected: UUID, actual: UUID)
    case unsafeNotePath(String)

    public var errorDescription: String? {
        switch self {
        case .destinationMismatch(let expected, let actual):
            return "Capture destination mismatch. Expected \(expected.uuidString), received \(actual.uuidString)."
        case .unsafeNotePath(let path):
            return "The capture note path resolved outside its destination: \(path)"
        }
    }
}

public enum CaptureDeliveryQuotaError: Error, Equatable, LocalizedError, Sendable {
    case limitReached(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .limitReached(let limit):
            return "You've used all \(limit) free captures. Unlock Vox.md Unlimited to keep capturing."
        }
    }
}

/// A durable claim on one free Capture delivery. Accounting implementations
/// use request IDs for idempotency and tokens so one failed duplicate cannot
/// release another caller's in-flight reservation.
public enum CaptureDeliveryReservation: Equatable, Sendable {
    case bypassed(requestID: UUID)
    case alreadyCounted(requestID: UUID)
    case reserved(requestID: UUID, token: UUID)

    public var requestID: UUID {
        switch self {
        case .bypassed(let requestID),
             .alreadyCounted(let requestID),
             .reserved(let requestID, _):
            return requestID
        }
    }
}

public protocol CaptureDeliveryAccounting: Sendable {
    func reserve(for request: CaptureRequest) async throws -> CaptureDeliveryReservation
    func commit(_ reservation: CaptureDeliveryReservation) async throws
    func release(_ reservation: CaptureDeliveryReservation) async
}

/// Core and isolated tests remain unmetered unless a production accounting
/// implementation is explicitly injected.
public struct UnmeteredCaptureDeliveryAccounting: CaptureDeliveryAccounting {
    public init() {}

    public func reserve(for request: CaptureRequest) async throws -> CaptureDeliveryReservation {
        .bypassed(requestID: request.id)
    }

    public func commit(_ reservation: CaptureDeliveryReservation) async throws {}
    public func release(_ reservation: CaptureDeliveryReservation) async {}
}

public struct CaptureReceipt: Equatable, Sendable {
    public var requestID: UUID
    public var destinationID: UUID
    public var noteURL: URL
    public var attachmentURLs: [URL]
    public var writeReceipt: CaptureWriteReceipt

    public init(
        requestID: UUID,
        destinationID: UUID,
        noteURL: URL,
        attachmentURLs: [URL],
        writeReceipt: CaptureWriteReceipt
    ) {
        self.requestID = requestID
        self.destinationID = destinationID
        self.noteURL = noteURL
        self.attachmentURLs = attachmentURLs
        self.writeReceipt = writeReceipt
    }
}

public actor CapturePipeline {
    /// One process-wide pipeline serializes note-path allocation and attachment
    /// transactions across typed, voice, deep-link, and inbox captures.
    public static let shared = CapturePipeline()

    private let pathPlanner: CapturePathPlanner
    private let renderer: CaptureMarkdownRenderer
    private let attachmentWriter: CaptureAttachmentWriter
    private let templateRenderer: CaptureEntryTemplateRenderer
    private let writer: any CaptureMutationWriting
    private let fileManager: FileManager
    private let deliveryAccounting: any CaptureDeliveryAccounting

    public init(
        pathPlanner: CapturePathPlanner = CapturePathPlanner(),
        renderer: CaptureMarkdownRenderer = CaptureMarkdownRenderer(),
        attachmentWriter: CaptureAttachmentWriter = CaptureAttachmentWriter(),
        templateRenderer: CaptureEntryTemplateRenderer? = nil,
        writer: any CaptureMutationWriting = CoordinatedCaptureWriter(),
        fileManager: FileManager = .default,
        deliveryAccounting: any CaptureDeliveryAccounting = UnmeteredCaptureDeliveryAccounting()
    ) {
        self.pathPlanner = pathPlanner
        self.renderer = renderer
        self.attachmentWriter = attachmentWriter
        self.templateRenderer = templateRenderer ?? CaptureEntryTemplateRenderer(calendar: pathPlanner.calendar)
        self.writer = writer
        self.fileManager = fileManager
        self.deliveryAccounting = deliveryAccounting
    }

    public func capture(
        _ request: CaptureRequest,
        destination: CaptureDestination,
        rootURL: URL,
        assetRootURL: URL? = nil
    ) async throws -> CaptureReceipt {
        await CapturePipelineGate.shared.acquire()

        let reservation: CaptureDeliveryReservation
        do {
            reservation = try await deliveryAccounting.reserve(for: request)
        } catch {
            await CapturePipelineGate.shared.release()
            throw error
        }

        if case .alreadyCounted(let requestID) = reservation {
            // Accounting commits happen only after a verified destination
            // write. A committed ID is therefore an idempotency receipt, not
            // permission to mutate the destination again. This remains true
            // even when user-facing HTML retry markers are disabled.
            let receipt = alreadyCountedReceipt(
                requestID: requestID,
                request: request,
                destination: destination,
                rootURL: rootURL
            )
            await CapturePipelineGate.shared.release()
            return receipt
        }

        let receipt: CaptureReceipt
        do {
            receipt = try await captureLocked(
                request,
                destination: destination,
                rootURL: rootURL,
                assetRootURL: assetRootURL
            )
        } catch {
            await deliveryAccounting.release(reservation)
            await CapturePipelineGate.shared.release()
            throw error
        }

        do {
            // A verified destination write is the only success boundary. If
            // final accounting fails, retain the reservation so a retry with
            // the same stable request ID can finish without opening a slot.
            try await deliveryAccounting.commit(reservation)
            await CapturePipelineGate.shared.release()
            return receipt
        } catch {
            await CapturePipelineGate.shared.release()
            throw error
        }
    }

    private func captureLocked(
        _ request: CaptureRequest,
        destination: CaptureDestination,
        rootURL: URL,
        assetRootURL: URL?
    ) async throws -> CaptureReceipt {
        guard request.destinationID == destination.id else {
            throw CapturePipelineError.destinationMismatch(
                expected: destination.id,
                actual: request.destinationID
            )
        }

        var effectiveDestination = destination
        if let folderOverride = request.attachmentsFolderNameOverride {
            effectiveDestination.attachmentsFolderName = folderOverride
        }

        let relativeNotePath = try availableNotePath(
            for: request,
            destination: effectiveDestination,
            rootURL: rootURL
        )
        let noteURL = try containedNoteURL(relativePath: relativeNotePath, root: rootURL)
        let attachments = try attachmentWriter.copyAttachments(
            for: request,
            destination: effectiveDestination,
            destinationRootURL: rootURL,
            assetRootURL: assetRootURL
        )

        do {
            let entry = try renderer.render(
                request,
                for: effectiveDestination,
                attachmentPaths: attachments.attachmentPaths
            )
            let mutation = MarkdownCaptureMutation(
                requestID: request.id,
                entry: entry,
                placement: effectiveDestination.placement,
                entryPrefix: templateRenderer.render(effectiveDestination.entryPrefix, for: request),
                entrySuffix: templateRenderer.render(effectiveDestination.entrySuffix, for: request),
                frontmatter: request.voxProfile?.metadataScope == .entry ? [:] : request.frontmatter,
                retryProtectionEnabled: effectiveDestination.retryProtectionEnabled,
                destinationRootURL: rootURL,
                relativeNotePath: relativeNotePath
            )
            let writeReceipt = try await writer.write(mutation, to: noteURL)
            return CaptureReceipt(
                requestID: request.id,
                destinationID: destination.id,
                noteURL: noteURL,
                attachmentURLs: attachments.attachmentURLs,
                writeReceipt: writeReceipt
            )
        } catch {
            attachments.rollback(fileManager: fileManager)
            throw error
        }
    }

    private func alreadyCountedReceipt(
        requestID: UUID,
        request: CaptureRequest,
        destination: CaptureDestination,
        rootURL: URL
    ) -> CaptureReceipt {
        let relativePath = request.relativeNotePathOverride
            ?? (try? pathPlanner.relativePath(for: request, destination: destination))
        let noteURL = relativePath.flatMap {
            try? containedNoteURL(relativePath: $0, root: rootURL)
        } ?? rootURL
        let byteCount = (try? Data(contentsOf: noteURL).count) ?? 0
        let writeReceipt = CaptureWriteReceipt(
            fileURL: noteURL,
            requestID: requestID,
            byteCount: byteCount,
            wasAlreadyApplied: true
        )
        return CaptureReceipt(
            requestID: requestID,
            destinationID: destination.id,
            noteURL: noteURL,
            attachmentURLs: [],
            writeReceipt: writeReceipt
        )
    }

    private func availableNotePath(
        for request: CaptureRequest,
        destination: CaptureDestination,
        rootURL: URL
    ) throws -> String {
        guard case .newNote = destination.noteTarget else {
            return try pathPlanner.relativePath(for: request, destination: destination)
        }

        var existing: Set<String> = []
        while true {
            let candidate = try pathPlanner.relativePath(
                for: request,
                destination: destination,
                existingRelativePaths: existing
            )
            let candidateURL = try containedNoteURL(relativePath: candidate, root: rootURL)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidate
            }
            if let content = try? String(contentsOf: candidateURL, encoding: .utf8),
               CaptureRequestMarker.isPresent(in: content, requestID: request.id) {
                return candidate
            }
            existing.insert(candidate)
        }
    }

    private func containedNoteURL(relativePath: String, root: URL) throws -> URL {
        do {
            return try CapturePathValidation.containedFileURL(
                relativePath: relativePath,
                rootURL: root
            )
        } catch {
            throw CapturePipelineError.unsafeNotePath(relativePath)
        }
    }
}

private actor CapturePipelineGate {
    static let shared = CapturePipelineGate()

    private var isAcquired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isAcquired {
            isAcquired = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isAcquired = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
