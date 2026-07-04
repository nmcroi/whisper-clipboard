import Foundation

/// The display category a mode is grouped under in the chip row and settings
/// editor. Ordered as the raw array (`allCases`) for a stable UI order.
public enum AIModeCategory: String, Codable, CaseIterable, Sendable {
    case samenvatten = "Samenvatten"
    case structureren = "Structureren"
    case schrijven = "Schrijven"
    case opschonen = "Opschonen"

    /// SF Symbol shown next to the category heading.
    public var icon: String {
        switch self {
        case .samenvatten: return "text.alignleft"
        case .structureren: return "list.bullet.rectangle"
        case .schrijven: return "square.and.pencil"
        case .opschonen: return "sparkles"
        }
    }
}

/// An AI post-processing "mode": a named instruction (system prompt) applied to
/// a transcript to produce a derived result (summary, action items, email, …).
///
/// Built-in modes ship with the app and are read-only (but duplicatable).
/// User-defined modes are persisted as JSON in Application Support.
public struct AIMode: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var systemPrompt: String
    /// SF Symbol name shown on the chip / in the editor.
    public var icon: String
    /// The group this mode is displayed under.
    public var category: AIModeCategory
    public var isBuiltin: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        systemPrompt: String,
        icon: String,
        category: AIModeCategory = .schrijven,
        isBuiltin: Bool = false
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.icon = icon
        self.category = category
        self.isBuiltin = isBuiltin
    }

    enum CodingKeys: String, CodingKey {
        case id, name, systemPrompt, icon, category, isBuiltin
    }

    /// Custom decode so older `modes.json` files (written before `category`
    /// existed) still load — a missing category defaults to "Schrijven".
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        icon = try container.decode(String.self, forKey: .icon)
        category = try container.decodeIfPresent(AIModeCategory.self, forKey: .category) ?? .schrijven
        isBuiltin = try container.decodeIfPresent(Bool.self, forKey: .isBuiltin) ?? false
    }
}

extension AIMode {
    /// The small SF Symbol set offered in the custom-mode icon picker.
    public static let iconChoices: [String] = [
        "sparkles",
        "text.alignleft",
        "text.justify",
        "list.bullet.clipboard",
        "cross.case",
        "checklist",
        "list.bullet",
        "envelope",
        "megaphone",
        "bubble.left.and.text.bubble.right",
        "doc.text",
        "quote.bubble",
        "lightbulb",
        "wand.and.stars",
        "brain",
    ]

    /// A shared instruction appended conceptually to every built-in prompt:
    /// answer in the transcript's language, no preamble, output only the result.
    public static let commonRules = """
    Schrijf je antwoord in de taal van het transcript (meestal Nederlands). \
    Geef geen inleiding, geen meta-opmerkingen en geen afsluiting — lever \
    uitsluitend het gevraagde resultaat.
    """

    /// The built-in library, tuned for a Dutch AI consultant who records
    /// meetings, doctor visits and sales calls and reuses transcripts for
    /// summaries, action lists and LinkedIn posts. Grouped by category.
    public static let builtins: [AIMode] = [

        // MARK: Samenvatten

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
            category: .samenvatten,
            isBuiltin: true
        ),
        AIMode(
            id: "builtin.korte_samenvatting",
            name: "Korte samenvatting",
            systemPrompt: """
            Vat het transcript samen in maximaal drie zinnen. Geef alleen de \
            absolute kern: waar ging het over, wat is er besloten of afgesproken, \
            en wat is de belangrijkste uitkomst. Geen bullets, geen details, \
            geen opsomming van sprekers. \(commonRules)
            """,
            icon: "text.append",
            category: .samenvatten,
            isBuiltin: true
        ),
        AIMode(
            id: "builtin.uitgebreide_samenvatting",
            name: "Uitgebreide samenvatting",
            systemPrompt: """
            Schrijf een uitgebreide, gestructureerde samenvatting van het \
            transcript in het Nederlands. Gebruik korte kopjes voor de \
            verschillende onderwerpen die aan bod komen, en werk elk onderwerp \
            uit in een alinea of bulletlijst. Behoud nuance, context en \
            belangrijke details, maar laat spreektaal, herhaling en zijsporen \
            weg. Sluit af met een kort kopje met eventuele open vragen of \
            vervolgstappen als die in het gesprek naar voren komen. \(commonRules)
            """,
            icon: "text.justify",
            category: .samenvatten,
            isBuiltin: true
        ),
        AIMode(
            id: "builtin.belangrijkste_punten",
            name: "Belangrijkste punten",
            systemPrompt: """
            Haal de belangrijkste punten uit het transcript en geef ze als een \
            heldere bulletlijst. Eén punt per regel, elk punt kort en concreet \
            geformuleerd. Rangschik van belangrijk naar minder belangrijk. Neem \
            geen small talk, herhaling of vulwoorden op. \(commonRules)
            """,
            icon: "list.bullet",
            category: .samenvatten,
            isBuiltin: true
        ),

        // MARK: Structureren

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
            category: .structureren,
            isBuiltin: true
        ),
        AIMode(
            id: "builtin.notulen",
            name: "Notulen",
            systemPrompt: """
            Maak beknopte notulen van deze vergadering in het Nederlands. \
            Gebruik de volgende kopjes, en laat een kopje weg als er geen \
            informatie voor is:

            **Aanwezigen** — alleen als de deelnemers uit het transcript af te \
            leiden zijn.
            **Onderwerpen** — korte bulletlijst van wat er besproken is.
            **Besluiten** — wat is er concreet besloten.
            **Actiepunten** — per punt de taak, en eigenaar en deadline als \
            genoemd (formaat: "— [eigenaar] · [deadline]").

            Wees feitelijk en zakelijk; verzin geen aanwezigen of besluiten die \
            er niet zijn. \(commonRules)
            """,
            icon: "list.bullet.clipboard",
            category: .structureren,
            isBuiltin: true
        ),
        AIMode(
            id: "builtin.doktersafspraak",
            name: "Doktersafspraak",
            systemPrompt: """
            Zet dit gesprek met een arts of zorgverlener om in een overzichtelijk \
            verslag in het Nederlands. Gebruik de volgende kopjes en laat een \
            kopje weg als er niets over gezegd is:

            **Klachten** — de gemelde klachten of symptomen.
            **Bevindingen** — wat de arts heeft vastgesteld of onderzocht.
            **Advies** — het gegeven advies of de uitleg.
            **Medicatie** — voorgeschreven of besproken medicijnen, met dosering \
            als genoemd.
            **Afspraken** — gemaakte afspraken.
            **Vervolgstappen** — controles, verwijzingen of wat de patiënt zelf \
            moet doen.

            Blijf strikt bij wat er in het gesprek is gezegd; geef geen eigen \
            medisch advies en verzin geen diagnoses. \(commonRules)
            """,
            icon: "cross.case",
            category: .structureren,
            isBuiltin: true
        ),

        // MARK: Schrijven

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
            category: .schrijven,
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
            category: .schrijven,
            isBuiltin: true
        ),

        // MARK: Opschonen

        AIMode(
            id: "builtin.verbeterde_transcriptie",
            name: "Verbeterde transcriptie",
            systemPrompt: """
            Schoon dit transcript op zonder de inhoud te veranderen. Verwijder \
            stopwoorden en vulwoorden ("uh", "eh", "weet je", "zeg maar"), \
            herhalingen en valse starts. Herstel duidelijke spraak-naar-tekst \
            fouten en zet de tekst in nette zinnen met correcte interpunctie en \
            hoofdletters. Behoud de oorspronkelijke betekenis, toon en taal \
            volledig, en vat NIET samen — lever de volledige, leesbare tekst. \
            \(commonRules)
            """,
            icon: "sparkles",
            category: .opschonen,
            isBuiltin: true
        ),
    ]

    /// Built-in modes grouped by category, in category order, ready for a
    /// sectioned display. Only categories that actually have modes appear.
    public static func grouped(_ modes: [AIMode]) -> [(category: AIModeCategory, modes: [AIMode])] {
        AIModeCategory.allCases.compactMap { category in
            let matching = modes.filter { $0.category == category }
            return matching.isEmpty ? nil : (category, matching)
        }
    }
}
