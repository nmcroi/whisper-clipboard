import Foundation

/// Pauze-bewuste opnameklok: telt alleen de tijd waarin er écht wordt
/// opgenomen, niet de gepauzeerde stukken. Puur — de tijd wordt ingegeven
/// (uptime-seconden of een testwaarde), er zit geen klok in — dus volledig
/// unit-testbaar en bruikbaar op Mac én iOS.
///
/// Gebruik: `start(at:)` bij opnamestart, `pause(at:)`/`resume(at:)` rond een
/// pauze, `elapsed(at:)` voor de weergegeven tijd. Dubbel pauzeren of hervatten
/// is een no-op, zodat aanroepers geen eigen toestand hoeven bij te houden.
public struct RecordingStopwatch: Sendable, Equatable {

    /// Opgetelde opnametijd van afgeronde (ge-resumede) stukken.
    private var accumulated: Double = 0
    /// Tijdstip waarop het huidige stuk begon te lopen; nil = gepauzeerd/gestopt.
    private var runningSince: Double?

    public init() {}

    /// True zolang de klok loopt (gestart en niet gepauzeerd).
    public var isRunning: Bool { runningSince != nil }

    /// Reset en begin te lopen.
    public mutating func start(at now: Double) {
        accumulated = 0
        runningSince = now
    }

    /// Bevries de klok. No-op wanneer hij al stilstaat.
    public mutating func pause(at now: Double) {
        guard let since = runningSince else { return }
        accumulated += max(0, now - since)
        runningSince = nil
    }

    /// Laat de klok weer lopen. No-op wanneer hij al loopt.
    public mutating func resume(at now: Double) {
        guard runningSince == nil else { return }
        runningSince = now
    }

    /// Stop en reset naar nul (voor de volgende opname).
    public mutating func stopAndReset() {
        accumulated = 0
        runningSince = nil
    }

    /// De opgenomen tijd tot `now`, exclusief gepauzeerde stukken.
    public func elapsed(at now: Double) -> Double {
        guard let since = runningSince else { return accumulated }
        return accumulated + max(0, now - since)
    }
}
