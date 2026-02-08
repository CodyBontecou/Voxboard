import UIKit
import KeyboardKit
import SwiftUI
import VoxVaultShared

/// The keyboard extension's root controller.
/// Uses KeyboardKit for the standard keyboard layout and adds a custom voice toolbar on top.
class KeyboardViewController: KeyboardInputViewController {

    private let voiceState = VoiceKeyboardState()

    override func viewWillSetupKeyboardView() {
        super.viewWillSetupKeyboardView()

        let state = voiceState

        setupKeyboardView { controller in
            VoxVaultKeyboardView(
                voiceState: state,
                controller: controller
            )
        }
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
