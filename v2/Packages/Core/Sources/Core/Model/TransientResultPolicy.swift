import Foundation

/// Beleid voor het automatisch wissen van de "laatste transcriptie" op het
/// scherm: het resultaat blijft vijf minuten zichtbaar en wordt daarna — bij de
/// eerstvolgende keer dat de app weer in beeld komt — geleegd. Er loopt bewust
/// geen achtergrond-timer (batterij); de check gebeurt op foreground-events.
///
/// Puur en zonder klok-afhankelijkheid (tijd wordt ingegeven), dus volledig
/// unit-testbaar.
public enum TransientResultPolicy {

    /// Hoe lang het laatste resultaat zichtbaar blijft: 5 minuten.
    public static let defaultLifetime: TimeInterval = 300

    /// True wanneer een resultaat dat op `shownAt` verscheen op tijdstip `now`
    /// verlopen is. Een klok die terugloopt (nu vóór `shownAt`) telt als niet
    /// verlopen — liever iets te lang zichtbaar dan onterecht gewist.
    public static func isExpired(
        shownAt: Date,
        now: Date,
        lifetime: TimeInterval = defaultLifetime
    ) -> Bool {
        now.timeIntervalSince(shownAt) >= lifetime
    }
}
