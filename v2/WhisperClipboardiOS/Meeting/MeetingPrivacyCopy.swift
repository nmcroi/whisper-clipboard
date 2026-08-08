import Foundation

/// Voorlopige, versievaste aanwezigen-uitleg uit `FINAL_RUN_IPHONE.md`.
/// Definitieve voice-overs kunnen later worden toegevoegd zonder deze route of
/// de opnamebediening te wijzigen.
struct MeetingPrivacyCopy {
    struct Card: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let text: String
    }

    let title: String
    let subtitle: String
    let cards: [Card]
    let spokenText: String
    let play: String
    let stop: String
    let voiceHint: String
    let voiceAccessibilityHint: String

    static func make(languageCode: String, includesAI: Bool) -> Self {
        switch languageCode {
        case "en": english(includesAI: includesAI)
        case "de": german(includesAI: includesAI)
        default: dutch(includesAI: includesAI)
        }
    }

    private static func dutch(includesAI: Bool) -> Self {
        let intro = "De app helpt vergaderingen notuleren door het gesproken gesprek lokaal op deze zichtbare telefoon te transcriberen."
        let pause = "Wil iemand iets buiten de notulen bespreken, dan wordt de opname gepauzeerd. Wat tijdens die pauze wordt gezegd, wordt niet opgenomen en komt dus niet in de transcriptie."
        let after = "Aan het einde van de vergadering wordt de transcriptie afgerond. De geluidsopname wordt daarna van de telefoon verwijderd. Vervolgens wordt een e-mail voorbereid voor iedereen die voor deze vergadering een e-mailadres heeft opgegeven; iedereen ontvangt hetzelfde verslag nadat de gebruiker de e-mail heeft verstuurd."
        let help = "De notulist verwerkt alleen geluid. Beschrijf daarom kort wat op een scherm of whiteboard gebeurt en spel bijzondere namen of termen. Een lokaal transcriptiemodel kan woorden verkeerd of fonetisch uitschrijven, maar zulke fouten zijn bij het nalezen meestal uit de context te herstellen."
        let final = includesAI
            ? "Voor deze vergadering is aanvullend AI-verslag aangezet. De transcriptietekst wordt daarom na afloop ook door een externe AI-dienst verwerkt tot bijvoorbeeld een samenvatting en actiepunten. De volledige oorspronkelijke transcriptie blijft onderdeel van het verslag."
            : "Nergens tijdens dit proces wordt AI gebruikt."
        return copy(
            title: "WhisperClip Notulist",
            subtitle: "Korte uitleg voor de aanwezigen",
            headings: ("Wat deze notulist doet", "Privacy tijdens de vergadering", "Na afloop", "Help de transcriptie", includesAI ? "Aanvullend AI-verslag" : "Zonder AI"),
            texts: (intro, pause, after, help, final),
            spoken: "Dit is de WhisperClip Notulist. \(intro) \(pause) \(after) \(help) \(final)",
            play: "Lees voor aan aanwezigen",
            stop: "Stop voorlezen",
            hint: "Voorlezen start geen opname en bewaart niets extra's.",
            accessibilityHint: "Speelt alleen de uitleg af en start geen opname"
        )
    }

    private static func english(includesAI: Bool) -> Self {
        let intro = "The app helps take minutes by transcribing the spoken conversation locally on this visible phone."
        let pause = "If anyone wants to discuss something off the record, the recording will be paused. Anything said during that pause is not recorded and will not appear in the transcript."
        let after = "At the end of the meeting, the transcript is completed. The audio recording is then removed from the phone. An email is prepared for everyone who provided an email address for this meeting; everyone receives the same report after the user sends the email."
        let help = "The minute taker processes sound only. Briefly describe anything shown on a screen or whiteboard, and spell unusual names or terms. A local transcription model may write words incorrectly or phonetically, but these errors can usually be resolved from context during review."
        let final = includesAI
            ? "An additional AI report has been enabled for this meeting. After the meeting, the transcript text is also processed by an external AI service to create items such as a summary and action points. The full original transcript remains part of the report."
            : "AI is not used anywhere in this process."
        return copy(
            title: "WhisperClip Minute Taker",
            subtitle: "Brief explanation for everyone present",
            headings: ("What this minute taker does", "Privacy during the meeting", "After the meeting", "Help the transcription", includesAI ? "Additional AI report" : "No AI"),
            texts: (intro, pause, after, help, final),
            spoken: "This is the WhisperClip Minute Taker. \(intro) \(pause) \(after) \(help) \(final)",
            play: "Read aloud to attendees",
            stop: "Stop reading",
            hint: "Reading this aloud does not start a recording or save anything extra.",
            accessibilityHint: "Only reads the explanation aloud and does not start a recording"
        )
    }

    private static func german(includesAI: Bool) -> Self {
        let intro = "Die App unterstützt bei der Protokollierung, indem sie das gesprochene Gespräch lokal auf diesem sichtbaren Telefon transkribiert."
        let pause = "Möchte jemand etwas außerhalb des Protokolls besprechen, wird die Aufnahme pausiert. Was während dieser Pause gesagt wird, wird nicht aufgenommen und erscheint daher nicht im Transkript."
        let after = "Am Ende der Besprechung wird das Transkript fertiggestellt. Anschließend wird die Audioaufnahme vom Telefon entfernt. Danach wird eine E-Mail für alle vorbereitet, die für diese Besprechung eine E-Mail-Adresse angegeben haben; alle erhalten denselben Bericht, nachdem der Benutzer die E-Mail gesendet hat."
        let help = "Die Protokollfunktion verarbeitet ausschließlich Ton. Beschreiben Sie deshalb kurz, was auf einem Bildschirm oder Whiteboard geschieht, und buchstabieren Sie besondere Namen oder Begriffe. Ein lokales Transkriptionsmodell kann Wörter falsch oder phonetisch schreiben; solche Fehler lassen sich beim Durchlesen meist aus dem Zusammenhang klären."
        let final = includesAI
            ? "Für diese Besprechung wurde zusätzlich ein KI-Bericht aktiviert. Der Transkripttext wird daher nach der Besprechung auch von einem externen KI-Dienst verarbeitet, beispielsweise zu einer Zusammenfassung und Aktionspunkten. Das vollständige ursprüngliche Transkript bleibt Bestandteil des Berichts."
            : "In diesem gesamten Prozess wird keine KI verwendet."
        return copy(
            title: "WhisperClip Protokoll",
            subtitle: "Kurze Erklärung für alle Anwesenden",
            headings: ("Was diese Protokollfunktion tut", "Datenschutz während der Besprechung", "Nach der Besprechung", "Unterstützen Sie die Transkription", includesAI ? "Zusätzlicher KI-Bericht" : "Ohne KI"),
            texts: (intro, pause, after, help, final),
            spoken: "Dies ist die WhisperClip Protokollfunktion. \(intro) \(pause) \(after) \(help) \(final)",
            play: "Anwesenden vorlesen",
            stop: "Vorlesen beenden",
            hint: "Das Vorlesen startet keine Aufnahme und speichert keine zusätzlichen Daten.",
            accessibilityHint: "Liest nur die Erklärung vor und startet keine Aufnahme"
        )
    }

    private static func copy(
        title: String,
        subtitle: String,
        headings: (String, String, String, String, String),
        texts: (String, String, String, String, String),
        spoken: String,
        play: String,
        stop: String,
        hint: String,
        accessibilityHint: String
    ) -> Self {
        Self(
            title: title,
            subtitle: subtitle,
            cards: [
                Card(id: "purpose", title: headings.0, symbol: "person.2.wave.2.fill", text: texts.0),
                Card(id: "pause", title: headings.1, symbol: "pause.circle.fill", text: texts.1),
                Card(id: "after", title: headings.2, symbol: "envelope.fill", text: texts.2),
                Card(id: "help", title: headings.3, symbol: "text.bubble.fill", text: texts.3),
                Card(id: "ai", title: headings.4, symbol: "sparkles", text: texts.4),
            ],
            spokenText: spoken,
            play: play,
            stop: stop,
            voiceHint: hint,
            voiceAccessibilityHint: accessibilityHint
        )
    }
}
