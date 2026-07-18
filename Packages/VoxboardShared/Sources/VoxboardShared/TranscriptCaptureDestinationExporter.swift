import Foundation
import VoxboardCaptureCore

public enum TranscriptCaptureAdapter {
    public static func payloads(
        transcript: Transcript,
        flow: RecordingFlow,
        audioAsset: CaptureAssetReference?
    ) throws -> [CapturePayload] {
        let configuration = TranscriptExportConfiguration(
            format: .md,
            mode: .append,
            mdObsidianEnabled: true,
            enrichmentOptions: .default,
            staticFrontmatter: [:]
        )
        let markdown = try TranscriptFileExporter.exportKitRenderedContent(
            transcript,
            configuration: configuration
        )
        var payloads: [CapturePayload] = [.text(removingLeadingFrontmatter(from: markdown))]
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
        flow: RecordingFlow
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

    private static func removingLeadingFrontmatter(from markdown: String) -> String {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---",
              let closing = lines.indices.dropFirst().first(where: { lines[$0] == "---" }) else {
            return markdown
        }
        guard closing + 1 < lines.count else { return "" }
        return lines[(closing + 1)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
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
        flow: RecordingFlow,
        destination: CaptureDestination,
        destinationRootURL: URL,
        stagingDirectoryURL: URL,
        audioSourceURL: URL?
    ) async throws -> CaptureReceipt {
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
            source: .voice,
            destinationID: routedDestination.id,
            payloads: try TranscriptCaptureAdapter.payloads(
                transcript: transcript,
                flow: flow,
                audioAsset: audioAsset
            ),
            frontmatter: TranscriptCaptureAdapter.frontmatter(transcript: transcript, flow: flow),
            voxProfile: flow.captureProfile,
            voxProcessingState: .applied
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
        for flow: RecordingFlow
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

    fileprivate static func attachmentFolderOverride(for flow: RecordingFlow) -> String? {
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
    case queuedForRetry(String)

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return "Shared capture storage is unavailable."
        case .destinationMissing:
            return "The Vox capture destination no longer exists. Choose another destination in the Vox settings."
        case .staleDestination(let name):
            return "The Files permission for ‘\(name)’ expired. Edit the capture destination and choose its folder again."
        case .audioPreparationFailed:
            return "The retained audio could not be prepared for capture. The original recording was kept for retry."
        case .requestPreparationFailed:
            return "The voice note could not be prepared for capture. The local transcript and recording were kept for retry."
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
        flow: RecordingFlow,
        captureRootURL: URL? = AppConstants.captureDirectoryURL
    ) async -> UUID? {
        guard let captureRootURL else { return nil }
        let store = CaptureLibraryStore(
            fileURL: captureRootURL.appendingPathComponent(CaptureLibraryStore.defaultFilename)
        )
        guard let library = try? await store.load() else { return nil }
        if !library.legacyFlowBindings.isEmpty {
            RecordingFlowStore.migrateLegacyCaptureBindings(library.legacyFlowBindings)
            try? await store.save(library)
        }
        var profile = flow.captureProfile
        if profile.captureDestinationID == nil {
            profile.captureDestinationID = library.legacyFlowBindings[flow.id]
        }
        return CaptureVoxRouteResolver.destinationID(
            selectionMode: .inherited,
            explicitDestinationID: nil,
            profile: profile,
            destinations: library.destinations,
            libraryDefaultDestinationID: library.defaultDestinationID
        )
    }

    public static func export(
        transcript: Transcript,
        flow: RecordingFlow,
        destinationID: UUID,
        audioSourceURL: URL?,
        captureRootURL: URL? = AppConstants.captureDirectoryURL,
        pipeline: CapturePipeline = AppCapturePipeline.shared,
        fileManager: FileManager = .default
    ) async throws -> CaptureReceipt {
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

        let payloads: [CapturePayload]
        do {
            payloads = try TranscriptCaptureAdapter.payloads(
                transcript: transcript,
                flow: flow,
                audioAsset: audioAsset
            )
        } catch {
            try? fileManager.removeItem(at: stagingDirectoryURL)
            throw ConfiguredTranscriptCaptureError.requestPreparationFailed
        }
        let request = CaptureRequest(
            id: requestID,
            source: .voice,
            destinationID: destinationID,
            payloads: payloads,
            frontmatter: TranscriptCaptureAdapter.frontmatter(transcript: transcript, flow: flow),
            voxProfile: flow.captureProfile,
            voxProcessingState: .applied,
            attachmentsFolderNameOverride: TranscriptCaptureDestinationExporter
                .attachmentFolderOverride(for: flow)
        )

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
                    "This transcript is already queued or being delivered."
                )
            }
            didClaimRequest = true
            let library = try await CaptureLibraryStore(
                fileURL: captureRootURL.appendingPathComponent(CaptureLibraryStore.defaultFilename)
            ).load()
            guard let storedDestination = library.destinations.first(where: { $0.id == destinationID }) else {
                throw ConfiguredTranscriptCaptureError.destinationMissing(destinationID)
            }
            var destination = library.resolvedDestination(
                storedDestination,
                overrideEntryTemplateID: flow.captureEntryTemplateID
            )
            if let placement = flow.capturePlacementOverride {
                destination.placement = placement
            }
            destinationName = destination.name

            var isStale = false
            let destinationRootURL = try URL(
                resolvingBookmarkData: destination.rootBookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard !isStale else {
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
}
