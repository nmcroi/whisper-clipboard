import AppKit
import Foundation
import SwiftUI
import UserNotifications

/// How the app tells the user something. Two channels live here:
///
///  * ``Notifications`` — the quiet banner facade over `UNUserNotificationCenter`,
///    plus a **critical** variant that escalates to a modal `NSAlert` when banners
///    are unavailable.
///  * ``DataChange`` + ``SwiftUI/View/dataChangeAlert(_:)`` — the one uniform way
///    a screen reports that a write to the store failed.
///
/// Authorization is requested lazily on the first `post(_:)`. If the user has
/// denied notifications the calls become silent no-ops — dictation still works.
@MainActor
enum Notifications {
    private static var didRequestAuthorization = false

    /// Posts a banner with `body` (and optional `title`). Requests authorization
    /// on first use. Never throws; failures are logged and swallowed.
    ///
    /// This is the **quiet** path: use it for informational messages that may be
    /// missed without harm ("Tekst staat op je klembord", "Opname gestart").
    static func post(_ body: String, title: String = "Whisper Clip") {
        Task { _ = await deliver(title: title, body: body) }
    }

    /// Meldt iets dat de gebruiker **niet** mag missen: eerst de gewone banner,
    /// en zodra die niet geplaatst kan worden een modale `NSAlert`.
    ///
    /// Bevinding 2026-08-03: de belangrijkste melding van de app ("Opslaan in
    /// Geschiedenis is mislukt") liep uitsluitend via `post(_:)`. Een banner is
    /// een stille no-op zodra de gebruiker meldingen heeft geweigerd of
    /// uitgezet — precies het geval waarin werk verloren gaat zonder dat iemand
    /// het merkt. Deze variant escaleert dan naar een alert.
    ///
    /// Gebruik dit ALLEEN voor dataverlies of een gestopte functie; gewone
    /// informatieve meldingen blijven via `post(_:)` lopen, anders wordt elke
    /// melding een modaal venster.
    static func postCritical(_ body: String, title: String = "Whisper Clip") {
        NSLog("Notifications (kritiek): %@ — %@", title, body)
        Task {
            if await deliver(title: title, body: body) { return }
            presentAlert(title: title, body: body)
        }
    }

    /// Returns true only when the banner was actually handed to the system.
    private static func deliver(title: String, body: String) async -> Bool {
        let center = UNUserNotificationCenter.current()

        if !didRequestAuthorization {
            didRequestAuthorization = true
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        else { return false }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            return true
        } catch {
            NSLog("Notifications: banner kon niet worden geplaatst (%@)", String(describing: error))
            return false
        }
    }

    /// De terugvaloptie wanneer er geen banner mogelijk is. De app is een
    /// menubalk-app (`LSUIElement`), dus hij moet zichzelf eerst naar voren
    /// halen — anders verschijnt de alert achter het actieve venster.
    private static func presentAlert(title: String, body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "Oké")
        alert.runModal()
    }
}

// MARK: - Mislukte datawijzigingen

/// De uniforme manier om een mislukte schrijfactie naar de store zichtbaar te
/// maken.
///
/// Bevinding 2026-08-03: elke mutatie vanuit de UI (verwijderen, hernoemen,
/// vastzetten, tekst bewerken, sprekers hernoemen, fragmenten wegknippen) liep
/// via `try?`. Mislukte de schrijfactie, dan verdween de fout in het niets en
/// bleef de UI de wijziging tonen alsof hij bewaard was — en bij verwijderen
/// sloot het detailpaneel zelfs. Dit spiegelt `AppModel.presentDataChangeError`
/// op de iPhone-app.
@MainActor
enum DataChange {

    /// Voert `change` uit en meldt een fout via `report`.
    ///
    /// Geeft `true` terug wanneer de wijziging écht is opgeslagen. Bij `false`
    /// mag de aanroeper de UI **niet** verder laten lopen: niet sluiten, geen
    /// selectie verschuiven, geen bewerkmodus verlaten (anders is de tekst van
    /// de gebruiker alsnog weg).
    @discardableResult
    static func perform(
        _ action: String,
        report: (String) -> Void,
        _ change: () throws -> Void
    ) -> Bool {
        do {
            try change()
            return true
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let message = "\(action) is mislukt: \(reason)"
            NSLog("DataChange: %@", message)
            report(message)
            return false
        }
    }

    /// Variant die de melding in de standaard-alert van het scherm zet. Koppel
    /// dezelfde `@State` aan ``SwiftUI/View/dataChangeAlert(_:)``.
    @discardableResult
    static func perform(
        _ action: String,
        reporting error: Binding<String?>,
        _ change: () throws -> Void
    ) -> Bool {
        perform(action, report: { error.wrappedValue = $0 }, change)
    }
}

extension View {
    /// De uniforme "wijziging niet opgeslagen"-alert. Zet hem één keer per
    /// scherm neer en voed hem met de melding uit ``DataChange``.
    func dataChangeAlert(_ message: Binding<String?>) -> some View {
        alert(
            "Wijziging niet opgeslagen",
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            )
        ) {
            Button("Oké", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
