import AppKit
import SwiftUI

/// AppKit-backed Markdown editor used by the Mac Capture workspace.
///
/// Keeping the `NSTextView` alive gives Capture native undo, find, spelling,
/// Services, keyboard selection, and drag behavior while toolbar edits continue
/// to use the shared `CaptureComposerTextEditor` semantics.
@MainActor
final class MacMarkdownComposerController {
    fileprivate weak var textView: NSTextView?
    fileprivate var publishText: ((String) -> Void)?
    fileprivate var publishSelection: ((NSRange) -> Void)?
    fileprivate var publishFocus: ((Bool) -> Void)?

    var text: String { textView?.string ?? "" }
    var selection: NSRange { textView?.selectedRange() ?? NSRange(location: 0, length: 0) }
    var isFocused: Bool { textView?.window?.firstResponder === textView }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        publishCurrentState()
    }

    func dismissFocus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(nil)
        publishCurrentState()
    }

    func undo() {
        textView?.undoManager?.undo()
        publishCurrentState()
    }

    func redo() {
        textView?.undoManager?.redo()
        publishCurrentState()
    }

    func replaceAll(with text: String, selection: NSRange) {
        apply(text: text, selection: selection, registeringUndo: true)
    }

    func replaceSelection(with replacement: String, selectInsertedText: Bool = false) {
        guard let textView else { return }
        let current = textView.string
        let currentSelection = Self.clamped(textView.selectedRange(), utf16Count: current.utf16.count)
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
        let oldText = textView.string
        let oldSelection = textView.selectedRange()
        if registeringUndo, oldText != text || oldSelection != selection {
            textView.undoManager?.registerUndo(withTarget: self) { controller in
                controller.apply(text: oldText, selection: oldSelection, registeringUndo: true)
            }
            textView.undoManager?.setActionName(String(localized: "Edit Markdown"))
        }

        textView.string = text
        textView.setSelectedRange(Self.clamped(selection, utf16Count: text.utf16.count))
        textView.scrollRangeToVisible(textView.selectedRange())
        publishCurrentState()
    }

    fileprivate func publishCurrentState() {
        guard let textView else { return }
        publishText?(textView.string)
        publishSelection?(textView.selectedRange())
        publishFocus?(textView.window?.firstResponder === textView)
    }

    fileprivate func disconnect(_ textView: NSTextView) {
        guard self.textView === textView else { return }
        self.textView = nil
        publishText = nil
        publishSelection = nil
        publishFocus = nil
    }

    fileprivate static func clamped(_ range: NSRange, utf16Count: Int) -> NSRange {
        let location = min(max(0, range.location), utf16Count)
        let length = min(max(0, range.length), utf16Count - location)
        return NSRange(location: location, length: length)
    }
}

struct MacMarkdownComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var isFocused: Bool
    let controller: MacMarkdownComposerController

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.drawsBackground = false
        textView.textColor = NSColor(Geist.text)
        textView.insertionPointColor = NSColor(Geist.focus)
        textView.font = NSFont(name: "GeistMono-Regular", size: 16)
            ?? NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.textContainerInset = NSSize(width: 18, height: 22)
        textView.string = text
        textView.setSelectedRange(Self.clamped(selection, utf16Count: text.utf16.count))
        textView.setAccessibilityLabel(String(localized: "Capture note"))
        textView.setAccessibilityIdentifier("mac_quick_capture_text")

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        connect(textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        connect(textView, coordinator: context.coordinator)

        if textView.string != text {
            textView.string = text
        }
        let desired = Self.clamped(selection, utf16Count: text.utf16.count)
        if textView.selectedRange() != desired {
            textView.setSelectedRange(desired)
        }

        if isFocused, textView.window?.firstResponder !== textView {
            let coordinator = context.coordinator
            DispatchQueue.main.async { [weak textView, weak coordinator] in
                guard let textView, let coordinator, coordinator.parent.isFocused else { return }
                textView.window?.makeFirstResponder(textView)
            }
        } else if !isFocused, textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        coordinator.parent.controller.disconnect(textView)
    }

    private func connect(_ textView: NSTextView, coordinator: Coordinator) {
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

    private static func clamped(_ range: NSRange, utf16Count: Int) -> NSRange {
        MacMarkdownComposerController.clamped(range, utf16Count: utf16Count)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacMarkdownComposerTextView

        init(parent: MacMarkdownComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            parent.controller.publishCurrentState()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            parent.controller.publishCurrentState()
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.controller.publishCurrentState()
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.controller.publishCurrentState()
        }
    }
}
