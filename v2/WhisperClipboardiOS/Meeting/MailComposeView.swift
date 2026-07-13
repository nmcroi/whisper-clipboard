import MessageUI
import SwiftUI

/// SwiftUI-wrapper om `MFMailComposeViewController`: de vooringevulde
/// notulen-mail (alle ontvangers, onderwerp, identieke tekst). De gebruiker
/// drukt zélf op versturen — de mail gaat via het eigen mailaccount, er is
/// geen externe verzenddienst.
struct MailComposeView: UIViewControllerRepresentable {
    let recipients: [String]
    let subject: String
    let body: String
    let onFinished: (MFMailComposeResult) -> Void

    static var canSendMail: Bool {
        MFMailComposeViewController.canSendMail()
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients(recipients)
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinished: onFinished)
    }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinished: (MFMailComposeResult) -> Void

        init(onFinished: @escaping (MFMailComposeResult) -> Void) {
            self.onFinished = onFinished
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            controller.dismiss(animated: true)
            onFinished(result)
        }
    }
}
