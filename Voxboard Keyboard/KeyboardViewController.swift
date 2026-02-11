import UIKit
import KeyboardKit
import SwiftUI
import VoxboardShared

private let log = KeyboardDebugLog.shared

/// The keyboard extension's root controller.
/// Uses KeyboardKit for the standard keyboard layout and adds a custom voice toolbar on top.
class KeyboardViewController: KeyboardInputViewController {

    private let voiceState = VoiceKeyboardState()

    override func viewDidLoad() {
        super.viewDidLoad()
        log.log("viewDidLoad — keyboard extension loaded")

        // Give the voice state a way to open URLs via our responder chain.
        // Only used for the one-time "Open Voxboard to start listening" prompt.
        voiceState.urlOpener = { [weak self] url in
            self?.openAppURL(url)
        }

        // Give the voice state a way to insert text directly via textDocumentProxy
        voiceState.textInserter = { [weak self] text in
            guard let self else {
                log.log("❌ textInserter — self is nil")
                return
            }
            log.log("textInserter — inserting \(text.count) chars into textDocumentProxy")
            self.textDocumentProxy.insertText(text)
        }
    }

    override func viewWillSetupKeyboardView() {
        super.viewWillSetupKeyboardView()
        log.log("viewWillSetupKeyboardView — hasFullAccess=\(hasFullAccess)")

        let state = voiceState

        setupKeyboardView { controller in
            VoxboardKeyboardView(
                voiceState: state,
                controller: controller
            )
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        log.log("viewDidAppear")

        // Re-check listening state immediately — catches cases where the user
        // opened the app, started listening, and came back to the keyboard.
        voiceState.refreshListeningStatePublic()

        // Refresh model cache in case models were downloaded while keyboard was hidden
        voiceState.refreshModelCache()

        // Try to insert any pending text recovered from a previous session
        voiceState.tryInsertPendingText()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        log.log("viewDidDisappear")
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        log.log("⚠️⚠️⚠️ didReceiveMemoryWarning")
        voiceState.handleMemoryWarning()
    }

    // MARK: - Open URL via Responder Chain

    /// Walk the responder chain to find a responder that can open URLs.
    /// Used only for the one-time "open app to start listening" prompt.
    private func openAppURL(_ url: URL) {
        log.log("openAppURL — walking responder chain for: \(url.absoluteString)")

        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self

        while let current = responder {
            if current.responds(to: selector) {
                log.log("openAppURL — found responder: \(type(of: current))")

                let imp = current.method(for: selector)
                typealias OpenURLFunc = @convention(c) (
                    AnyObject, Selector, URL, Any?, ((Bool) -> Void)?
                ) -> Void
                let openURL = unsafeBitCast(imp, to: OpenURLFunc.self)
                openURL(current, selector, url, nil) { success in
                    DispatchQueue.main.async {
                        log.log("openAppURL — completion: success=\(success)")
                    }
                }
                return
            }
            responder = current.next
        }

        log.log("❌ openAppURL — no responder found in chain")
    }
}

/// Combines the voice toolbar + standard KeyboardKit keyboard in a VStack.
private struct VoxboardKeyboardView: View {
    @State var voiceState: VoiceKeyboardState
    let controller: KeyboardInputViewController

    var body: some View {
        VStack(spacing: 0) {
            VoiceToolbarView(
                voiceState: voiceState,
                hasFullAccess: controller.hasFullAccess
            )

            KeyboardView(
                services: controller.services,
                buttonContent: { $0.view },
                buttonView: { $0.view },
                collapsedView: { $0.view },
                emojiKeyboard: { $0.view },
                toolbar: { _ in EmptyView() }
            )
        }
        .onChange(of: voiceState.pendingTranscription) { _, newValue in
            if let text = newValue {
                log.log("onChange(pendingTranscription) — inserting \(text.count) chars (fallback path)")
                controller.textDocumentProxy.insertText(text)
                voiceState.consumeTranscription()
            }
        }
    }
}
