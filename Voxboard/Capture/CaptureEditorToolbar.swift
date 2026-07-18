import SwiftUI

enum CaptureEditorToolbarCommand: Equatable {
    case undo
    case bold
    case italic
    case hashtag
    case heading(Int)
    case markdownLink
    case checklist
    case bulletList
    case paste
    case internalLink
    case timestamp
    case date
    case lowercase
    case uppercase
    case sentenceCase
    case capitalizeWords
    case slugify
}

struct CaptureEditorToolbar: View {
    var command: (CaptureEditorToolbarCommand) -> Void
    var showDueDate: () -> Void
    var insertLocation: () -> Void
    var showSketch: () -> Void
    var showCamera: () -> Void
    var showPhotos: () -> Void
    var showScreenshots: () -> Void
    var showLinkPrompt: () -> Void
    var showFiles: () -> Void
    var showScan: () -> Void
    var isProcessingMedia: Bool
    var isFindingLocation: Bool

    @State private var preferences = CaptureToolbarPreferences()
    @State private var showsSettings = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(preferences.visibleActions) { action in
                    toolbarAction(action)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .frame(height: 48)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .accessibilityLabel("Markdown and capture tools")
        .sheet(isPresented: $showsSettings) {
            CaptureToolbarSettingsView(preferences: preferences)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private func toolbarAction(_ action: CaptureToolbarAction) -> some View {
        switch action {
        case .addMedia:
            Menu {
                Button(action: showSketch) {
                    Label("Sketch", systemImage: "pencil.tip")
                }
                Button(action: showCamera) {
                    Label("Camera", systemImage: "camera")
                }
                Button(action: showPhotos) {
                    Label("Photo", systemImage: "photo")
                }
                Button(action: showScreenshots) {
                    Label("Screenshot", systemImage: "rectangle.inset.filled.and.person.filled")
                }
                Divider()
                Button(action: showLinkPrompt) {
                    Label("Web Link", systemImage: "link")
                }
            } label: {
                toolbarLabel(action.accessibilityLabel, icon: action.systemImage)
            }
            .disabled(isProcessingMedia)

        case .addFiles:
            toolbarButton(action.accessibilityLabel, icon: action.systemImage, action: showFiles)
                .disabled(isProcessingMedia)

        case .scanDocument:
            toolbarButton(action.accessibilityLabel, icon: action.systemImage, action: showScan)
                .disabled(isProcessingMedia)

        case .undo:
            toolbarButton(action.accessibilityLabel, icon: action.systemImage) { command(.undo) }

        case .formatMarkdown:
            Menu {
                Button("Bold") { command(.bold) }
                Button("Italic") { command(.italic) }
                Button("Hashtag") { command(.hashtag) }
                Divider()
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") { command(.heading(level)) }
                }
            } label: {
                toolbarLabel(action.accessibilityLabel, icon: action.systemImage)
            }

        case .markdownLink:
            toolbarButton(action.accessibilityLabel, icon: action.systemImage) { command(.markdownLink) }

        case .dueDate:
            toolbarButton(action.accessibilityLabel, icon: action.systemImage, action: showDueDate)

        case .checklist:
            toolbarButton(action.accessibilityLabel, icon: action.systemImage) { command(.checklist) }

        case .bulletList:
            toolbarButton(action.accessibilityLabel, icon: action.systemImage) { command(.bulletList) }

        case .paste:
            toolbarButton(action.accessibilityLabel, icon: action.systemImage) { command(.paste) }

        case .internalLink:
            toolbarButton(action.accessibilityLabel, textIcon: action.textIcon) { command(.internalLink) }

        case .sketch:
            toolbarButton(action.accessibilityLabel, icon: action.systemImage, action: showSketch)

        case .currentLocation:
            Button(action: insertLocation) {
                toolbarLabel(
                    action.accessibilityLabel,
                    icon: isFindingLocation ? "location.fill" : action.systemImage
                )
            }
            .disabled(isFindingLocation)

        case .timestamp:
            toolbarButton(action.accessibilityLabel, icon: action.systemImage) { command(.timestamp) }

        case .date:
            toolbarButton(action.accessibilityLabel, icon: action.systemImage) { command(.date) }

        case .captureBarSettings:
            Button {
                showsSettings = true
            } label: {
                toolbarLabel(action.accessibilityLabel, icon: action.systemImage)
            }
            .accessibilityIdentifier("capture_toolbar_settings")

        case .textCase:
            Menu {
                Button("Lowercase") { command(.lowercase) }
                Button("Uppercase") { command(.uppercase) }
                Button("Sentence case") { command(.sentenceCase) }
                Button("Capitalize case") { command(.capitalizeWords) }
                Button("Slugify case") { command(.slugify) }
            } label: {
                toolbarLabel(action.accessibilityLabel, textIcon: action.textIcon)
            }
        }
    }

    private func toolbarButton(
        _ accessibilityLabel: String,
        icon: String? = nil,
        textIcon: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            toolbarLabel(accessibilityLabel, icon: icon, textIcon: textIcon)
        }
    }

    private func toolbarLabel(
        _ accessibilityLabel: String,
        icon: String? = nil,
        textIcon: String? = nil
    ) -> some View {
        Group {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
            } else {
                Text(textIcon ?? "")
                    .font(Geist.mono(.footnote, medium: true))
            }
        }
        .foregroundStyle(Geist.text)
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
    }
}
