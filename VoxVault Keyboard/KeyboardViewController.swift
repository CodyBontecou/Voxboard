import UIKit
import KeyboardKit
import SwiftUI
import VoxVaultShared

private let log = KeyboardDebugLog.shared

/// The keyboard extension's root controller.
/// Uses KeyboardKit for the standard keyboard layout and adds a custom voice toolbar on top.
class KeyboardViewController: KeyboardInputViewController {

    private let voiceState = VoiceKeyboardState()

    override func viewDidLoad() {
        super.viewDidLoad()
        log.log("viewDidLoad — keyboard extension loaded")

        // Give the voice state a way to open URLs via our responder chain
        voiceState.urlOpener = { [weak self] url in
            self?.openAppURL(url)
        }
    }

    override func viewWillSetupKeyboardView() {
        super.viewWillSetupKeyboardView()
        log.log("viewWillSetupKeyboardView — hasFullAccess=\(hasFullAccess)")

        let state = voiceState

        setupKeyboardView { controller in
            VoxVaultKeyboardView(
                voiceState: state,
                controller: controller
            )
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        log.log("viewDidAppear")
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
    ///
    /// In keyboard extensions the chain typically ends at `_UIScreenBasedWindowScene`
    /// (a UIWindowScene subclass) which responds to `openURL:options:completionHandler:`.
    /// We pass `nil` for options since UIWindowScene expects `UIScene.OpenExternalURLOptions?`
    /// while UIApplication expects `[OpenExternalURLOptionsKey: Any]` — nil is valid for both.
    private func openAppURL(_ url: URL) {
        log.log("openAppURL — walking responder chain for: \(url.absoluteString)")

        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self

        while let current = responder {
            if current.responds(to: selector) {
                log.log("openAppURL — found responder: \(type(of: current))")

                // Call the 3-arg method via IMP cast.
                // Use Any? for options so nil works for both UIApplication and UIWindowScene.
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
private struct VoxVaultKeyboardView: View {
    @State var voiceState: VoiceKeyboardState
    let controller: KeyboardInputViewController

    var body: some View {
        VStack(spacing: 0) {
            VoiceToolbarView(
                voiceState: voiceState,
                hasFullAccess: controller.hasFullAccess
            )

            KeyboardView(
                services: controller.services
            )
        }
        .onChange(of: voiceState.pendingTranscription) { _, newValue in
            if let text = newValue {
                controller.textDocumentProxy.insertText(text)
                voiceState.consumeTranscription()
            }
        }
    }
}
