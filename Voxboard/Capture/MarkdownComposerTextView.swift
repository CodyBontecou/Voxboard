import SwiftUI
import UIKit

/// Imperative bridge used by the Markdown toolbar so selection-aware edits use
/// the same UITextView undo stack as keyboard typing on the iOS 17 target.
@MainActor
final class MarkdownComposerController {
    fileprivate weak var textView: UITextView?
    fileprivate var publishText: ((String) -> Void)?
    fileprivate var publishSelection: ((NSRange) -> Void)?
    fileprivate var publishFocus: ((Bool) -> Void)?

    var text: String { textView?.text ?? "" }
    var selection: NSRange { textView?.selectedRange ?? NSRange(location: 0, length: 0) }

    func focus() {
        textView?.becomeFirstResponder()
    }

    func dismissKeyboard() {
        textView?.resignFirstResponder()
    }

    func undo() {
        textView?.undoManager?.undo()
        publishCurrentState()
    }

    func replaceAll(with text: String, selection: NSRange) {
        apply(text: text, selection: selection, registeringUndo: true)
    }

    func replaceSelection(with replacement: String, selectInsertedText: Bool = false) {
        guard let textView else { return }
        let current = textView.text ?? ""
        let currentSelection = Self.clamped(textView.selectedRange, utf16Count: current.utf16.count)
        guard let range = Range(currentSelection, in: current) else { return }
        let next = current.replacingCharacters(in: range, with: replacement)
        let insertedLength = replacement.utf16.count
        let nextSelection = NSRange(
            location: currentSelection.location + (selectInsertedText ? 0 : insertedLength),
            length: selectInsertedText ? insertedLength : 0
        )
        apply(text: next, selection: nextSelection, registeringUndo: true)
    }

    private func apply(text: String, selection: NSRange, registeringUndo: Bool) {
        guard let textView else { return }
        let oldText = textView.text ?? ""
        let oldSelection = textView.selectedRange
        if registeringUndo, oldText != text || oldSelection != selection {
            textView.undoManager?.registerUndo(withTarget: self) { controller in
                controller.apply(text: oldText, selection: oldSelection, registeringUndo: true)
            }
            textView.undoManager?.setActionName(String(localized: "Edit Markdown"))
        }
        textView.text = text
        textView.selectedRange = Self.clamped(selection, utf16Count: text.utf16.count)
        publishCurrentState()
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    fileprivate func publishCurrentState() {
        guard let textView else { return }
        publishText?(textView.text ?? "")
        publishSelection?(textView.selectedRange)
        publishFocus?(textView.isFirstResponder)
    }

    fileprivate static func clamped(_ range: NSRange, utf16Count: Int) -> NSRange {
        let location = min(max(0, range.location), utf16Count)
        let length = min(max(0, range.length), utf16Count - location)
        return NSRange(location: location, length: length)
    }
}

struct MarkdownComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var isFocused: Bool
    let controller: MarkdownComposerController

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textColor = UIColor(Geist.text)
        textView.tintColor = UIColor(Geist.focus)
        let baseFont = UIFont(name: "GeistMono-Regular", size: 16)
            ?? UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: baseFont)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 24, left: 16, bottom: 24, right: 16)
        textView.keyboardDismissMode = .interactive
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.autocorrectionType = .yes
        textView.spellCheckingType = .yes
        textView.accessibilityLabel = String(localized: "Capture note")
        textView.accessibilityHint = String(localized: "Enter raw Markdown to send to the selected destination")
        textView.accessibilityIdentifier = "quick_capture_text"
        textView.text = text
        textView.selectedRange = MarkdownComposerController.clamped(selection, utf16Count: text.utf16.count)
        connect(textView, coordinator: context.coordinator)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        connect(textView, coordinator: context.coordinator)

        if textView.text != text {
            textView.text = text
        }
        let desired = MarkdownComposerController.clamped(selection, utf16Count: text.utf16.count)
        if textView.selectedRange != desired {
            textView.selectedRange = desired
        }
        if isFocused, !textView.isFirstResponder {
            DispatchQueue.main.async { textView.becomeFirstResponder() }
        } else if !isFocused, textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }

    private func connect(_ textView: UITextView, coordinator: Coordinator) {
        controller.textView = textView
        controller.publishText = { value in
            if coordinator.parent.text != value { coordinator.parent.text = value }
        }
        controller.publishSelection = { value in
            if coordinator.parent.selection != value { coordinator.parent.selection = value }
        }
        controller.publishFocus = { value in
            if coordinator.parent.isFocused != value { coordinator.parent.isFocused = value }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownComposerTextView

        init(parent: MarkdownComposerTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.controller.publishCurrentState()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.controller.publishCurrentState()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.controller.publishCurrentState()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.controller.publishCurrentState()
        }
    }
}
