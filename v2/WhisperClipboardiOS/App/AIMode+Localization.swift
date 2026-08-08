import Core
import Foundation

enum AIModeLocalization {
    static func name(for mode: AIMode, language: AppLanguage) -> String {
        name(id: mode.id, fallback: mode.name, language: language)
    }

    static func name(id: String, fallback: String, language: AppLanguage) -> String {
        let locale = language.locale
        switch id {
        case "builtin.samenvatting": return L10n.string( "Slimme samenvatting", locale: locale)
        case "builtin.korte_samenvatting": return L10n.string( "Korte samenvatting", locale: locale)
        case "builtin.uitgebreide_samenvatting": return L10n.string( "Uitgebreide samenvatting", locale: locale)
        case "builtin.belangrijkste_punten": return L10n.string( "Belangrijkste punten", locale: locale)
        case "builtin.redeneringsoverzicht": return L10n.string( "Redeneringsoverzicht", locale: locale)
        case "builtin.actiepunten": return L10n.string( "Actiepunten", locale: locale)
        case "builtin.notulen": return L10n.string( "Notulen", locale: locale)
        case "builtin.doktersafspraak": return L10n.string( "Doktersafspraak", locale: locale)
        case "builtin.vraag_en_antwoord": return L10n.string( "Vraag en antwoord", locale: locale)
        case "builtin.lezing_workshop": return L10n.string( "Lezing of workshop", locale: locale)
        case "builtin.interview": return L10n.string( "Interviewverslag", locale: locale)
        case "builtin.brainstorm": return L10n.string( "Brainstorm", locale: locale)
        case "builtin.klant_adviesgesprek": return L10n.string( "Klant- of adviesgesprek", locale: locale)
        case "builtin.linkedin": return L10n.string( "LinkedIn-post", locale: locale)
        case "builtin.verbeterde_transcriptie": return L10n.string( "Verbeterde transcriptie", locale: locale)
        case "builtin.volledig_transcript": return L10n.string( "Volledig transcript", locale: locale)
        case "builtin.woordenlijst_suggesties": return L10n.string( "Woordenlijstsuggesties", locale: locale)
        default: return localizedBuiltinName(fallback, language: language) ?? fallback
        }
    }

    /// Usage events written by older versions contain a name but no mode id.
    static func localizedBuiltinName(_ name: String, language: AppLanguage) -> String? {
        let mapping: [(String, String)] = [
            ("Slimme samenvatting", "builtin.samenvatting"),
            ("Korte samenvatting", "builtin.korte_samenvatting"),
            ("Uitgebreide samenvatting", "builtin.uitgebreide_samenvatting"),
            ("Belangrijkste punten", "builtin.belangrijkste_punten"),
            ("Redeneringsoverzicht", "builtin.redeneringsoverzicht"),
            ("Actiepunten", "builtin.actiepunten"),
            ("Notulen", "builtin.notulen"),
            ("Doktersafspraak", "builtin.doktersafspraak"),
            ("Vraag en antwoord", "builtin.vraag_en_antwoord"),
            ("Lezing of workshop", "builtin.lezing_workshop"),
            ("Interviewverslag", "builtin.interview"),
            ("Brainstorm", "builtin.brainstorm"),
            ("Klant- of adviesgesprek", "builtin.klant_adviesgesprek"),
            ("LinkedIn-post", "builtin.linkedin"),
            ("Verbeterde transcriptie", "builtin.verbeterde_transcriptie"),
            ("Volledig transcript", "builtin.volledig_transcript"),
            ("Woordenlijstsuggesties", "builtin.woordenlijst_suggesties"),
        ]
        guard let id = mapping.first(where: { $0.0 == name })?.1 else { return nil }
        return self.name(id: id, fallback: name, language: language)
    }
}
