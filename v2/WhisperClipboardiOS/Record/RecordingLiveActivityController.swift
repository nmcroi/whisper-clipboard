import ActivityKit
import Foundation

/// Beheert de Live Activity (Dynamic Island + lock-screen banner) voor één
/// opname-sessie.
///
/// Start de activiteit wanneer de opname begint, ververst de niveau-samples op
/// een getemperde cadans (ActivityKit knijpt agressieve lokale updates af, dus
/// ~elke 0,8 s), en beëindigt de activiteit altijd — óók op foutpaden — zodat er
/// nooit een zombie-activiteit blijft hangen.
///
/// Alles is defensief: als Live Activities uitstaan of een aanroep faalt, doen we
/// stilletjes niets in plaats van te crashen.
@MainActor
final class RecordingLiveActivityController {

    private var activity: Activity<RecordingActivityAttributes>?
    private var startedAt: Date?
    /// Ringbuffer met de recentste niveaus; elke update stuurt de laatste N mee.
    private var recentLevels: [Double] = []
    private let sampleCount = 7

    /// Minimale tijd tussen ContentState-updates (ActivityKit-throttling).
    private let updateInterval: TimeInterval = 0.8
    private var lastUpdate: Date = .distantPast
    private var isPaused = false

    /// Hoe lang na de laatste content-update de activiteit als "stale" geldt. Een
    /// dood app-proces stopt met verversen → het systeem markeert de activiteit
    /// stale en de widget toont dan een "Opname gestopt?"-hint i.p.v. te doen
    /// alsof er nog wordt opgenomen.
    private let staleAfter: TimeInterval = 120

    private func staleDate(from now: Date = Date()) -> Date {
        now.addingTimeInterval(staleAfter)
    }

    // MARK: - Start

    /// Start de Live Activity, mits de gebruiker ze heeft toegestaan. Faalt stil.
    func start() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Ruim een eventueel eerder blijven hangende activiteit op.
        end()

        let now = Date()
        startedAt = now
        isPaused = false
        recentLevels = Array(repeating: 0, count: sampleCount)
        lastUpdate = .distantPast

        let state = RecordingActivityAttributes.ContentState(
            levels: recentLevels,
            startedAt: now,
            isPaused: false
        )
        do {
            activity = try Activity.request(
                attributes: RecordingActivityAttributes(),
                content: .init(state: state, staleDate: staleDate(from: now))
            )
        } catch {
            // Live Activity kon niet starten — geen ramp, opname loopt gewoon door.
            activity = nil
            startedAt = nil
        }
    }

    // MARK: - Update

    /// Voedt één (gladgestreken) niveau in. De widget-balken worden op een
    /// getemperde cadans bijgewerkt met de recentste `sampleCount` waarden.
    func push(level: Double) {
        guard activity != nil, let startedAt else { return }
        recentLevels.append(min(max(level, 0), 1))
        if recentLevels.count > sampleCount {
            recentLevels.removeFirst(recentLevels.count - sampleCount)
        }

        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= updateInterval else { return }
        lastUpdate = now
        pushState(startedAt: startedAt)
    }

    /// Zet de pauze-vlag en ververst meteen (los van de throttle) zodat de
    /// widget de pauze direct toont.
    func setPaused(_ paused: Bool) {
        guard activity != nil, let startedAt else { return }
        isPaused = paused
        lastUpdate = Date()
        pushState(startedAt: startedAt)
    }

    private func pushState(startedAt: Date) {
        guard let activity else { return }
        let state = RecordingActivityAttributes.ContentState(
            levels: recentLevels,
            startedAt: startedAt,
            isPaused: isPaused
        )
        let content = ActivityContent(state: state, staleDate: staleDate())
        // `Activity` is Sendable en de handle is procesbreed thread-safe, dus een
        // update van buiten de main actor is veilig. `nonisolated(unsafe)` haalt
        // de main-actor-regio-attributie van de gedeelde handle af zodat Swift 6
        // strict-concurrency de detached update accepteert.
        nonisolated(unsafe) let handle = activity
        Task.detached { await handle.update(content) }
    }

    // MARK: - End

    /// Beëindigt de activiteit onmiddellijk. Idempotent — veilig meermaals aan te
    /// roepen (stop, annuleer, foutpad).
    func end() {
        guard let activity else { return }
        self.activity = nil
        startedAt = nil
        isPaused = false
        recentLevels = []
        nonisolated(unsafe) let handle = activity
        Task.detached { await handle.end(nil, dismissalPolicy: .immediate) }
    }
}
