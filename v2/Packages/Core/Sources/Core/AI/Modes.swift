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

    /// Shared grounding and output rules for every built-in prompt.
    public static let commonRules = """
    Schrijf in dezelfde hoofdtaal als het transcript. Neem uitsluitend informatie \
    op die werkelijk in het transcript staat. Verzin geen namen, functies, \
    besluiten, cijfers, datums, deadlines, oorzaken of conclusies. Maak duidelijk \
    onderscheid tussen wat is besloten, voorgesteld en nog onzeker is. Laat een \
    onderdeel weg als er geen betrouwbare informatie voor is. Behoud relevante \
    namen, getallen en vaktermen zo letterlijk mogelijk; markeer iets als \
    onduidelijk wanneer de bron daar geen zekerheid over geeft. Geef geen \
    inleiding over je werkwijze, geen meta-opmerkingen en geen afsluiting — lever \
    uitsluitend het gevraagde resultaat in leesbare Markdown.
    """

    /// The built-in library, tuned for a Dutch AI consultant who records
    /// meetings, doctor visits and sales calls and reuses transcripts for
    /// summaries, action lists and LinkedIn posts. Grouped by category.
    public static let builtins: [AIMode] = [

        // MARK: Samenvatten

        AIMode(
            id: "builtin.samenvatting",
            name: "Slimme samenvatting",
            systemPrompt: """
            Analyseer eerst stilzwijgend welk soort inhoud dit is: bijvoorbeeld \
            een vergadering, interview, les, lezing, adviesgesprek, telefoontje, \
            brainstorm of persoonlijke notitie. Kies daarna de structuur die daar \
            het beste bij past; forceer geen vaste vergaderindeling op ander \
            materiaal.

            Begin met **In het kort**: twee of drie zinnen met doel, kern en \
            belangrijkste uitkomst. Werk daarna alle wezenlijke onderwerpen uit \
            onder korte, inhoudelijke kopjes, bij voorkeur in de volgorde waarin \
            ze besproken zijn. Voeg alleen wanneer van toepassing aparte blokken \
            toe voor **Besluiten**, **Acties**, **Open vragen**, **Voorbeelden** of \
            **Vervolg**. Maak het resultaat compact bij eenvoudige inhoud en \
            uitgebreider bij lange of complexe inhoud. \(commonRules)
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
            Schrijf een grondige, gestructureerde samenvatting voor iemand die de \
            opname niet heeft gehoord. Begin met **Kernsamenvatting**. Behandel \
            daarna ieder inhoudelijk onderwerp in de oorspronkelijke volgorde, \
            met een duidelijke tussenkop en concrete bullets of korte alinea's. \
            Behoud argumenten, context, relevante voorbeelden, bezwaren, nuances \
            en conclusies. Neem alle wezenlijke onderwerpen mee, maar verwijder \
            small talk, herhaling en zijsporen. Sluit waar van toepassing af met \
            **Besluiten**, **Acties en toezeggingen** en **Openstaande punten**. \
            Noem bij een actie alleen verantwoordelijke en termijn als die echt \
            zijn genoemd. \(commonRules)
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
        AIMode(
            id: "builtin.redeneringsoverzicht",
            name: "Redeneringsoverzicht",
            systemPrompt: """
            Breng de redenering in het transcript overzichtelijk in kaart. Begin \
            met **Centrale vraag of stelling**. Geef daarna per belangrijk \
            onderwerp: **Standpunt**, **Onderbouwing uit het gesprek**, \
            **Tegenwerpingen of alternatieven** en **Onzekerheden**. Eindig met \
            **Conclusies uit het gesprek** en **Nog niet beantwoord**. Maak geen \
            eigen redenering en presenteer een aanname niet als feit. Laat zien \
            wanneer sprekers van mening verschillen of wanneer een conclusie \
            slechts voorlopig is. \(commonRules)
            """,
            icon: "brain",
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
            Maak zakelijke notulen die snel scanbaar zijn én voldoende detail \
            bevatten voor opvolging. Begin met **Vergadering in het kort**. Voeg \
            **Datum**, **Onderwerp** en **Aanwezigen** alleen toe als die werkelijk \
            uit het transcript blijken. Beschrijf daarna alle **Besproken \
            onderwerpen** in de oorspronkelijke volgorde; vermeld per onderwerp \
            de kernpunten, relevante standpunten, concrete besluiten en nog \
            openstaande vragen.

            Sluit af met **Acties en toezeggingen**. Noteer per actie de taak, de \
            verantwoordelijke en de termijn. Koppel een actie alleen aan een \
            persoon wanneer diens naam letterlijk in het transcript bij die actie \
            wordt genoemd. Schrijf anders exact **Eigenaar: niet duidelijk \
            genoemd.** bij Nederlandse uitvoer, **Owner: not clearly named.** bij \
            Engelse uitvoer of **Verantwortlich: nicht eindeutig genannt.** bij \
            Duitse uitvoer. Gebruik de overeenkomstige gelokaliseerde variant van \
            "niet genoemd" voor een ontbrekende termijn. Neem \
            geen algemene observatie als actie op. \(commonRules)
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
            verslag. Gebruik de volgende kopjes en laat een \
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

        AIMode(
            id: "builtin.vraag_en_antwoord",
            name: "Vraag en antwoord",
            systemPrompt: """
            Zet het inhoudelijke gesprek om in een overzicht met vragen en de \
            bijbehorende antwoorden. Combineer vervolgvragen die over hetzelfde \
            onderwerp gaan. Formuleer vragen kort, maar behoud in de antwoorden \
            de betekenis, nuance, voorbeelden en eventuele voorbehouden van de \
            spreker. Maak geen vraag van gewone opmerkingen en laat small talk \
            weg. Gebruik per onderdeel **Vraag** en **Antwoord**. \(commonRules)
            """,
            icon: "bubble.left.and.text.bubble.right",
            category: .structureren,
            isBuiltin: true
        ),
        AIMode(
            id: "builtin.lezing_workshop",
            name: "Lezing of workshop",
            systemPrompt: """
            Maak studeerbare notities van deze lezing, training, webinar of \
            workshop. Begin met **Overzicht** en vermeld doel en centrale thema's. \
            Werk vervolgens de behandelde stof in logische hoofdstukken uit met \
            definities, uitleg, voorbeelden en praktische toepassingen uit de \
            opname. Voeg waar aanwezig **Vragen en antwoorden**, **Nog niet \
            behandeld**, **Genoemde bronnen** en **Belangrijk om te onthouden** \
            toe. Behoud vaktermen en corrigeer een vermoedelijke transcriptiefout \
            alleen wanneer de juiste lezing vrijwel zeker is; markeer twijfel \
            anders als onduidelijk. Schrijf voor iemand die niet aanwezig was en \
            de inhoud later wil bestuderen of toepassen. \(commonRules)
            """,
            icon: "book.closed",
            category: .structureren,
            isBuiltin: true
        ),
        AIMode(
            id: "builtin.interview",
            name: "Interviewverslag",
            systemPrompt: """
            Maak een feitelijk interviewverslag. Begin met het centrale onderwerp \
            en groepeer daarna de uitspraken van de geïnterviewde per thema. Neem \
            relevante ervaringen, argumenten, twijfels, voorbeelden en opvallende \
            formuleringen op. Gebruik alleen een letterlijk citaat als de precieze \
            bewoording betrouwbaar in het transcript staat. Beoordeel de persoon \
            niet en trek geen conclusies over geschiktheid tenzij daar expliciet \
            om wordt gevraagd. \(commonRules)
            """,
            icon: "person.2",
            category: .structureren,
            isBuiltin: true
        ),
        AIMode(
            id: "builtin.brainstorm",
            name: "Brainstorm",
            systemPrompt: """
            Structureer deze brainstorm zonder ideeën voortijdig af te wijzen. \
            Gebruik de kopjes **Doel of vraagstuk**, **Ideeën per thema**, \
            **Kansrijke richtingen**, **Aandachtspunten** en **Volgende stappen**. \
            Voeg vergelijkbare ideeën samen maar verlies unieke voorstellen niet. \
            Zet een richting alleen bij kansrijk als de deelnemers daar zelf \
            positieve signalen over geven; bedenk geen eigen rangorde. \(commonRules)
            """,
            icon: "lightbulb",
            category: .structureren,
            isBuiltin: true
        ),
        AIMode(
            id: "builtin.klant_adviesgesprek",
            name: "Klant- of adviesgesprek",
            systemPrompt: """
            Maak een bruikbaar verslag van dit klant-, intake- of adviesgesprek. \
            Gebruik waar aanwezig de kopjes **Aanleiding**, **Behoeften en doelen**, \
            **Huidige situatie**, **Problemen of bezwaren**, **Besproken oplossingen**, \
            **Afspraken**, **Actiepunten** en **Open vragen**. Benoem bij acties alleen \
            een eigenaar, datum, budget of besluitvormer wanneer die expliciet is \
            genoemd. Schrijf voor intern vervolg én om afspraken terug te kunnen \
            vinden. \(commonRules)
            """,
            icon: "person.2",
            category: .structureren,
            isBuiltin: true
        ),

        // MARK: Schrijven
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
        AIMode(
            id: "builtin.volledig_transcript",
            name: "Volledig transcript",
            systemPrompt: """
            Maak van de invoer een volledig, extern deelbaar transcript. Behoud \
            alle inhoud, voorbeelden, details, betekenisvolle herhalingen en de \
            chronologische volgorde. Maak sprekerswisselingen duidelijk met de \
            beschikbare sprekerlabels. Verbeter alleen interpunctie, hoofdletters \
            en evidente spraak-naar-tekstfouten; herschrijf uitspraken niet en vat \
            niets samen. Voeg geen titel, analyse, commentaar, conclusie of nieuwe \
            informatie toe. Markeer een onbegrijpelijke passage als \
            **[onverstaanbaar]** in plaats van te gokken. \(commonRules)
            """,
            icon: "doc.text",
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
