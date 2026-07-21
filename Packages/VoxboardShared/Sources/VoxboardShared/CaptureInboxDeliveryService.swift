import Foundation
import VoxboardCaptureCore

public struct CaptureInboxDeliveryResult: Sendable {
    public var receipts: [CaptureReceipt]
    public var failedRequestIDs: [UUID]
    public var quotaBlockedRequestIDs: [UUID]
    public var setupError: String?

    public init(
        receipts: [CaptureReceipt] = [],
        failedRequestIDs: [UUID] = [],
        quotaBlockedRequestIDs: [UUID] = [],
        setupError: String? = nil
    ) {
        self.receipts = receipts
        self.failedRequestIDs = failedRequestIDs
        self.quotaBlockedRequestIDs = quotaBlockedRequestIDs
        self.setupError = setupError
    }
}

/// Shared app-side delivery for durable capture requests. Both iOS and macOS
/// can drain the same App Group inbox without duplicating bookmark, template,
/// orphan-route, or retry behavior.
public enum CaptureInboxDeliveryService {
    public static func drain(
        captureRootURL: URL,
        retryFailed: Bool = false,
        staleProcessingTimeout: TimeInterval = 5 * 60,
        completedRetention: TimeInterval = 7 * 24 * 60 * 60,
        defaults: UserDefaults? = AppConstants.sharedDefaults,
        pipeline: CapturePipeline = AppCapturePipeline.shared,
        requestProcessor: CapturePresetRequestProcessor = CapturePresetRequestProcessor(),
        coordinator: any CaptureFileCoordinating = NSFileCoordinatorCaptureFileCoordinator.shared
    ) async -> CaptureInboxDeliveryResult {
        let inbox = CaptureInbox(rootDirectoryURL: captureRootURL, coordinator: coordinator)
        let history = CaptureHistoryStore(
            fileURL: captureRootURL.appendingPathComponent(AppConstants.captureHistoryFilename),
            coordinator: coordinator
        )
        let library: CaptureLibraryEnvelope
        do {
            let libraryStore = CaptureLibraryStore(
                fileURL: captureRootURL.appendingPathComponent(CaptureLibraryStore.defaultFilename),
                coordinator: coordinator
            )
            library = try await CapturePresetRouteLibrary.load(
                from: libraryStore,
                defaults: defaults
            )
            _ = try await inbox.recoverStaleProcessing(olderThan: staleProcessingTimeout)
            _ = try await inbox.purgeCompleted(olderThan: completedRetention)
            _ = try await inbox.purgeOrphanedStaging(olderThan: 24 * 60 * 60)

            if let replacementID = validDefaultDestinationID(in: library) {
                let rerouted = try await inbox.rerouteOrphanedRequests(
                    validDestinationIDs: Set(library.destinations.map(\.id)),
                    to: replacementID,
                    states: [.pending, .failed]
                )
                for requestID in rerouted {
                    _ = try await inbox.retryFailed(requestID: requestID)
                }
            }
            if retryFailed {
                _ = try await inbox.retryAllFailed()
            }
        } catch {
            return CaptureInboxDeliveryResult(setupError: error.localizedDescription)
        }

        var receipts: [CaptureReceipt] = []
        var failures: [UUID] = []
        var quotaBlocked: [UUID] = []
        do {
            while let claimedRequest = try await inbox.claimNext(
                excludingRequestIDs: Set(quotaBlocked)
            ) {
                var request = claimedRequest
                do {
                    if request.voxProcessingState == .pending {
                        request = await requestProcessor.process(request)
                        try await inbox.replaceProcessingRequest(request)
                    }
                    guard let storedDestination = library.destinations.first(where: {
                        $0.id == request.destinationID
                    }) else {
                        throw ConfiguredTranscriptCaptureError.destinationMissing(request.destinationID)
                    }
                    var destination = library.resolvedDestination(
                        storedDestination,
                        overrideEntryTemplateID: request.entryTemplateIDOverride
                            ?? request.voxProfile?.captureEntryTemplateID
                    )
                    if let relativePath = request.relativeNotePathOverride {
                        try CapturePathValidation.validateRelativePath(relativePath)
                        destination.noteTarget = .existingNote(relativePath: relativePath)
                    }
                    if let placement = request.placementOverride
                        ?? request.voxProfile?.capturePlacementOverride {
                        destination.placement = placement
                    }
                    if let attachmentsFolderName = request.attachmentsFolderNameOverride {
                        destination.attachmentsFolderName = attachmentsFolderName
                    }
                    let rootResolution = try CaptureBookmarkResolver.resolve(destination.rootBookmark)
                    let rootURL = rootResolution.url
                    guard !rootResolution.isStale else {
                        throw ConfiguredTranscriptCaptureError.staleDestination(destination.name)
                    }
                    let didAccess = rootURL.startAccessingSecurityScopedResource()
                    defer { if didAccess { rootURL.stopAccessingSecurityScopedResource() } }
                    let receipt = try await pipeline.capture(
                        request,
                        destination: destination,
                        rootURL: rootURL,
                        assetRootURL: captureRootURL
                    )
                    try await inbox.complete(requestID: request.id)
                    if let record = try? CaptureHistoryRecord(
                        requestID: request.id,
                        createdAt: request.createdAt,
                        deliveredAt: Date(),
                        source: request.source,
                        outcome: .delivered,
                        destinationID: request.destinationID,
                        destinationName: destination.name,
                        voxID: request.voxReference?.id,
                        voxName: request.voxReference?.name,
                        relativeNotePath: CaptureHistoryRecord.relativeNotePath(
                            noteURL: receipt.noteURL,
                            rootURL: rootURL
                        ),
                        attachmentCount: receipt.attachmentURLs.count
                    ) {
                        _ = await history.upsertBestEffort(record)
                    }
                    receipts.append(receipt)
                } catch let error as CaptureDeliveryQuotaError {
                    try? await inbox.returnToPending(requestID: request.id)
                    if case .limitReached = error {
                        quotaBlocked.append(request.id)
                    }
                    // Skip this request for the rest of this drain, but keep
                    // scanning: later metered-voice requests still bypass the
                    // Capture quota and must not be starved by an older item.
                    continue
                } catch {
                    let destinationName = library.destinations.first(where: {
                        $0.id == request.destinationID
                    })?.name ?? "Unavailable destination"
                    if let record = try? CaptureHistoryRecord(
                        requestID: request.id,
                        createdAt: request.createdAt,
                        deliveredAt: Date(),
                        source: request.source,
                        outcome: .failed,
                        destinationID: request.destinationID,
                        destinationName: destinationName,
                        voxID: request.voxReference?.id,
                        voxName: request.voxReference?.name,
                        relativeNotePath: nil,
                        attachmentCount: attachmentCount(in: request),
                        failureCategory: failureCategory(for: error)
                    ) {
                        _ = await history.upsertBestEffort(record)
                    }
                    try? await inbox.fail(requestID: request.id)
                    failures.append(request.id)
                }
            }
        } catch {
            return CaptureInboxDeliveryResult(
                receipts: receipts,
                failedRequestIDs: failures,
                quotaBlockedRequestIDs: quotaBlocked,
                setupError: error.localizedDescription
            )
        }
        return CaptureInboxDeliveryResult(
            receipts: receipts,
            failedRequestIDs: failures,
            quotaBlockedRequestIDs: quotaBlocked
        )
    }

    private static func attachmentCount(in request: CaptureRequest) -> Int {
        request.payloads.reduce(into: 0) { count, payload in
            switch payload {
            case .text, .url:
                break
            case .audio, .retainedAudio, .image, .file:
                count += 1
            case .scannedDocument(let pages, let pdf, _):
                count += pages.count + (pdf == nil ? 0 : 1)
            case .sketch:
                count += 2
            }
        }
    }

    private static func failureCategory(for error: Error) -> CaptureHistoryFailureCategory {
        switch error {
        case is ConfiguredTranscriptCaptureError:
            return .destinationUnavailable
        case is CaptureAttachmentError:
            return .attachment
        case is CaptureModelError, is CapturePipelineError:
            return .invalidRequest
        default:
            return .fileWrite
        }
    }

    private static func validDefaultDestinationID(in library: CaptureLibraryEnvelope) -> UUID? {
        if let defaultID = library.defaultDestinationID,
           library.destinations.contains(where: { $0.id == defaultID }) {
            return defaultID
        }
        return library.destinations.first?.id
    }
}
