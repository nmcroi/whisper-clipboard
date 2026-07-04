import ActivityKit
import Foundation

/// Live Activity attributes voor een lopende opname.
///
/// Dit bestand wordt in ZOWEL de app als de widget-extensie meegecompileerd
/// (zie beide targets in `project.yml`). Het staat bewust NIET in
/// `WhisperShared`: dat pakket sleept GRDB + FluidAudio mee en die horen niet in
/// de lichte widget-extensie. Alle data reist via de `ContentState`, dus er is
/// géén App Group nodig.
struct RecordingActivityAttributes: ActivityAttributes {
    /// De dynamische, per-update-verversbare toestand van de opname.
    public struct ContentState: Codable, Hashable {
        /// Recente, gladgestreken microfoonniveaus (0…1) — voedt de equalizer-
        /// balken zodat ze onderling verschillen. Meestal 6–8 waarden.
        var levels: [Double]
        /// Wanneer de opname begon. De widget toont hiermee een native tikkende
        /// timer (geen verdere updates nodig).
        var startedAt: Date
        /// Of de opname momenteel gepauzeerd is door een onderbreking
        /// (telefoon, Siri, …).
        var isPaused: Bool
    }

    /// Statische, niet-veranderende identiteit van de activiteit. Leeg: alle
    /// zichtbare data zit in `ContentState`.
    // (bewust geen velden — houdt de attributes klein en Codable-simpel)
}
