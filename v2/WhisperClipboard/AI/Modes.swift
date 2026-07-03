import Foundation

/// An AI post-processing "mode": a named instruction (system prompt) applied to
/// a transcript to produce a derived result (summary, action items, email, …).
///
/// Built-in modes ship with the app and are read-only (but duplicatable).
/// User-defined modes are persisted as JSON in Application Support.
struct AIMode: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var systemPrompt: String
    /// SF Symbol name shown on the chip / in the editor.
    var icon: String
    var isBuiltin: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        systemPrompt: String,
        icon: String,
        isBuiltin: Bool = false
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.icon = icon
        self.isBuiltin = isBuiltin
    }
}

extension AIMode {
    /// The small SF Symbol set offered in the custom-mode icon picker.
    static let iconChoices: [String] = [
        "sparkles",
        "text.alignleft",
        "checklist",
        "envelope",
        "megaphone",
        "bubble.left.and.text.bubble.right",
        "doc.text",
        "list.bullet",
        "quote.bubble",
        "lightbulb",
        "wand.and.stars",
        "brain",
    ]

    /// A shared instruction appended conceptually to every built-in prompt:
    /// answer in the transcript's language, no preamble, output only the result.
    private static let commonRules = """
    Schrijf je antwoord in de taal van het transcript (meestal Nederlands). \
    Geef geen inleiding, geen meta-opmerkingen en geen afsluiting — lever \
    uitsluitend het gevraagde resultaat.
    """

    /// The four built-in modes, tuned for a Dutch AI consultant who reuses
    /// transcripts for LinkedIn posts and client work.
    static let builtins: [AIMode] = [
        AIMode(
            id: "builtin.samenvatting",
            name: "Samenvatting",
            systemPrompt: """
            Je bent een scherpe redacteur. Vat het onderstaande transcript bondig \
            samen in het Nederlands. Begin met één of twee zinnen die de kern \
            weergeven, gevolgd door een korte bulletlijst met de belangrijkste \
            punten. Houd het compact en zakelijk; laat herhaling en \
            spreektaal-vulwoorden weg. \(commonRules)
            """,
            icon: "text.alignleft",
            isBuiltin: true
        ),
        AIMode(
            id: "builtin.actiepunten",
            name: "Actiepunten",
            systemPrompt: """
            Je bent een assistent die concrete actiepunten uit een transcript \
            haalt. Geef een bulletlijst met heldere, uitvoerbare taken. Noem per \
            actiepunt de eigenaar en de deadline wanneer die in het transcript \
            genoemd worden (formaat: "— [eigenaar] · [deadline]"). Neem alleen \
            echte acties op, geen algemene observaties. \(commonRules)
            """,
            icon: "checklist",
            isBuiltin: true
        ),
        AIMode(
            id: "builtin.email",
            name: "E-mail",
            systemPrompt: """
            Zet het transcript om in een professionele maar warme Nederlandse \
            e-mail. Gebruik een passende aanhef en afsluiting, korte alinea's en \
            een duidelijke, vriendelijke toon. Behoud de intentie en de \
            belangrijkste punten van de spreker; laat spreektaal en herhaling \
            weg. \(commonRules)
            """,
            icon: "envelope",
            isBuiltin: true
        ),
        AIMode(
            id: "builtin.linkedin",
            name: "LinkedIn-post",
            systemPrompt: """
            Herschrijf het transcript tot een pakkende Nederlandse LinkedIn-post \
            in de eigen stem van de spreker. Begin met een sterke openingszin, \
            houd de alinea's kort en luchtig, en eindig met een uitnodiging tot \
            reactie of een prikkelende gedachte. Vermijd clichés, corporate \
            jargon en hashtag-spam (hooguit een paar relevante hashtags). \
            \(commonRules)
            """,
            icon: "megaphone",
            isBuiltin: true
        ),
    ]
}
