import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VoxboardShared

struct CaptureRoutePickerView: View {
    @Bindable var viewModel: QuickCaptureViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsNotePicker = false

    var body: some View {
        NavigationStack {
            List {
                Section("Destination") {
                    ForEach(viewModel.destinations) { destination in
                        Button {
                            viewModel.selectDestination(destination.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(destination.name)
                                    Text(destination.rootName)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(Geist.muted)
                                }
                                Spacer()
                                if destination.id == viewModel.draft.destinationID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                if viewModel.selectedDestination != nil {
                    Section("This capture") {
                        Picker("Placement", selection: placementBinding) {
                            Text("Destination Default").tag(PlacementChoice.default)
                            Text("Top").tag(PlacementChoice.top)
                            Text("Bottom").tag(PlacementChoice.bottom)
                        }

                        Picker("Entry template", selection: $viewModel.draft.entryTemplateID) {
                            Text("Destination Default").tag(UUID?.none)
                            ForEach(viewModel.entryTemplates) { template in
                                Text(template.name).tag(Optional(template.id))
                            }
                        }

                        Button {
                            showsNotePicker = true
                        } label: {
                            Label(
                                viewModel.draft.relativeNotePathOverride ?? "Choose note from vault",
                                systemImage: "doc.text.magnifyingglass"
                            )
                        }

                        if viewModel.draft.relativeNotePathOverride != nil
                            || viewModel.draft.placementOverride != nil
                            || viewModel.draft.entryTemplateID != nil {
                            Button(role: .destructive) {
                                viewModel.clearRouteOverrides()
                            } label: {
                                Label("Reset capture overrides", systemImage: "arrow.uturn.backward")
                            }
                        }
                    }

                    if let preview = viewModel.resolvedDestinationPreview {
                        Section("Resolved note") {
                            Text(preview)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }

                Section {
                    NavigationLink {
                        CaptureDestinationLibraryView(viewModel: viewModel)
                    } label: {
                        Label("Manage destinations and templates", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .navigationTitle("Capture route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task { await viewModel.saveDraftNow() }
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showsNotePicker) {
                CaptureMarkdownNotePicker(
                    initialDirectoryURL: viewModel.selectedRootURL(),
                    onPick: { url in
                        showsNotePicker = false
                        Task { await viewModel.setOneOffNote(url: url) }
                    },
                    onCancel: { showsNotePicker = false }
                )
                .ignoresSafeArea()
            }
        }
    }

    private var placementBinding: Binding<PlacementChoice> {
        Binding(
            get: {
                switch viewModel.draft.placementOverride {
                case nil: return .default
                case .prepend: return .top
                case .append: return .bottom
                case .beneathHeading(_, _): return .default
                }
            },
            set: { choice in
                switch choice {
                case .default: viewModel.setPlacementOverride(nil)
                case .top: viewModel.setPlacementOverride(.prepend)
                case .bottom: viewModel.setPlacementOverride(.append)
                }
            }
        )
    }

    private enum PlacementChoice: String, Hashable {
        case `default`
        case top
        case bottom
    }
}

struct CaptureFolderPicker: UIViewControllerRepresentable {
    var initialDirectoryURL: URL?
    var onPick: (URL) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.directoryURL = initialDirectoryURL
        picker.delegate = context.coordinator
        picker.accessibilityLabel = String(localized: "Choose vault or folder")
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: CaptureFolderPicker

        init(parent: CaptureFolderPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                parent.onCancel()
                return
            }
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}

struct CaptureMarkdownNotePicker: UIViewControllerRepresentable {
    var initialDirectoryURL: URL?
    var onPick: (URL) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let markdown = UTType(filenameExtension: "md") ?? .plainText
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [markdown], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.directoryURL = initialDirectoryURL
        picker.delegate = context.coordinator
        picker.accessibilityLabel = String(localized: "Choose Markdown note")
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: CaptureMarkdownNotePicker

        init(parent: CaptureMarkdownNotePicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                parent.onCancel()
                return
            }
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
