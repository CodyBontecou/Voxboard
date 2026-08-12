import Foundation
import VoxboardCaptureCore

public extension Notification.Name {
    static let captureInboxDecisionRequired = Notification.Name(
        "VoxboardCaptureInboxDecisionRequired"
    )
    static let captureInboxDecisionResolved = Notification.Name(
        "VoxboardCaptureInboxDecisionResolved"
    )
}

public enum TranscriptCaptureAdapter {
    /// Unified Capture destinations receive the processed transcript body, just
    /// like typed Capture text. Standalone transcript-file exports own any
    /// document-level wrappers such as dated headings or body hashtags.
    public static func payloads(
        transcript: Transcript,
        flow: CapturePreset,
        audioAsset: CaptureAssetReference?
    ) -> [CapturePayload] {
        let body: String
        if let cleanedText = transcript.cleanedText, !cleanedText.isEmpty {
            body = cleanedText
        } else {
            body = transcript.text
        }
        var payloads: [CapturePayload] = [.text(body)]
        if let audioAsset, flow.audioSaveMode != .off {
            let embedPlacement: CaptureAudioEmbedPlacement
            if !flow.exportSettings.embedAudioInMarkdown {
                embedPlacement = .none
            } else {
                embedPlacement = flow.exportSettings.audioEmbedPlacement == .top ? .top : .bottom
            }
            payloads.append(.retainedAudio(audioAsset, embedPlacement: embedPlacement))
        }
        return payloads
    }

    public static func frontmatter(
        transcript: Transcript,
        flow: CapturePreset
    ) -> [String: String] {
        var metadata = flow.staticFrontmatter
        if let title = transcript.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            metadata["title"] = title
        }
        if let tags = transcript.tags, !tags.isEmpty {
            metadata["tags"] = "[" + tags.joined(separator: ", ") + "]"
        }
        if let category = transcript.category?.trimmingCharacters(in: .whitespacesAndNewlines),
           !category.isEmpty,
           metadata["category"] == nil,
           metadata["type"] == nil {
            metadata["category"] = category
        }
        return metadata
    }
}

/// Routes a voice transcript through the same precise, coordinated Markdown
/// pipeline as typed, widget, Shortcut, and share-sheet captures.
public struct TranscriptCaptureDestinationExporter {
    private let pipeline: CapturePipeline
    private let fileManager: FileManager

    public init(
        pipeline: CapturePipeline = AppCapturePipeline.shared,
        fileManager: FileManager = .default
    ) {
        self.pipeline = pipeline
        self.fileManager = fileManager
    }

    public func export(
        transcript: Transcript,
        flow: CapturePreset,
        destination: CaptureDestination,
        destinationRootURL: URL,
        stagingDirectoryURL: URL,
        audioSourceURL: URL?,
        locationOutcome: CaptureLocationOutcome?,
        source: CaptureSource = .voice
    ) async throws -> CaptureReceipt {
        try ConfiguredTranscriptCaptureDestinationExporter.enforceUnavailableCancellation(
            flow: flow,
            locationOutcome: locationOutcome
        )
        let audioAsset: CaptureAssetReference?
        if let audioSourceURL, flow.audioSaveMode != .off {
            audioAsset = try await CaptureAssetStager(directoryURL: stagingDirectoryURL).stageCopy(
                from: audioSourceURL,
                preferredFilename: audioSourceURL.lastPathComponent,
                contentTypeIdentifier: Self.audioContentType(forExtension: audioSourceURL.pathExtension)
            )
        } else {
            audioAsset = nil
        }
        defer { try? fileManager.removeItem(at: stagingDirectoryURL) }

        let routedDestination = Self.routedDestination(destination, for: flow)
        let request = CaptureRequest(
            source: source,
            deliveryKind: .meteredVoiceTranscript,
            destinationID: routedDestination.id,
            payloads: TranscriptCaptureAdapter.payloads(
                transcript: transcript,
                flow: flow,
                audioAsset: audioAsset
            ),
            frontmatter: TranscriptCaptureAdapter.frontmatter(transcript: transcript, flow: flow),
            voxProfile: flow.captureProfile,
            voxProcessingState: .applied,
            locationOutcome: locationOutcome
        )
        return try await pipeline.capture(
            request,
            destination: routedDestination,
            rootURL: destinationRootURL,
            assetRootURL: stagingDirectoryURL
        )
    }

    fileprivate static func routedDestination(
        _ destination: CaptureDestination,
        for flow: CapturePreset
    ) -> CaptureDestination {
        var routed = destination
        if let placement = flow.capturePlacementOverride {
            routed.placement = placement
        }
        if let override = attachmentFolderOverride(for: flow) {
            routed.attachmentsFolderName = override
        }
        return routed
    }

    fileprivate static func attachmentFolderOverride(for flow: CapturePreset) -> String? {
        switch flow.audioSaveMode {
        case .off:
            return nil
        case .alongsideTranscript:
            return ""
        case .attachmentsFolder:
            let folder = flow.attachmentsFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
            return folder.isEmpty ? nil : folder
        }
    }

    fileprivate static func audioContentType(forExtension pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "m4a", "mp4": return "public.mpeg-4-audio"
        case "mp3": return "public.mp3"
        case "aif", "aiff": return "public.aiff-audio"
        default: return "com.microsoft.waveform-audio"
        }
    }
}

public enum ConfiguredTranscriptCaptureError: Error, LocalizedError, Sendable {
    case storageUnavailable
    case destinationMissing(UUID)
    case staleDestination(String)
    case audioPreparationFailed
    case requestPreparationFailed
    case locationUnavailableCancelled
    case queuedForRetry(String)

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return "Shared capture storage is unavailable."
        case .destinationMissing:
            return "This Capture Preset’s destination no longer exists. Open Capture destination or Settings to configure it again."
        case .staleDestination(let name):
            return "The Files permission for ‘\(name)’ expired. Edit the capture destination and choose its folder again."
        case .audioPreparationFailed:
            return "The retained audio could not be prepared for capture. The original recording was kept for retry."
        case .requestPreparationFailed:
            return "The voice note could not be prepared for capture. The local transcript and recording were kept for retry."
        case .locationUnavailableCancelled:
            return "The Capture was cancelled because its preset requires an origin-time location. The local transcript was kept."
        case .queuedForRetry(let message):
            return "The voice note is queued for retry because its destination could not be written: \(message)"
        }
    }
}

public enum ConfiguredTranscriptCaptureDestinationExporter {
    /// Resolves a direct voice run through the same route precedence as every
    /// other capture. Legacy voice export remains the fallback when no Capture
    /// destination has been configured yet.
    public static func resolvedDestinationID(
        flow: CapturePreset,
        captureRootURL: URL? = AppConstants.captureDirectoryURL,
        defaults: UserDefaults? = AppConstants.sharedDefaults
    ) async -> UUID? {
        guard let captureRootURL else { return nil }
        let store = CaptureLibraryStore(
            fileURL: captureRootURL.appendingPathComponent(CaptureLibraryStore.defaultFilename)
        )
        guard let library = try? await CapturePresetRouteLibrary.load(
            from: store,
            defaults: defaults
        ) else { return nil }
        let hasOwnedRoutes = CapturePresetProfileStore.hasOwnedRouteMigration(defaults: defaults)
        // `flow` is the caller's immutable recording-time snapshot. Reloading
        // the preset here would let edits from another window reroute audio
        // after recording has already started.
        var profile = flow.captureProfile
        if !hasOwnedRoutes, profile.captureDestinationID == nil {
            profile.captureDestinationID = library.legacyFlowBindings[flow.id]
        }
        return CapturePresetRouteResolver.destinationID(
            selectionMode: .inherited,
            explicitDestinationID: nil,
            profile: profile,
            destinations: library.destinations,
            libraryDefaultDestinationID: library.defaultDestinationID,
            allowsLegacyFallback: !hasOwnedRoutes
        )
    }

    public static func export(
        transcript: Transcript,
        flow: CapturePreset,
        destinationID: UUID,
        audioSourceURL: URL?,
        locationOutcome: CaptureLocationOutcome?,
        source: CaptureSource = .voice,
        captureRootURL: URL? = AppConstants.captureDirectoryURL,
        pipeline: CapturePipeline = AppCapturePipeline.shared,
        fileManager: FileManager = .default
    ) async throws -> CaptureReceipt {
        try enforceUnavailableCancellation(flow: flow, locationOutcome: locationOutcome)
        guard let captureRootURL else { throw ConfiguredTranscriptCaptureError.storageUnavailable }

        // Transcript identity is the capture idempotency key. Re-entering the
        // export path for the same saved transcript can never append it twice.
        let requestID = transcript.id
        let relativeStagingDirectory = "inbox-staging/\(requestID.uuidString.lowercased())"
        let stagingDirectoryURL = captureRootURL.appendingPathComponent(relativeStagingDirectory, isDirectory: true)
        var audioAsset: CaptureAssetReference?
        if flow.audioSaveMode != .off {
            guard let audioSourceURL else {
                throw ConfiguredTranscriptCaptureError.audioPreparationFailed
            }
            do {
                let staged = try await CaptureAssetStager(directoryURL: stagingDirectoryURL).stageCopy(
                    from: audioSourceURL,
                    preferredFilename: audioSourceURL.lastPathComponent,
                    contentTypeIdentifier: TranscriptCaptureDestinationExporter.audioContentType(
                        forExtension: audioSourceURL.pathExtension
                    )
                )
                audioAsset = try CaptureAssetReference(
                    relativePath: "\(relativeStagingDirectory)/\(staged.relativePath)",
                    originalFilename: staged.originalFilename,
                    contentTypeIdentifier: staged.contentTypeIdentifier,
                    byteCount: staged.byteCount
                )
            } catch {
                // Never construct a reduced transcript-only retry. The caller
                // keeps its retained source until a complete audio request has
                // been durably staged and enqueued.
                try? fileManager.removeItem(at: stagingDirectoryURL)
                throw ConfiguredTranscriptCaptureError.audioPreparationFailed
            }
        }

        let payloads = TranscriptCaptureAdapter.payloads(
            transcript: transcript,
            flow: flow,
            audioAsset: audioAsset
        )
        let request = CaptureRequest(
            id: requestID,
            createdAt: transcript.date,
            source: source,
            deliveryKind: .meteredVoiceTranscript,
            destinationID: destinationID,
            payloads: payloads,
            frontmatter: TranscriptCaptureAdapter.frontmatter(transcript: transcript, flow: flow),
            voxProfile: flow.captureProfile,
            voxProcessingState: .applied,
            locationOutcome: locationOutcome,
            attachmentsFolderNameOverride: TranscriptCaptureDestinationExporter
                .attachmentFolderOverride(for: flow)
        )

        return try await deliver(
            request,
            flow: flow,
            captureRootURL: captureRootURL,
            stagingDirectoryURL: stagingDirectoryURL,
            pipeline: pipeline,
            fileManager: fileManager
        )
    }

    /// Captures a retained voice recording as a first-class audio payload and
    /// deliberately omits transcription text. The Watch inbox remains the
    /// source of truth until this durable Capture request completes.
    public static func exportRecording(
        requestID: UUID,
        createdAt: Date,
        flow: CapturePreset,
        destinationID: UUID,
        audioSourceURL: URL,
        preferredFilename: String? = nil,
        locationOutcome: CaptureLocationOutcome?,
        source: CaptureSource = .watch,
        captureRootURL: URL? = AppConstants.captureDirectoryURL,
        pipeline: CapturePipeline = AppCapturePipeline.shared,
        fileManager: FileManager = .default
    ) async throws -> CaptureReceipt {
        try enforceUnavailableCancellation(flow: flow, locationOutcome: locationOutcome)
        guard let captureRootURL else { throw ConfiguredTranscriptCaptureError.storageUnavailable }

        let relativeStagingDirectory = "inbox-staging/\(requestID.uuidString.lowercased())"
        let stagingDirectoryURL = captureRootURL.appendingPathComponent(
            relativeStagingDirectory,
            isDirectory: true
        )
        let audioAsset: CaptureAssetReference
        do {
            let staged = try await CaptureAssetStager(directoryURL: stagingDirectoryURL).stageCopy(
                from: audioSourceURL,
                preferredFilename: preferredFilename ?? audioSourceURL.lastPathComponent,
                contentTypeIdentifier: TranscriptCaptureDestinationExporter.audioContentType(
                    forExtension: audioSourceURL.pathExtension
                )
            )
            audioAsset = try CaptureAssetReference(
                relativePath: "\(relativeStagingDirectory)/\(staged.relativePath)",
                originalFilename: staged.originalFilename,
                contentTypeIdentifier: staged.contentTypeIdentifier,
                byteCount: staged.byteCount
            )
        } catch {
            try? fileManager.removeItem(at: stagingDirectoryURL)
            throw ConfiguredTranscriptCaptureError.audioPreparationFailed
        }

        let request = CaptureRequest(
            id: requestID,
            createdAt: createdAt,
            source: source,
            deliveryKind: .standard,
            destinationID: destinationID,
            payloads: [.audio(audioAsset, transcript: nil)],
            frontmatter: flow.staticFrontmatter,
            voxProfile: flow.captureProfile,
            voxProcessingState: .applied,
            locationOutcome: locationOutcome,
            attachmentsFolderNameOverride: TranscriptCaptureDestinationExporter
                .attachmentFolderOverride(for: flow)
        )
        return try await deliver(
            request,
            flow: flow,
            captureRootURL: captureRootURL,
            stagingDirectoryURL: stagingDirectoryURL,
            pipeline: pipeline,
            fileManager: fileManager
        )
    }

    fileprivate static func enforceUnavailableCancellation(
        flow: CapturePreset,
        locationOutcome: CaptureLocationOutcome?
    ) throws {
        guard flow.locationPolicy.isEnabled,
              flow.locationPolicy.unavailableBehavior == .cancel else { return }
        guard case .available = locationOutcome else {
            throw ConfiguredTranscriptCaptureError.locationUnavailableCancelled
        }
    }

    private static func deliver(
        _ request: CaptureRequest,
        flow: CapturePreset,
        captureRootURL: URL,
        stagingDirectoryURL: URL,
        pipeline: CapturePipeline,
        fileManager: FileManager
    ) async throws -> CaptureReceipt {
        let inbox = CaptureInbox(rootDirectoryURL: captureRootURL)
        let history = CaptureHistoryStore(
            fileURL: captureRootURL.appendingPathComponent(AppConstants.captureHistoryFilename)
        )
        do {
            // Persist before any bookmark resolution or destination write.
            // A crash after claiming is recovered from the processing lease,
            // while the stable request ID makes replay idempotent.
            try await inbox.enqueue(request)
        } catch {
            throw ConfiguredTranscriptCaptureError.storageUnavailable
        }

        var didClaimRequest = false
        var destinationName = "Unavailable destination"
        do {
            guard try await inbox.claim(requestID: request.id) != nil else {
                throw ConfiguredTranscriptCaptureError.queuedForRetry(
                    "This capture is already queued or being delivered."
                )
            }
            didClaimRequest = true
            let libraryStore = CaptureLibraryStore(
                fileURL: captureRootURL.appendingPathComponent(CaptureLibraryStore.defaultFilename)
            )
            let library = try await CapturePresetRouteLibrary.load(from: libraryStore)
            guard let storedDestination = library.destinations.first(where: { $0.id == request.destinationID }) else {
                throw ConfiguredTranscriptCaptureError.destinationMissing(request.destinationID)
            }
            var destination = library.resolvedDestination(
                storedDestination,
                overrideEntryTemplateID: flow.captureEntryTemplateID
            )
            if let placement = flow.capturePlacementOverride {
                destination.placement = placement
            }
            destinationName = destination.name

            let rootResolution = try CaptureBookmarkResolver.resolve(destination.rootBookmark)
            let destinationRootURL = rootResolution.url
            guard !rootResolution.isStale else {
                throw ConfiguredTranscriptCaptureError.staleDestination(destination.name)
            }
            let didAccess = destinationRootURL.startAccessingSecurityScopedResource()
            defer { if didAccess { destinationRootURL.stopAccessingSecurityScopedResource() } }

            let receipt = try await pipeline.capture(
                request,
                destination: TranscriptCaptureDestinationExporter.routedDestination(destination, for: flow),
                rootURL: destinationRootURL,
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
                destinationName: destinationName,
                voxID: request.voxReference?.id,
                voxName: request.voxReference?.name,
                relativeNotePath: CaptureHistoryRecord.relativeNotePath(
                    noteURL: receipt.noteURL,
                    rootURL: destinationRootURL
                ),
                attachmentCount: receipt.attachmentURLs.count
            ) {
                _ = await history.upsertBestEffort(record)
            }
            try? fileManager.removeItem(at: stagingDirectoryURL)
            return receipt
        } catch {
            if let pipelineError = error as? CapturePipelineError,
               case .locationDecisionRequired = pipelineError {
                if didClaimRequest { try? await inbox.returnToPending(requestID: request.id) }
                NotificationCenter.default.post(name: .captureInboxDecisionRequired, object: request.id)
                throw ConfiguredTranscriptCaptureError.queuedForRetry(
                    "Location was unavailable. Open Vox.md to send without location or discard this exact capture."
                )
            }
            // Preserve the exact idempotency key and any staged bytes. Failed
            // direct delivery returns the claimed request to pending so app
            // and macOS inbox drains can retry it without user content loss.
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
                attachmentCount: historyAttachmentCount(in: request),
                failureCategory: historyFailureCategory(for: error)
            ) {
                _ = await history.upsertBestEffort(record)
            }
            if didClaimRequest {
                try? await inbox.fail(requestID: request.id)
                _ = try? await inbox.retryFailed(requestID: request.id)
            }
            if let configured = error as? ConfiguredTranscriptCaptureError,
               case .queuedForRetry = configured {
                throw configured
            }
            throw ConfiguredTranscriptCaptureError.queuedForRetry(error.localizedDescription)
        }
    }

    private static func historyAttachmentCount(in request: CaptureRequest) -> Int {
        request.payloads.reduce(into: 0) { count, payload in
            switch payload {
            case .text, .url: break
            case .audio, .retainedAudio, .image, .file: count += 1
            case .scannedDocument(let pages, let pdf, _):
                count += pages.count + (pdf == nil ? 0 : 1)
            case .sketch: count += 2
            }
        }
    }

    private static func historyFailureCategory(for error: Error) -> CaptureHistoryFailureCategory {
        switch error {
        case is ConfiguredTranscriptCaptureError, is CaptureVaultMarkdownTemplateError:
            return .destinationUnavailable
        case is CaptureAttachmentError:
            return .attachment
        case is CaptureModelError, is CapturePipelineError:
            return .invalidRequest
        default:
            return .fileWrite
        }
    }
}
