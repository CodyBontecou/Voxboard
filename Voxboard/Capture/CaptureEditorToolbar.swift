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
    var showScan: () -> Void
    var dismissKeyboard: () -> Void
    var isFindingLocation: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                toolbarButton("Undo", icon: "arrow.uturn.backward") { command(.undo) }

                Menu {
                    Button("Bold") { command(.bold) }
                    Button("Italic") { command(.italic) }
                    Button("Hashtag") { command(.hashtag) }
                    Divider()
                    ForEach(1...6, id: \.self) { level in
                        Button("Heading \(level)") { command(.heading(level)) }
                    }
                } label: {
                    toolbarLabel("Format Markdown", icon: "textformat")
                }

                toolbarButton("Markdown link", icon: "link") { command(.markdownLink) }
                toolbarButton("Set due date", icon: "alarm") { showDueDate() }
                toolbarButton("Checklist", icon: "checkmark.square") { command(.checklist) }
                toolbarButton("Bullet list", icon: "list.bullet") { command(.bulletList) }
                toolbarButton("Paste", icon: "clipboard") { command(.paste) }
                toolbarButton("Dismiss keyboard", icon: "keyboard.chevron.compact.down") { dismissKeyboard() }
                toolbarButton("Internal link", textIcon: "[[") { command(.internalLink) }
                toolbarButton("Sketch", icon: "pencil.tip") { showSketch() }
                toolbarButton("Scan document", icon: "viewfinder") { showScan() }

                Button(action: insertLocation) {
                    toolbarLabel(
                        "Insert current location",
                        icon: isFindingLocation ? "location.fill" : "location"
                    )
                }
                .disabled(isFindingLocation)

                toolbarButton("Insert timestamp", icon: "clock") { command(.timestamp) }
                toolbarButton("Insert date", icon: "calendar") { command(.date) }

                Menu {
                    Button("Lowercase") { command(.lowercase) }
                    Button("Uppercase") { command(.uppercase) }
                    Button("Sentence case") { command(.sentenceCase) }
                    Button("Capitalize case") { command(.capitalizeWords) }
                    Button("Slugify case") { command(.slugify) }
                } label: {
                    toolbarLabel("Change text case", textIcon: "Abc")
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(minHeight: 48)
        .background(Brutal.surface)
        .overlay(alignment: .top) { Rectangle().fill(Brutal.border).frame(height: 1) }
        .accessibilityLabel("Markdown and capture tools")
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
                    .font(.system(size: 18, weight: .medium))
            } else {
                Text(textIcon ?? "")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
            }
        }
        .foregroundStyle(Brutal.text)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
    }
}
