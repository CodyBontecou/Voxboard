import Foundation
import Observation
import UniformTypeIdentifiers
import VoxboardShared

@MainActor
@Observable
final class QuickCaptureViewModel {
    var draft = CaptureDraft()
    var destinations: [CaptureDestination] = []
    var entryTemplates: [CaptureEntryTemplate] = []
    var voxProfiles: [CapturePresetProfile] = CapturePresetProfileStore.enabledProfiles(
        defaults: AppConstants.sharedDefaults
    )
    var defaultDestinationID: UUID?
    var isLoading = false
    var isSubmitting = false
    var errorMessage: String?
    var lastReceipt: CaptureReceipt?
    var failedInboxCount = 0
    var historyRecords: [CaptureHistoryRecord] = []
    var requestedInput: CaptureRequestedInput?
    var needsCaptureUnlock = false

    private let captureRootURL: URL?
    private let libraryStore: CaptureLibraryStore?
    private let draftStore: CaptureDraftStore?
    private let historyStore: CaptureHistoryStore?
    private let pipeline: CapturePipeline
    private let requestProcessor: CapturePresetRequestProcessor
    private var pendingDraftSave: Task<Void, Never>?
    private var initialLoadTask: Task<Bool, Never>?
    private var hasLoaded = false
    private var pendingCaptureSource: CaptureSource?
    private var pendingVoxID: String?
    private var liveRecordedTranscriptPreview: LiveTranscriptDraftPreview?

    init(
        captureRootURL: URL? = AppConstants.captureDirectoryURL,
        requestProcessor: CapturePresetRequestProcessor = CapturePresetRequestProcessor()
    ) {
        self.captureRootURL = captureRootURL
        if let captureRootURL {
            self.libraryStore = CaptureLibraryStore(
                fileURL: captureRootURL.appendingPathComponent(AppConstants.captureLibraryFilename)
            )
            self.draftStore = CaptureDraftStore(rootDirectoryURL: captureRootURL)
            self.historyStore = CaptureHistoryStore(
                fileURL: captureRootURL.appendingPathComponent(AppConstants.captureHistoryFilename)
            )
        } else {
            self.libraryStore = nil
            self.draftStore = nil
            self.historyStore = nil
        }
        self.pipeline = AppCapturePipeline.shared
        self.requestProcessor = requestProcessor
    }

    var selectedVoxProfile: CapturePresetProfile? {
        let enabled = voxProfiles.filter(\.isEnabled)
        if let voxID = draft.voxID,
           let selected = enabled.first(where: { $0.id == voxID }) {
            return selected
        }
        let selectedID = CapturePresetProfileStore.selectedProfileID(defaults: AppConstants.sharedDefaults)
        return enabled.first(where: { $0.id == selectedID }) ?? enabled.first
    }

    var effectiveDestinationID: UUID? {
        CapturePresetRouteResolver.destinationID(
            selectionMode: draft.destinationSelectionMode,
            explicitDestinationID: draft.destinationID,
            profile: selectedVoxProfile,
            destinations: destinations,
            libraryDefaultDestinationID: defaultDestinationID,
            allowsLegacyFallback: !CapturePresetProfileStore.hasOwnedRouteMigration(
                defaults: AppConstants.sharedDefaults
            )
        )
    }

    var selectedDestination: CaptureDestination? {
        guard let id = effectiveDestinationID else { return nil }
        return destinations.first { $0.id == id }
    }

    var hasExplicitDestinationOverride: Bool {
        draft.destinationSelectionMode == .explicit && draft.destinationID != nil
    }

    var resolvedDestinationPreview: String? {
        guard var destination = selectedDestination,
              let destinationID = effectiveDestinationID,
              let request = try? draft.makeRequest(
                source: .app,
                resolvedDestinationID: destinationID,
                voxProfile: selectedVoxProfile
              ) else { return nil }
        if let override = draft.relativeNotePathOverride {
            destination.noteTarget = .existingNote(relativePath: override)
        }
        guard let relativePath = try? CapturePathPlanner().relativePath(
            for: request,
            destination: destination
        ) else { return nil }
        return destination.rootName + " / " + relativePath
    }

    var effectivePlacementLabel: String {
        switch draft.placementOverride
            ?? selectedVoxProfile?.capturePlacementOverride
            ?? selectedDestination?.placement {
        case .prepend: return String(localized: "Top")
        case .append: return String(localized: "Bottom")
        case .beneathHeading: return String(localized: "Heading")
        case nil: return String(localized: "Default")
        }
    }

    var canSubmit: Bool {
        !isSubmitting
            && selectedDestination != nil
            && draft.hasCaptureContent
    }

    func load() async {
        if hasLoaded { return }
        if let initialLoadTask {
            _ = await initialLoadTask.value
            return
        }
        let task = Task { @MainActor [self] in
            await performInitialLoad()
        }
        initialLoadTask = task
        let didLoad = await task.value
        hasLoaded = didLoad
        initialLoadTask = nil
    }

    /// Performs the only destructive restoration of the observable draft.
    /// `load()` serializes all cold-launch callers around this operation so a
    /// deep link cannot race the view task and have its incoming content
    /// replaced by a second disk load.
    private func performInitialLoad() async -> Bool {
        guard let libraryStore, let draftStore else {
            errorMessage = String(localized: "Shared capture storage is unavailable. Reinstall Vox.md or verify its App Group entitlement.")
            return false
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let library = try await CapturePresetRouteLibrary.load(from: libraryStore)
            destinations = library.destinations
            entryTemplates = library.entryTemplates
            defaultDestinationID = library.defaultDestinationID
            refreshVoxProfiles()
            if let savedDraft = try await draftStore.loadAll().first {
                draft = savedDraft
            } else {
                draft = CaptureDraft(
                    voxID: CapturePresetProfileStore.selectedProfileID(defaults: AppConstants.sharedDefaults),
                    destinationSelectionMode: .inherited
                )
            }
            if draft.voxID == nil || !voxProfiles.contains(where: { $0.id == draft.voxID && $0.isEnabled }) {
                draft.voxID = CapturePresetProfileStore.selectedProfileID(defaults: AppConstants.sharedDefaults)
            }
            if draft.destinationSelectionMode == .explicit {
                let inheritedDestinationID = selectedVoxProfile?.captureDestinationID
                if !draft.inheritDestinationIfEquivalent(to: inheritedDestinationID),
                   (draft.destinationID == nil || !destinations.contains(where: { $0.id == draft.destinationID })) {
                    draft.useInheritedDestination()
                }
            }
            if let templateID = draft.entryTemplateID,
               !entryTemplates.contains(where: { $0.id == templateID }) {
                draft.entryTemplateID = nil
            }
            if let pendingCaptureSource {
                draft.captureSource = pendingCaptureSource
                self.pendingCaptureSource = nil
            }
            if let pendingVoxID,
               voxProfiles.contains(where: { $0.id == pendingVoxID && $0.isEnabled }) {
                draft.selectVox(pendingVoxID)
                self.pendingVoxID = nil
            }
            try await draftStore.save(draft)
            historyRecords = (try? await historyStore?.list()) ?? []
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func requestCaptureSource(_ source: CaptureSource) {
        if hasLoaded {
            draft.captureSource = source
            scheduleDraftSave()
        } else {
            pendingCaptureSource = source
        }
    }

    func requestVox(_ id: String) {
        if hasLoaded {
            refreshVoxProfiles()
            selectVox(id)
        } else {
            pendingVoxID = id
        }
    }

    func refreshHistory() async {
        historyRecords = (try? await historyStore?.list()) ?? []
    }

    func clearHistory() async {
        do {
            try await historyStore?.clear()
            historyRecords = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshVoxProfiles() {
        voxProfiles = CapturePresetProfileStore.enabledProfiles(defaults: AppConstants.sharedDefaults)
        if let current = draft.voxID,
           voxProfiles.contains(where: { $0.id == current && $0.isEnabled }) {
            return
        }
        draft.voxID = CapturePresetProfileStore.selectedProfileID(defaults: AppConstants.sharedDefaults)
    }

    func selectVox(_ id: String) {
        guard voxProfiles.contains(where: { $0.id == id && $0.isEnabled }) else { return }
        draft.selectVox(id)
        CapturePresetProfileStore.selectCaptureProfile(id: id, defaults: AppConstants.sharedDefaults)
        scheduleDraftSave()
    }

    func selectDestination(_ id: UUID) {
        guard destinations.contains(where: { $0.id == id }) else { return }
        draft.selectDestination(id)
        scheduleDraftSave()
    }

    func useVoxRouteDefaults() {
        draft.useInheritedDestination()
        draft.placementOverride = nil
        draft.entryTemplateID = nil
        scheduleDraftSave()
    }

    func setPlacementOverride(_ placement: CapturePlacement?) {
        draft.placementOverride = placement
        scheduleDraftSave()
    }

    func clearRouteOverrides() {
        draft.relativeNotePathOverride = nil
        draft.placementOverride = nil
        draft.entryTemplateID = nil
        scheduleDraftSave()
    }

    var hasAnyRouteOverride: Bool {
        hasExplicitDestinationOverride
            || draft.relativeNotePathOverride != nil
            || draft.placementOverride != nil
            || draft.entryTemplateID != nil
    }

    func selectedRootURL() -> URL? {
        guard let destination = selectedDestination else { return nil }
        return try? Self.resolveRootURL(for: destination)
    }

    func setOneOffNote(url: URL) async {
        guard let destination = selectedDestination else {
            errorMessage = QuickCaptureViewModelError.unknownDestination.localizedDescription
            return
        }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            guard url.pathExtension.lowercased() == "md" else {
                throw QuickCaptureViewModelError.noteMustBeMarkdown
            }
            let rootURL = try Self.resolveRootURL(for: destination)
            let rootPath = rootURL.standardizedFileURL.path
            let candidatePath = url.standardizedFileURL.path
            let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard candidatePath.hasPrefix(rootPrefix) else {
                throw QuickCaptureViewModelError.noteOutsideDestination
            }
            let relativePath = String(candidatePath.dropFirst(rootPrefix.count))
            _ = try CapturePathValidation.containedFileURL(
                relativePath: relativePath,
                rootURL: rootURL
            )
            draft.relativeNotePathOverride = relativePath
            try await draftStore?.save(draft)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func scheduleDraftSave() {
        pendingDraftSave?.cancel()
        pendingDraftSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            await self.saveDraftNow()
        }
    }

    func saveDraftNow() async {
        guard let draftStore else { return }
        draft.updatedAt = Date()
        do {
            try await draftStore.save(draft)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var hasLiveRecordedTranscriptPreview: Bool {
        liveRecordedTranscriptPreview != nil
    }

    func updateLiveRecordedTranscript(
        finalizedText: String,
        volatileText: String?
    ) async {
        await load()
        var preview = liveRecordedTranscriptPreview ?? LiveTranscriptDraftPreview()
        let updatedText = preview.render(
            finalizedText: finalizedText,
            volatileText: volatileText,
            in: draft.text
        )
        guard updatedText.count <= CaptureInputLimits.maximumTextCharacters else {
            errorMessage = QuickCaptureViewModelError.textTooLarge.localizedDescription
            return
        }

        // Keep volatile recognition in memory. The durable draft is saved only
        // when Apple Speech finalizes, so a crash cannot persist tentative words.
        liveRecordedTranscriptPreview = preview
        draft.text = updatedText
        draft.updatedAt = Date()
    }

    func cancelLiveRecordedTranscript() async {
        guard var preview = liveRecordedTranscriptPreview else { return }
        let restoredText = preview.cancel(in: draft.text)
        liveRecordedTranscriptPreview = nil
        draft.text = restoredText
        await saveDraftNow()
    }

    @discardableResult
    func appendRecordedTranscript(_ text: String) async -> Bool {
        await load()
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        let previousDraft = draft
        let previousPreview = liveRecordedTranscriptPreview
        let updatedText: String
        if var preview = liveRecordedTranscriptPreview {
            updatedText = preview.commit(normalized, in: draft.text)
        } else {
            let separator = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n"
            updatedText = draft.text + separator + normalized
        }
        guard updatedText.count <= CaptureInputLimits.maximumTextCharacters else {
            errorMessage = QuickCaptureViewModelError.textTooLarge.localizedDescription
            return false
        }

        liveRecordedTranscriptPreview = nil
        draft.text = updatedText
        // The recorder adds transcription seconds only after a successful
        // result. Mark this durable request so sending it does not consume a
        // second, independent Capture allowance.
        draft.deliveryKind = .meteredVoiceTranscript
        draft.updatedAt = Date()
        do {
            try await draftStore?.save(draft)
            errorMessage = nil
            return true
        } catch {
            draft = previousDraft
            liveRecordedTranscriptPreview = previousPreview
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func stageRecordedAudio(at sourceURL: URL) async -> CaptureAssetReference? {
        await load()
        guard let stagingDirectory = stagingDirectoryURL else {
            errorMessage = QuickCaptureViewModelError.storageUnavailable.localizedDescription
            return nil
        }
        let stager = CaptureAssetStager(directoryURL: stagingDirectory)
        var stagedAsset: CaptureAssetReference?
        do {
            let sourceExtension = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension.lowercased()
            let contentType = UTType(filenameExtension: sourceExtension)?.identifier ?? UTType.audio.identifier
            let asset = try await stager.stageCopy(
                from: sourceURL,
                preferredFilename: "Recording-\(Self.captureFilenameTimestamp()).\(sourceExtension)",
                contentTypeIdentifier: contentType
            )
            stagedAsset = asset
            try await appendStagedPayload(.audio(asset, transcript: nil), using: stager)
            errorMessage = nil
            return asset
        } catch {
            if let stagedAsset { try? await stager.remove(stagedAsset) }
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func stageImage(
        data: Data,
        filename: String,
        contentTypeIdentifier: String,
        altText: String? = nil
    ) async {
        await stageAsset { stager in
            let asset = try await stager.stage(
                data: data,
                preferredFilename: filename,
                contentTypeIdentifier: contentTypeIdentifier
            )
            return .image(asset, altText: altText)
        }
    }

    func stageFile(
        at sourceURL: URL,
        filename: String? = nil,
        contentTypeIdentifier: String,
        embedAsImage: Bool = false,
        embedAsAudio: Bool = false
    ) async {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        await stageAsset { stager in
            let asset = try await stager.stageCopy(
                from: sourceURL,
                preferredFilename: filename,
                contentTypeIdentifier: contentTypeIdentifier
            )
            if embedAsImage { return .image(asset, altText: nil) }
            if embedAsAudio { return .audio(asset, transcript: nil) }
            return .file(asset)
        }
    }

    @discardableResult
    func stageVoiceRecording(at sourceURL: URL, transcript: String?) async -> CaptureAssetReference? {
        guard let stagingDirectory = stagingDirectoryURL else {
            errorMessage = QuickCaptureViewModelError.storageUnavailable.localizedDescription
            return nil
        }
        let stager = CaptureAssetStager(directoryURL: stagingDirectory)
        var stagedAsset: CaptureAssetReference?
        do {
            try Task.checkCancellation()
            let filename = "Recording-\(Self.captureFilenameTimestamp()).m4a"
            let asset = try await stager.stageCopy(
                from: sourceURL,
                preferredFilename: filename,
                contentTypeIdentifier: "public.mpeg-4-audio"
            )
            stagedAsset = asset
            try Task.checkCancellation()
            try await appendStagedPayload(.audio(asset, transcript: transcript), using: stager)
            errorMessage = nil
            return asset
        } catch is CancellationError {
            if let stagedAsset { try? await stager.remove(stagedAsset) }
            return nil
        } catch {
            if let stagedAsset { try? await stager.remove(stagedAsset) }
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func updateStagedVoiceRecording(
        _ asset: CaptureAssetReference,
        transcript: String?
    ) async -> Bool {
        guard let index = draft.additionalPayloads.firstIndex(where: { payload in
            guard case .audio(let candidate, _) = payload else { return false }
            return candidate == asset
        }) else { return false }
        let previous = draft.additionalPayloads[index]
        draft.additionalPayloads[index] = .audio(asset, transcript: transcript)
        do {
            try await draftStore?.save(draft)
            errorMessage = nil
            return true
        } catch {
            draft.additionalPayloads[index] = previous
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func removeStagedVoiceRecording(_ asset: CaptureAssetReference) async -> Bool {
        guard let index = draft.additionalPayloads.firstIndex(where: { payload in
            guard case .audio(let candidate, _) = payload else { return false }
            return candidate == asset
        }) else { return true }
        await removePayload(at: index)
        return !draft.additionalPayloads.contains { payload in
            guard case .audio(let candidate, _) = payload else { return false }
            return candidate == asset
        }
    }

    func stageScan(pageImages: [Data], pdfData: Data?, extractedText: String?) async {
        guard let stagingDirectory = stagingDirectoryURL else {
            errorMessage = QuickCaptureViewModelError.storageUnavailable.localizedDescription
            return
        }
        let stager = CaptureAssetStager(directoryURL: stagingDirectory)
        var newlyStaged: [CaptureAssetReference] = []
        do {
            var pages: [CaptureAssetReference] = []
            for (index, data) in pageImages.enumerated() {
                let page = try await stager.stage(
                    data: data,
                    preferredFilename: "scan-page-\(index + 1).jpg",
                    contentTypeIdentifier: "public.jpeg"
                )
                pages.append(page)
                newlyStaged.append(page)
            }
            let pdf: CaptureAssetReference?
            if let pdfData {
                let stagedPDF = try await stager.stage(
                    data: pdfData,
                    preferredFilename: "scan.pdf",
                    contentTypeIdentifier: "com.adobe.pdf"
                )
                pdf = stagedPDF
                newlyStaged.append(stagedPDF)
            } else {
                pdf = nil
            }
            try await appendStagedPayload(
                .scannedDocument(pages: pages, pdf: pdf, extractedText: extractedText),
                using: stager
            )
            errorMessage = nil
        } catch {
            for asset in newlyStaged { try? await stager.remove(asset) }
            errorMessage = error.localizedDescription
        }
    }

    func stageSketch(drawingData: Data, previewData: Data, altText: String? = nil) async {
        guard let stagingDirectory = stagingDirectoryURL else {
            errorMessage = QuickCaptureViewModelError.storageUnavailable.localizedDescription
            return
        }
        let stager = CaptureAssetStager(directoryURL: stagingDirectory)
        var newlyStaged: [CaptureAssetReference] = []
        do {
            let drawing = try await stager.stage(
                data: drawingData,
                preferredFilename: "sketch.drawing",
                contentTypeIdentifier: "com.apple.pencilkit.drawing"
            )
            newlyStaged.append(drawing)
            let preview = try await stager.stage(
                data: previewData,
                preferredFilename: "sketch.png",
                contentTypeIdentifier: "public.png"
            )
            newlyStaged.append(preview)
            try await appendStagedPayload(
                .sketch(drawing: drawing, preview: preview, altText: altText),
                using: stager
            )
            errorMessage = nil
        } catch {
            for asset in newlyStaged { try? await stager.remove(asset) }
            errorMessage = error.localizedDescription
        }
    }

    func addURL(_ url: URL, title: String? = nil) async {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            errorMessage = String(localized: "Enter a complete http:// or https:// link.")
            return
        }
        draft.additionalPayloads.append(.url(url, title: title))
        await saveDraftNow()
    }

    func removePayload(at index: Int) async {
        guard draft.additionalPayloads.indices.contains(index), let draftStore else { return }
        let pendingSave = pendingDraftSave
        pendingDraftSave = nil
        pendingSave?.cancel()
        await pendingSave?.value

        let payload = draft.additionalPayloads.remove(at: index)
        draft.updatedAt = Date()
        do {
            // Persist the removed reference before deleting bytes. If saving
            // fails, the durable draft still points at a valid staged file.
            try await draftStore.save(draft)
        } catch {
            draft.additionalPayloads.insert(payload, at: index)
            errorMessage = error.localizedDescription
            return
        }

        if let stagingDirectory = stagingDirectoryURL {
            let stager = CaptureAssetStager(directoryURL: stagingDirectory)
            for asset in Self.assets(in: payload) {
                do {
                    try await stager.remove(asset)
                } catch {
                    // The draft no longer references this file. Keep the
                    // capture valid and surface cleanup failure for retry via
                    // normal draft completion directory cleanup.
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func submit() async {
        guard draft.text.count <= CaptureInputLimits.maximumTextCharacters else {
            errorMessage = QuickCaptureViewModelError.textTooLarge.localizedDescription
            return
        }
        guard attachmentsFitInputBudget(draft.additionalPayloads) else {
            errorMessage = QuickCaptureViewModelError.assetsTooLarge.localizedDescription
            return
        }
        guard let captureRootURL, let libraryStore, let draftStore else {
            errorMessage = String(localized: "Shared capture storage is unavailable.")
            return
        }
        guard canSubmit else { return }

        isSubmitting = true
        errorMessage = nil
        let pendingSave = pendingDraftSave
        pendingDraftSave = nil
        pendingSave?.cancel()
        await pendingSave?.value
        let submittedDraft = draft
        let submittedVoxProfile = selectedVoxProfile
        guard let submittedDestinationID = effectiveDestinationID else {
            isSubmitting = false
            errorMessage = CaptureDraftError.destinationRequired.localizedDescription
            return
        }
        do {
            try await draftStore.save(submittedDraft)
            let submittedDraftID = submittedDraft.id
            let pipeline = self.pipeline
            let requestProcessor = self.requestProcessor
            let receipt = try await draftStore.submit(draftID: submittedDraftID) { draft in
                let library = try await libraryStore.load()
                guard let storedDestination = library.destinations.first(where: {
                    $0.id == submittedDestinationID
                }) else {
                    throw CaptureDraftError.destinationRequired
                }
                var destination = library.resolvedDestination(
                    storedDestination,
                    overrideEntryTemplateID: draft.entryTemplateID
                        ?? submittedVoxProfile?.captureEntryTemplateID
                )
                if let override = draft.placementOverride
                    ?? submittedVoxProfile?.capturePlacementOverride {
                    destination.placement = override
                }
                if let noteOverride = draft.relativeNotePathOverride {
                    try CapturePathValidation.validateRelativePath(noteOverride)
                    guard noteOverride.lowercased().hasSuffix(".md") else {
                        throw QuickCaptureViewModelError.noteMustBeMarkdown
                    }
                    destination.noteTarget = .existingNote(relativePath: noteOverride)
                }
                let request: CaptureRequest
                if let prepared = try await draftStore.loadPreparedRequest(draftID: draft.id),
                   prepared.id == draft.requestID,
                   prepared.originDraftUpdatedAt == draft.updatedAt,
                   prepared.destinationID == submittedDestinationID,
                   prepared.voxProfile == submittedVoxProfile,
                   prepared.voxProcessingState != .pending {
                    request = prepared
                } else {
                    let unresolved = try draft.makeRequest(
                        source: .app,
                        resolvedDestinationID: submittedDestinationID,
                        voxProfile: submittedVoxProfile
                    )
                    let processed = await requestProcessor.process(unresolved)
                    try await draftStore.savePreparedRequest(processed, draftID: draft.id)
                    request = processed
                }
                let rootURL = try Self.resolveRootURL(for: destination)
                let didAccess = rootURL.startAccessingSecurityScopedResource()
                defer { if didAccess { rootURL.stopAccessingSecurityScopedResource() } }
                let stagingURL = captureRootURL
                    .appendingPathComponent("staging", isDirectory: true)
                    .appendingPathComponent(draft.id.uuidString.lowercased(), isDirectory: true)
                return try await pipeline.capture(
                    request,
                    destination: destination,
                    rootURL: rootURL,
                    assetRootURL: stagingURL
                )
            }

            lastReceipt = receipt
            needsCaptureUnlock = false
            try? await draftStore.removePreparedRequest(draftID: submittedDraftID)
            let library = try await libraryStore.load()
            if let request = try? submittedDraft.makeRequest(
                source: .app,
                resolvedDestinationID: submittedDestinationID,
                voxProfile: submittedVoxProfile
            ) {
                await recordHistory(
                    request: request,
                    destinationName: library.destinations.first(where: { $0.id == request.destinationID })?.name
                        ?? String(localized: "Deleted destination"),
                    relativeNotePath: submittedDraft.relativeNotePathOverride
                        ?? historyRelativeNotePath(for: receipt, destinationID: request.destinationID),
                    attachmentCount: receipt.attachmentURLs.count,
                    outcome: .delivered,
                    failureCategory: nil
                )
            }
            if let concurrentlyEdited = try await draftStore.load(id: submittedDraftID) {
                let rebased = concurrentlyEdited.rebased(afterSubmitting: submittedDraft)
                if rebased.hasCaptureContent {
                    draft = rebased
                    try await draftStore.save(rebased)
                } else {
                    try await draftStore.complete(draftID: submittedDraftID)
                    draft = CaptureDraft(
                        voxID: submittedVoxProfile?.id,
                        destinationSelectionMode: .inherited
                    )
                    try await draftStore.save(draft)
                }
            } else {
                draft = CaptureDraft(
                    voxID: submittedVoxProfile?.id,
                    destinationSelectionMode: .inherited
                )
                try await draftStore.save(draft)
            }
            destinations = library.destinations
            entryTemplates = library.entryTemplates
        } catch let error as CaptureDeliveryQuotaError {
            if case .limitReached = error {
                needsCaptureUnlock = true
                errorMessage = nil
            }
        } catch {
            if let request = try? submittedDraft.makeRequest(
                source: .app,
                resolvedDestinationID: submittedDestinationID,
                voxProfile: submittedVoxProfile
            ) {
                await recordHistory(
                    request: request,
                    destinationName: destinations.first(where: { $0.id == request.destinationID })?.name
                        ?? String(localized: "Unavailable destination"),
                    relativeNotePath: submittedDraft.relativeNotePathOverride,
                    attachmentCount: request.payloads.flatMap(Self.assets(in:)).count,
                    outcome: .failed,
                    failureCategory: Self.historyFailureCategory(for: error)
                )
            }
            errorMessage = error.localizedDescription
        }
        isSubmitting = false
    }

    func handleDeepLink(_ action: CaptureDeepLinkAction) async {
        do {
            if destinations.isEmpty { await load() }
            switch action {
            case .openComposer(let incoming):
                draft.captureSource = incoming.source ?? .deepLink
                if let voxID = incoming.voxID {
                    refreshVoxProfiles()
                    guard voxProfiles.contains(where: { $0.id == voxID && $0.isEnabled }) else {
                        throw QuickCaptureViewModelError.unknownVox
                    }
                    draft.selectVox(voxID)
                    CapturePresetProfileStore.selectCaptureProfile(
                        id: voxID,
                        defaults: AppConstants.sharedDefaults
                    )
                }
                if let destinationID = incoming.destinationID {
                    guard destinations.contains(where: { $0.id == destinationID }) else {
                        throw QuickCaptureViewModelError.unknownDestination
                    }
                    draft.selectDestination(destinationID)
                }
                if let text = incoming.text, !text.isEmpty {
                    let separator = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n"
                    draft.text += separator + text
                }
                if let url = incoming.url {
                    draft.additionalPayloads.append(.url(url, title: nil))
                }
                requestedInput = incoming.requestedInput
                try await draftStore?.save(draft)

            case .processInboxRequest(let requestID):
                try await processInboxRequest(id: requestID)
            }
            errorMessage = nil
        } catch let error as CaptureDeliveryQuotaError {
            if case .limitReached = error {
                needsCaptureUnlock = true
                errorMessage = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func processPendingInbox() async {
        guard let captureRootURL else { return }
        let inbox = CaptureInbox(rootDirectoryURL: captureRootURL)
        do {
            _ = try await inbox.recoverStaleProcessing(olderThan: 5 * 60)
            try await recoverOrphanedInboxRequests(in: inbox)
            _ = try await inbox.purgeCompleted(olderThan: 7 * 24 * 60 * 60)
            _ = try await inbox.purgeOrphanedStaging(olderThan: 24 * 60 * 60)
            var latestFailure: Error?
            var quotaBlockedRequestIDs = Set<UUID>()
            while let request = try await inbox.claimNext(
                excludingRequestIDs: quotaBlockedRequestIDs
            ) {
                do {
                    try await processClaimedInboxRequest(request, inbox: inbox)
                } catch let error as CaptureDeliveryQuotaError {
                    if case .limitReached = error {
                        needsCaptureUnlock = true
                    }
                    // Keep this request pending, skip it for this drain, and
                    // continue so a later metered-voice request is not starved.
                    quotaBlockedRequestIDs.insert(request.id)
                    continue
                } catch {
                    latestFailure = error
                    // One broken destination must not block unrelated shared captures.
                    continue
                }
            }
            failedInboxCount = try await inbox.requestIDs(in: .failed).count
            if let latestFailure {
                errorMessage = String(localized: "A shared capture could not be delivered and is queued for retry. \(latestFailure.localizedDescription)")
            }
        } catch {
            errorMessage = error.localizedDescription
            failedInboxCount = (try? await inbox.requestIDs(in: .failed).count) ?? failedInboxCount
        }
    }

    func retryFailedInbox() async {
        guard let captureRootURL, let libraryStore else { return }
        let inbox = CaptureInbox(rootDirectoryURL: captureRootURL)
        do {
            let library = try await libraryStore.load()
            let replacementID = library.defaultDestinationID.flatMap { defaultID in
                library.destinations.contains(where: { $0.id == defaultID }) ? defaultID : nil
            } ?? library.destinations.first?.id
            if let replacementID {
                _ = try await inbox.rerouteOrphanedRequests(
                    validDestinationIDs: Set(library.destinations.map(\.id)),
                    to: replacementID,
                    states: [.failed]
                )
            }
            _ = try await inbox.retryAllFailed()
            failedInboxCount = 0
            await processPendingInbox()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var stagingDirectoryURL: URL? {
        captureRootURL?
            .appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(draft.id.uuidString.lowercased(), isDirectory: true)
    }

    private func stageAsset(
        _ operation: (CaptureAssetStager) async throws -> CapturePayload
    ) async {
        guard let stagingDirectory = stagingDirectoryURL else {
            errorMessage = QuickCaptureViewModelError.storageUnavailable.localizedDescription
            return
        }
        do {
            let stager = CaptureAssetStager(directoryURL: stagingDirectory)
            let payload = try await operation(stager)
            try await appendStagedPayload(payload, using: stager)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func appendStagedPayload(
        _ payload: CapturePayload,
        using stager: CaptureAssetStager
    ) async throws {
        let proposed = draft.additionalPayloads + [payload]
        guard attachmentsFitInputBudget(proposed) else {
            for asset in Self.assets(in: payload) {
                try? await stager.remove(asset)
            }
            throw QuickCaptureViewModelError.assetsTooLarge
        }
        draft.additionalPayloads.append(payload)
        do {
            try await draftStore?.save(draft)
        } catch {
            _ = draft.additionalPayloads.popLast()
            for asset in Self.assets(in: payload) {
                try? await stager.remove(asset)
            }
            throw error
        }
    }

    private func attachmentsFitInputBudget(_ payloads: [CapturePayload]) -> Bool {
        var budget = CaptureInputBudget()
        do {
            for byteCount in payloads.flatMap(Self.assets(in:)).compactMap(\.byteCount) {
                try budget.reserveAsset(bytes: byteCount)
            }
            return true
        } catch {
            return false
        }
    }

    private func historyRelativeNotePath(
        for receipt: CaptureReceipt,
        destinationID: UUID
    ) -> String? {
        guard let destination = destinations.first(where: { $0.id == destinationID }),
              let rootURL = try? Self.resolveRootURL(for: destination) else {
            return receipt.noteURL.lastPathComponent
        }
        return CaptureHistoryRecord.relativeNotePath(noteURL: receipt.noteURL, rootURL: rootURL)
    }

    private func recordHistory(
        request: CaptureRequest,
        destinationName: String,
        relativeNotePath: String?,
        attachmentCount: Int,
        outcome: CaptureHistoryOutcome,
        failureCategory: CaptureHistoryFailureCategory?
    ) async {
        guard let historyStore,
              let record = try? CaptureHistoryRecord(
                requestID: request.id,
                createdAt: request.createdAt,
                deliveredAt: Date(),
                source: request.source,
                outcome: outcome,
                destinationID: request.destinationID,
                destinationName: destinationName,
                voxID: request.voxReference?.id,
                voxName: request.voxReference?.name,
                relativeNotePath: relativeNotePath,
                attachmentCount: attachmentCount,
                failureCategory: failureCategory
              ) else { return }
        _ = await historyStore.upsertBestEffort(record)
        historyRecords = (try? await historyStore.list()) ?? historyRecords
    }

    nonisolated private static func historyFailureCategory(for error: Error) -> CaptureHistoryFailureCategory {
        switch error {
        case is CaptureDraftError:
            return .invalidRequest
        case is CaptureAttachmentError:
            return .attachment
        case is CaptureModelError, is CapturePipelineError:
            return .invalidRequest
        case is QuickCaptureViewModelError:
            return .destinationUnavailable
        default:
            return .fileWrite
        }
    }

    nonisolated private static func captureFilenameTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    nonisolated private static func assets(in payload: CapturePayload) -> [CaptureAssetReference] {
        switch payload {
        case .text, .url:
            return []
        case .audio(let asset, _), .retainedAudio(let asset, _), .image(let asset, _), .file(let asset):
            return [asset]
        case .scannedDocument(let pages, let pdf, _):
            return pages + (pdf.map { [$0] } ?? [])
        case .sketch(let drawing, let preview, _):
            return [drawing, preview]
        }
    }

    private func recoverOrphanedInboxRequests(in inbox: CaptureInbox) async throws {
        guard let libraryStore else { return }
        let library = try await libraryStore.load()
        guard let replacementID = library.defaultDestinationID.flatMap({ defaultID in
            library.destinations.contains(where: { $0.id == defaultID }) ? defaultID : nil
        }) ?? library.destinations.first?.id else { return }
        let rerouted = try await inbox.rerouteOrphanedRequests(
            validDestinationIDs: Set(library.destinations.map(\.id)),
            to: replacementID,
            states: [.pending, .failed]
        )
        for requestID in rerouted {
            _ = try await inbox.retryFailed(requestID: requestID)
        }
    }

    private func processInboxRequest(id: UUID) async throws {
        guard let captureRootURL else { throw QuickCaptureViewModelError.storageUnavailable }
        let inbox = CaptureInbox(rootDirectoryURL: captureRootURL)
        try await recoverOrphanedInboxRequests(in: inbox)
        if let request = try await inbox.claim(requestID: id) {
            try await processClaimedInboxRequest(request, inbox: inbox)
            return
        }
        switch try await inbox.state(of: id) {
        case .completed, .processing:
            // The app-wide inbox drain may have won the race with this deep link.
            return
        case .failed:
            _ = try await inbox.retryFailed(requestID: id)
            guard let request = try await inbox.claim(requestID: id) else { return }
            try await processClaimedInboxRequest(request, inbox: inbox)
        case .pending:
            guard let request = try await inbox.claim(requestID: id) else { return }
            try await processClaimedInboxRequest(request, inbox: inbox)
        case nil:
            throw QuickCaptureViewModelError.inboxRequestUnavailable
        }
    }

    private func processClaimedInboxRequest(
        _ claimedRequest: CaptureRequest,
        inbox: CaptureInbox
    ) async throws {
        var request = claimedRequest
        guard let captureRootURL, let libraryStore else {
            throw QuickCaptureViewModelError.storageUnavailable
        }
        do {
            if request.voxProcessingState == .pending {
                request = await requestProcessor.process(request)
                try await inbox.replaceProcessingRequest(request)
            }
            let library = try await libraryStore.load()
            guard let storedDestination = library.destinations.first(where: { $0.id == request.destinationID }) else {
                throw QuickCaptureViewModelError.unknownDestination
            }
            var destination = library.resolvedDestination(
                storedDestination,
                overrideEntryTemplateID: request.voxProfile?.captureEntryTemplateID
            )
            if let placement = request.voxProfile?.capturePlacementOverride {
                destination.placement = placement
            }
            let rootURL = try Self.resolveRootURL(for: destination)
            let didAccess = rootURL.startAccessingSecurityScopedResource()
            defer { if didAccess { rootURL.stopAccessingSecurityScopedResource() } }
            let receipt = try await pipeline.capture(
                request,
                destination: destination,
                rootURL: rootURL,
                assetRootURL: captureRootURL
            )
            try await inbox.complete(requestID: request.id)
            lastReceipt = receipt
            needsCaptureUnlock = false
            await recordHistory(
                request: request,
                destinationName: destination.name,
                relativeNotePath: CaptureHistoryRecord.relativeNotePath(
                    noteURL: receipt.noteURL,
                    rootURL: rootURL
                ),
                attachmentCount: receipt.attachmentURLs.count,
                outcome: .delivered,
                failureCategory: nil
            )
        } catch let error as CaptureDeliveryQuotaError {
            try? await inbox.returnToPending(requestID: request.id)
            if case .limitReached = error {
                needsCaptureUnlock = true
            }
            throw error
        } catch {
            await recordHistory(
                request: request,
                destinationName: destinations.first(where: { $0.id == request.destinationID })?.name
                    ?? String(localized: "Unavailable destination"),
                relativeNotePath: nil,
                attachmentCount: request.payloads.flatMap(Self.assets(in:)).count,
                outcome: .failed,
                failureCategory: Self.historyFailureCategory(for: error)
            )
            try? await inbox.fail(requestID: request.id)
            throw error
        }
    }

    nonisolated private static func resolveRootURL(for destination: CaptureDestination) throws -> URL {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: destination.rootBookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale else { throw QuickCaptureViewModelError.staleDestination(destination.name) }
        return url
    }
}

enum QuickCaptureViewModelError: Error, LocalizedError {
    case storageUnavailable
    case staleDestination(String)
    case unknownDestination
    case unknownVox
    case inboxRequestUnavailable
    case noteMustBeMarkdown
    case noteOutsideDestination
    case textTooLarge
    case assetsTooLarge

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return String(localized: "Shared capture storage is unavailable.")
        case .staleDestination(let name):
            return String(localized: "The Files permission for ‘\(name)’ expired. Edit the destination and choose its folder again.")
        case .unknownDestination:
            return String(localized: "The requested capture destination no longer exists.")
        case .unknownVox:
            return String(localized: "The requested Capture Preset no longer exists or is disabled.")
        case .inboxRequestUnavailable:
            return String(localized: "The shared capture request is no longer pending.")
        case .noteMustBeMarkdown:
            return String(localized: "Choose a Markdown (.md) note.")
        case .noteOutsideDestination:
            return String(localized: "Choose a note inside the selected destination folder.")
        case .textTooLarge:
            return String(localized: "Capture text is above the 100,000-character safety limit.")
        case .assetsTooLarge:
            return String(localized: "Capture attachments exceed the 250 MB total safety limit.")
        }
    }
}
