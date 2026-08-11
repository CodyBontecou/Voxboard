import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VoxboardCaptureCore

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []
        let model = ShareCaptureModel(providers: providers, extensionContext: extensionContext)
        let host = UIHostingController(rootView: ShareCaptureView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}

@MainActor
@Observable
private final class ShareCaptureModel {
    var destinations: [CaptureDestination] = []
    var presets: [CapturePresetProfile] = []
    var selectedPresetID: String?
    var selectedDestinationID: UUID?
    var libraryDefaultDestinationID: UUID?
    var note = ""
    var isLoading = true
    var isSubmitting = false
    var isQueuedForLater = false
    var errorMessage: String?

    private let providers: [NSItemProvider]
    private weak var extensionContext: NSExtensionContext?
    private let requestID = UUID()
    private var loadedPayloads: [CapturePayload] = []
    private var captureRootURL: URL?
    private var cancellationRequested = false

    init(providers: [NSItemProvider], extensionContext: NSExtensionContext?) {
        self.providers = providers
        self.extensionContext = extensionContext
    }

    func load() async {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.bontecou.Voxboard"
        ) else {
            fail("Shared capture storage is unavailable.")
            return
        }
        let captureRoot = container.appendingPathComponent("Capture", isDirectory: true)
        captureRootURL = captureRoot
        do {
            let library = try await CaptureLibraryStore(
                fileURL: captureRoot.appendingPathComponent(CaptureLibraryStore.defaultFilename)
            ).load()
            destinations = library.destinations
            libraryDefaultDestinationID = library.defaultDestinationID
            let sharedDefaults = UserDefaults(suiteName: "group.bontecou.Voxboard")
            presets = CapturePresetProfileStore.enabledProfiles(defaults: sharedDefaults)
            for index in presets.indices where presets[index].captureDestinationID == nil {
                presets[index].captureDestinationID = library.legacyFlowBindings[presets[index].id]
            }
            selectedPresetID = CapturePresetProfileStore.selectedProfileID(defaults: sharedDefaults)
            selectedDestinationID = resolvedDestinationID(
                profile: selectedPreset,
                libraryDefaultID: library.defaultDestinationID
            )
            guard selectedDestinationID != nil else {
                throw ShareCaptureError.destinationRequired
            }
            loadedPayloads = try await ShareItemLoader.load(
                providers: providers,
                requestID: requestID,
                captureRootURL: captureRoot
            )
            guard !cancellationRequested else {
                removeStagingDirectory()
                finishCancellation()
                return
            }
            isLoading = false
        } catch is CancellationError {
            removeStagingDirectory()
            if cancellationRequested { finishCancellation() }
        } catch {
            removeStagingDirectory()
            if cancellationRequested {
                finishCancellation()
            } else {
                fail(error.localizedDescription)
            }
        }
    }

    var selectedPreset: CapturePresetProfile? {
        guard let selectedPresetID else { return nil }
        return presets.first(where: { $0.id == selectedPresetID })
    }

    func applySelectedPresetDestination() {
        selectedDestinationID = CapturePresetRouteResolver.destinationID(
            selectionMode: .inherited,
            explicitDestinationID: nil,
            profile: selectedPreset,
            destinations: destinations,
            libraryDefaultDestinationID: libraryDefaultDestinationID,
            allowsLegacyFallback: !CapturePresetProfileStore.hasOwnedRouteMigration(
                defaults: UserDefaults(suiteName: "group.bontecou.Voxboard")
            )
        )
        if let selectedPresetID {
            CapturePresetProfileStore.selectCaptureProfile(
                id: selectedPresetID,
                defaults: UserDefaults(suiteName: "group.bontecou.Voxboard")
            )
        }
    }

    func submit() async {
        guard !isSubmitting, !cancellationRequested else { return }
        if isQueuedForLater {
            await openQueuedCapture()
            return
        }
        guard let captureRootURL, let selectedDestinationID else {
            fail(ShareCaptureError.destinationRequired.localizedDescription)
            return
        }
        var payloads: [CapturePayload] = []
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            var textBudget = CaptureInputBudget()
            for payload in loadedPayloads {
                if case .text(let text) = payload {
                    try textBudget.reserveText(characters: text.count)
                }
            }
            try textBudget.reserveText(characters: trimmed.count)
        } catch {
            fail(error.localizedDescription)
            return
        }
        if !trimmed.isEmpty { payloads.append(.text(trimmed)) }
        payloads.append(contentsOf: loadedPayloads)
        guard !payloads.isEmpty else {
            fail(ShareCaptureError.emptyShare.localizedDescription)
            return
        }

        isSubmitting = true
        do {
            let profile = selectedPreset
            let processingState: CapturePresetProcessingState = profile?.captureProcessingEnabled == true
                && profile?.postProcessingMode != CapturePresetProcessingMode.none
                ? .pending
                : (profile == nil ? .notRequested : .applied)
            let request = CaptureRequest(
                id: requestID,
                source: .shareExtension,
                destinationID: selectedDestinationID,
                payloads: payloads,
                frontmatter: profile?.staticFrontmatter ?? [:],
                voxProfile: profile,
                voxProcessingState: processingState
            )
            try await CaptureInbox(rootDirectoryURL: captureRootURL).enqueue(request)
            isQueuedForLater = true
            if cancellationRequested {
                extensionContext?.completeRequest(returningItems: nil)
                return
            }
            await openQueuedCapture()
            return
        } catch {
            isSubmitting = false
            if cancellationRequested {
                removeStagingDirectory()
                finishCancellation()
            } else {
                fail(error.localizedDescription)
            }
        }
    }

    private func resolvedDestinationID(
        profile: CapturePresetProfile?,
        libraryDefaultID: UUID?
    ) -> UUID? {
        CapturePresetRouteResolver.destinationID(
            selectionMode: .inherited,
            explicitDestinationID: nil,
            profile: profile,
            destinations: destinations,
            libraryDefaultDestinationID: libraryDefaultID,
            allowsLegacyFallback: !CapturePresetProfileStore.hasOwnedRouteMigration(
                defaults: UserDefaults(suiteName: "group.bontecou.Voxboard")
            )
        )
    }

    private func openQueuedCapture() async {
        isSubmitting = true
        errorMessage = nil
        let callback = URL(string: "voxboard://capture-request?id=\(requestID.uuidString)")!
        let didOpen = await extensionContext?.open(callback) ?? false
        if didOpen {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            isSubmitting = false
            fail(String(localized: "Capture is safely queued in Vox.md. Open Vox.md to finish delivery, then tap Done here."))
        }
    }

    func cancel() {
        cancellationRequested = true
        if isQueuedForLater {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        // Do not delete staging while an enqueue may be committing a request
        // that references it. The submit path finishes cancellation once it
        // has atomically reached either queued or failed state.
        if isSubmitting || isLoading { return }
        removeStagingDirectory()
        finishCancellation()
    }

    private func finishCancellation() {
        extensionContext?.cancelRequest(
            withError: NSError(
                domain: "VoxboardShare",
                code: NSUserCancelledError,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "Capture cancelled")]
            )
        )
    }

    private func fail(_ message: String) {
        errorMessage = message
        isLoading = false
    }

    private func removeStagingDirectory() {
        guard let captureRootURL else { return }
        let staging = captureRootURL
            .appendingPathComponent("inbox-staging", isDirectory: true)
            .appendingPathComponent(requestID.uuidString.lowercased(), isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
    }
}

private enum ShareItemLoader {
    static func load(
        providers: [NSItemProvider],
        requestID: UUID,
        captureRootURL: URL
    ) async throws -> [CapturePayload] {
        var payloads: [CapturePayload] = []
        var budget = CaptureInputBudget()
        try budget.reserveSharedItems(providers.count)
        let stagingDirectory = captureRootURL
            .appendingPathComponent("inbox-staging", isDirectory: true)
            .appendingPathComponent(requestID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        for provider in providers {
            try Task.checkCancellation()
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try await loadURL(provider),
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                payloads.append(.url(url, title: provider.suggestedName))
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let text = try await loadText(provider) {
                try budget.reserveText(characters: text.count)
                payloads.append(.text(text))
                continue
            }
            guard let typeIdentifier = preferredFileType(from: provider.registeredTypeIdentifiers) else {
                continue
            }
            let copiedURL = try await copyFile(
                provider: provider,
                typeIdentifier: typeIdentifier,
                to: stagingDirectory
            )
            let relativePath = "inbox-staging/\(requestID.uuidString.lowercased())/\(copiedURL.lastPathComponent)"
            try Task.checkCancellation()
            let values = try copiedURL.resourceValues(forKeys: [.fileSizeKey])
            try budget.reserveAsset(bytes: Int64(values.fileSize ?? 0))
            let asset = try CaptureAssetReference(
                relativePath: relativePath,
                originalFilename: copiedURL.lastPathComponent,
                contentTypeIdentifier: typeIdentifier,
                byteCount: values.fileSize.map(Int64.init)
            )
            let type = UTType(typeIdentifier)
            if type?.conforms(to: .image) == true {
                payloads.append(.image(asset, altText: provider.suggestedName))
            } else if type?.conforms(to: .audio) == true {
                payloads.append(.audio(asset, transcript: nil))
            } else {
                payloads.append(.file(asset))
            }
        }
        return payloads
    }

    private static func preferredFileType(from identifiers: [String]) -> String? {
        identifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .image)
                || type.conforms(to: .audio)
                || type.conforms(to: .movie)
                || type.conforms(to: .pdf)
                || type.conforms(to: .data)
        }
    }

    private static func loadURL(_ provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                if let error { return continuation.resume(throwing: error) }
                if let url = item as? URL { return continuation.resume(returning: url) }
                if let value = item as? String { return continuation.resume(returning: URL(string: value)) }
                continuation.resume(returning: nil)
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                if let error { return continuation.resume(throwing: error) }
                continuation.resume(returning: item as? String)
            }
        }
    }

    private static func copyFile(
        provider: NSItemProvider,
        typeIdentifier: String,
        to directory: URL
    ) async throws -> URL {
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { sourceURL, error in
                if let error { return continuation.resume(throwing: error) }
                guard let sourceURL else {
                    return continuation.resume(throwing: ShareCaptureError.missingSharedFile)
                }
                var copiedDestination: URL?
                do {
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
                        throw ShareCaptureError.missingSharedFile
                    }
                    guard !isDirectory.boolValue else {
                        throw CaptureAssetStagerError.sourceIsDirectory(sourceURL.path)
                    }
                    let requestedName = suggestedName ?? sourceURL.lastPathComponent
                    let sourceValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
                    if let size = sourceValues.fileSize,
                       Int64(size) > CaptureAssetStager.defaultMaximumByteCount {
                        throw CaptureAssetStagerError.assetTooLarge(
                            filename: requestedName,
                            byteCount: Int64(size),
                            limit: CaptureAssetStager.defaultMaximumByteCount
                        )
                    }
                    let proposed = CaptureAssetStager.sanitizedFilename(
                        requestedName,
                        fallbackExtension: sourceURL.pathExtension
                    )
                    let destination = uniqueURL(directory.appendingPathComponent(proposed))
                    copiedDestination = destination
                    try FileManager.default.copyItem(at: sourceURL, to: destination)
                    let copiedValues = try destination.resourceValues(forKeys: [.fileSizeKey])
                    if let size = copiedValues.fileSize,
                       Int64(size) > CaptureAssetStager.defaultMaximumByteCount {
                        try? FileManager.default.removeItem(at: destination)
                        throw CaptureAssetStagerError.assetTooLarge(
                            filename: requestedName,
                            byteCount: Int64(size),
                            limit: CaptureAssetStager.defaultMaximumByteCount
                        )
                    }
                    continuation.resume(returning: destination)
                } catch {
                    if let copiedDestination {
                        try? FileManager.default.removeItem(at: copiedDestination)
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func uniqueURL(_ initialURL: URL) -> URL {
        guard FileManager.default.fileExists(atPath: initialURL.path) else { return initialURL }
        let ext = initialURL.pathExtension
        let base = initialURL.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            let candidate = initialURL.deletingLastPathComponent().appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}

private struct ShareCaptureView: View {
    @Bindable var model: ShareCaptureModel

    var body: some View {
        NavigationStack {
            Form {
                if model.isLoading {
                    HStack { Spacer(); ProgressView("Loading shared items…"); Spacer() }
                } else {
                    if !model.presets.isEmpty {
                        Section("Capture Preset") {
                            Picker("Preset", selection: $model.selectedPresetID) {
                                ForEach(model.presets) { preset in
                                    Label(preset.displayName, systemImage: preset.symbolName)
                                        .tag(Optional(preset.id))
                                }
                            }
                            .disabled(model.isQueuedForLater)
                            .onChange(of: model.selectedPresetID) { _, _ in
                                model.applySelectedPresetDestination()
                            }
                            if let destination = model.destinations.first(where: { $0.id == model.selectedDestinationID }) {
                                LabeledContent("Destination", value: destination.rootName)
                            }
                        }
                    }
                    Section("Add a note") {
                        TextEditor(text: $model.note)
                            .frame(minHeight: 130)
                            .disabled(model.isQueuedForLater)
                            .accessibilityLabel("Optional capture note")
                            .accessibilityHint("Adds text before the shared content")
                    }
                    if let error = model.errorMessage {
                        Section("Error") { Text(error).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle("Capture to Vox.md")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.isQueuedForLater ? String(localized: "Done") : String(localized: "Cancel")) {
                        model.cancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isSubmitting
                           ? String(localized: "Sending…")
                           : (model.isQueuedForLater ? String(localized: "Open Vox.md") : String(localized: "Send"))) {
                        Task { await model.submit() }
                    }
                    .disabled(model.isLoading || model.isSubmitting || model.selectedDestinationID == nil)
                }
            }
            .task { await model.load() }
            .onChange(of: model.errorMessage) { _, message in
                guard let message else { return }
                UIAccessibility.post(notification: .announcement, argument: message)
            }
        }
    }
}

private enum ShareCaptureError: Error, LocalizedError {
    case destinationRequired
    case emptyShare
    case missingSharedFile

    var errorDescription: String? {
        switch self {
        case .destinationRequired: return String(localized: "Configure a destination for a Capture Preset in Vox.md first.")
        case .emptyShare: return String(localized: "There is no supported content to capture.")
        case .missingSharedFile: return String(localized: "The shared file disappeared before Vox.md could copy it.")
        }
    }
}
