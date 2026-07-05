import Foundation
import UserNotifications

/// Small facade over `UNUserNotificationCenter` for the app's Dutch banners.
///
/// Authorization is requested lazily on the first `post(_:)`. If the user has
/// denied notifications the calls become silent no-ops — dictation still works.
@MainActor
enum Notifications {
    private static var didRequestAuthorization = false

    /// Posts a banner with `body` (and optional `title`). Requests authorization
    /// on first use. Never throws; failures are logged and swallowed.
    static func post(_ body: String, title: String = "Whisper Clip") {
        Task { await deliver(title: title, body: body) }
    }

    private static func deliver(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()

        if !didRequestAuthorization {
            didRequestAuthorization = true
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}
