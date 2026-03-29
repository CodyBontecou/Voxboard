import SwiftUI

#if os(iOS)
import MessageUI
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Feedback Email Payload

struct FeedbackEmailPayload {
    let recipient: String
    let subject: String
    let body: String
}

// MARK: - Feedback Helper

enum FeedbackHelper {
    static let supportEmail = "cody@isolated.tech"

    static func makePayload() -> FeedbackEmailPayload {
        let appName = appDisplayName
        return FeedbackEmailPayload(
            recipient: supportEmail,
            subject: "\(appName) Feedback",
            body: "\n\n\(diagnosticsBlock(appName: appName))"
        )
    }

    static func diagnosticsBlock(appName: String = appDisplayName) -> String {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

#if os(iOS)
        let platform = "iOS"
        let device = UIDevice.current.model
#elseif os(macOS)
        let platform = "macOS"
        let device = "Mac"
#else
        let platform = "Unknown"
        let device = "Unknown"
#endif

        return """
        ---
        App: \(appName) \(appVersion) (\(buildNumber))
        Platform: \(platform) \(osVersion)
        Device: \(device)
        ---
        """
    }

    static func mailtoURL(payload: FeedbackEmailPayload = makePayload()) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = payload.recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: payload.subject),
            URLQueryItem(name: "body", value: payload.body),
        ]
        return components.url
    }

#if os(iOS)
    static var canSendMail: Bool {
        MFMailComposeViewController.canSendMail()
    }

    static func makeMailCompose(payload: FeedbackEmailPayload = makePayload()) -> MFMailComposeViewController {
        let compose = MFMailComposeViewController()
        compose.setToRecipients([payload.recipient])
        compose.setSubject(payload.subject)
        compose.setMessageBody(payload.body, isHTML: false)
        return compose
    }
#endif

    private static var appDisplayName: String {
        if let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }

        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.isEmpty {
            return name
        }

        return "Voxboard"
    }
}

// MARK: - iOS Mail Compose Wrapper

#if os(iOS)
struct MailComposeView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let payload: FeedbackEmailPayload

    init(payload: FeedbackEmailPayload = FeedbackHelper.makePayload()) {
        self.payload = payload
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let compose = FeedbackHelper.makeMailCompose(payload: payload)
        compose.mailComposeDelegate = context.coordinator
        return compose
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let parent: MailComposeView

        init(_ parent: MailComposeView) {
            self.parent = parent
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            parent.dismiss()
        }
    }
}
#endif
