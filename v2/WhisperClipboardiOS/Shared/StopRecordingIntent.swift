import ActivityKit
import AppIntents
import Foundation

/// App Intent voor de stop-knop op de Live Activity (lock-screen + Dynamic
/// Island). Omdat dit een `LiveActivityIntent` is, draait `perform()` IN HET
/// APP-PROCES (op een achtergrondthread) i.p.v. in de widget-extensie — precies
/// wat we nodig hebben om de lopende opname netjes af te ronden.
///
/// Dit bestand wordt in ZOWEL de app als de widget-extensie meegecompileerd (zie
/// beide targets in `project.yml`): de widget refereert het type in `Button(intent:)`,
/// de app voert het uit.
struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Opname stoppen"
    static let description = IntentDescription("Stopt de lopende opname en transcribeert.")

    /// Draait in het app-proces. Vraagt de actieve controller (indien er één
    /// draait) om te stoppen; is er geen actieve controller (app opnieuw gestart,
    /// niets aan het opnemen), dan ruimen we alle achtergebleven Live Activities op
    /// zodat de knop nooit "niets" doet.
    func perform() async throws -> some IntentResult {
        await RecordingStopBus.shared.requestStop()
        return .result()
    }
}

/// Procesbrede brug tussen `StopRecordingIntent.perform()` en de per-view
/// `RecordController`-@StateObject die op dat moment de opname draait.
///
/// De controllers zijn per-view, dus de intent kan ze niet direct bereiken.
/// De actieve controller registreert zichzelf (zwak) bij start en deregistreert
/// bij stop. `requestStop()` roept de geregistreerde controller aan; is er niets
/// geregistreerd, dan veegt hij achtergebleven activiteiten op (zombie-sweep).
@MainActor
final class RecordingStopBus {
    static let shared = RecordingStopBus()
    private init() {}

    /// Zwakke referentie: de bus houdt de controller niet in leven. Wordt vanzelf
    /// nil als de view (en dus de @StateObject) verdwijnt.
    private weak var active: RecordingStopHandling?

    func register(_ handler: RecordingStopHandling) {
        active = handler
    }

    /// Deregistreert, maar alleen als `handler` nog de geregistreerde is (voorkomt
    /// dat een oude controller de registratie van een nieuwere wist).
    func deregister(_ handler: RecordingStopHandling) {
        if active === handler {
            active = nil
        }
    }

    func requestStop() async {
        if let active {
            active.stopFromIntent()
        } else {
            // Geen actieve opname bekend in dit proces → alles wat nog op het
            // lock-screen hangt is een zombie. Ruim op.
            await RecordingStopBus.endAllActivities()
        }
    }

    /// Beëindigt alle achtergebleven `RecordingActivityAttributes`-activiteiten
    /// onmiddellijk. Gebruikt door de zombie-sweep (intent-fallback én app-start).
    static func endAllActivities() async {
        for activity in Activity<RecordingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

/// Wat de bus van een controller nodig heeft: één stop-actie die zich exact
/// gedraagt als op de stop-knop tikken (afronden → transcriberen → opslaan →
/// activiteit beëindigen).
@MainActor
protocol RecordingStopHandling: AnyObject {
    func stopFromIntent()
}
