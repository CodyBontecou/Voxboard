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
            ) { text in
                controller.textDocumentProxy.insertText(text)
            }

            KeyboardView(
                services: controller.services
            )
        }
    }
}
