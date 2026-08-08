import Foundation

/// Eén e-mailontvanger van een notulenverslag. Een ontbrekend e-mailadres is
/// ongeldig: aanwezigen zonder adres worden niet als deelnemer bijgehouden.
public struct MeetingParticipant: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var email: String?

    public init(id: UUID = UUID(), name: String, email: String? = nil) {
        self.id = id
        self.name = name
        self.email = email
    }

    /// Geldig als ontvanger: een niet-lege naam en een plausibel e-mailadres.
    public var isValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        guard let email else { return false }
        return Self.isPlausibleEmail(email)
    }

    /// Bewust lichte check — geen RFC-parser: iets@iets.iets volstaat om
    /// tikfouten als "naam@bedrijf" te vangen.
    public static func isPlausibleEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@"), at != trimmed.startIndex else { return false }
        let domain = trimmed[trimmed.index(after: at)...]
        guard let dot = domain.firstIndex(of: "."), dot != domain.startIndex else { return false }
        return domain.index(after: dot) != domain.endIndex && !trimmed.contains(" ")
    }
}

/// Een herbruikbare persoon voor de Notulen-kiezer. `isMe` markeert de eigenaar
/// van het toestel, zodat die standaard alvast geselecteerd kan worden.
public struct SavedMeetingContact: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var email: String
    public var isMe: Bool

    public init(id: UUID = UUID(), name: String, email: String = "", isMe: Bool = false) {
        self.id = id
        self.name = name
        self.email = email
        self.isMe = isMe
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && MeetingParticipant.isPlausibleEmail(email)
    }
}

/// Kleine, platformonafhankelijke bewerking voor het bewust bewaren van een
/// Notulist-ontvanger. Het e-mailadres is de unieke sleutel; opnieuw bewaren
/// werkt naam/adres bij zonder de bestaande `Dit ben ik`-markering te verliezen.
public enum MeetingContactList {
    public static func saving(
        _ participant: MeetingParticipant,
        in contacts: [SavedMeetingContact]
    ) -> [SavedMeetingContact] {
        guard participant.isValid,
              let email = participant.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return contacts }

        let name = participant.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = contacts
        if let index = result.firstIndex(where: {
            $0.email.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(email) == .orderedSame
        }) {
            result[index].name = name
            result[index].email = email
        } else {
            result.append(SavedMeetingContact(name: name, email: email))
        }
        return result
    }
}

/// Taal van het gedeelde Notulist-verslag. Dit staat los van de gesproken
/// transcriptietaal: de interfacekeuze bepaalt de taal van mail en uitleg.
public enum MeetingReportLanguage: String, Codable, CaseIterable, Sendable {
    case dutch = "nl"
    case english = "en"
    case german = "de"

    fileprivate var localeIdentifier: String {
        switch self {
        case .dutch: "nl_NL"
        case .english: "en_US"
        case .german: "de_DE"
        }
    }
}

/// Stelt de notulen-mail samen: onderwerp, ontvangers, en één identieke
/// berichttekst voor iedereen — transcript plus de vaste transparantie-uitleg.
/// Puur Foundation, dus volledig unit-testbaar (ook in de Linux-CI).
public enum MeetingMinutesComposer {

    /// De vaste, feitelijke uitleg die onder elk verslag staat. De zes punten
    /// volgen het proces van de notulist-modus en zijn geformuleerd conform wat
    /// de app werkelijk doet: audio staat alleen tijdelijk en beschermd in de
    /// appcontainer en wordt na de lokale transcriptie verwijderd.
    public static let transparencyText = transparencyText(language: .dutch, usedAI: false)

    public static func transparencyText(
        language: MeetingReportLanguage,
        usedAI: Bool
    ) -> String {
        switch (language, usedAI) {
        case (.dutch, false):
            """
            Over dit verslag:
            1. Het gesprek is lokaal op het opnametoestel getranscribeerd.
            2. De audio bestond alleen tijdelijk lokaal op het toestel dat opnam — nooit in de cloud.
            3. De transcriptie is gemaakt door een lokaal taalmodel op dat toestel; er is geen externe AI-dienst gebruikt.
            4. De audio is direct gewist zodra de tekst klaar was.
            5. Iedereen op de verzendlijst ontvangt exact hetzelfde bericht.
            6. Gepauzeerde delen van het gesprek zijn nergens in opgenomen — ook niet in deze tekst.
            """
        case (.dutch, true):
            """
            Over dit verslag:
            1. Het gesprek is lokaal op het opnametoestel getranscribeerd.
            2. De audio bestond alleen tijdelijk lokaal op het toestel dat opnam — nooit in de cloud en nooit bij de AI-dienst.
            3. Alleen de transcriptietekst is door de gekozen externe AI-dienst verwerkt tot AI-notulen.
            4. De audio is direct gewist zodra de tekst klaar was.
            5. Iedereen op de verzendlijst ontvangt exact hetzelfde bericht, inclusief de volledige onbewerkte transcriptie.
            6. Gepauzeerde delen van het gesprek zijn nergens in opgenomen — ook niet in deze tekst.
            """
        case (.english, false):
            """
            About this report:
            1. The conversation was transcribed locally on the recording device.
            2. Audio existed only temporarily and locally on the recording device — never in the cloud.
            3. The transcript was created by a local language model on that device; no external AI service was used.
            4. The audio was erased immediately after the text was ready.
            5. Everyone on the recipient list receives exactly the same message.
            6. Paused parts of the conversation were not recorded anywhere — including in this text.
            """
        case (.english, true):
            """
            About this report:
            1. The conversation was transcribed locally on the recording device.
            2. Audio existed only temporarily and locally on the recording device — never in the cloud or at the AI service.
            3. Only the transcript text was processed by the selected external AI service to create the AI minutes.
            4. The audio was erased immediately after the text was ready.
            5. Everyone on the recipient list receives exactly the same message, including the full unedited transcript.
            6. Paused parts of the conversation were not recorded anywhere — including in this text.
            """
        case (.german, false):
            """
            Über diesen Bericht:
            1. Das Gespräch wurde lokal auf dem Aufnahmegerät transkribiert.
            2. Die Audiodaten existierten nur vorübergehend und lokal auf dem Aufnahmegerät — niemals in der Cloud.
            3. Das Transkript wurde von einem lokalen Sprachmodell auf diesem Gerät erstellt; es wurde kein externer KI-Dienst verwendet.
            4. Die Audiodaten wurden sofort gelöscht, nachdem der Text fertig war.
            5. Alle Personen auf der Empfängerliste erhalten exakt dieselbe Nachricht.
            6. Pausierte Teile des Gesprächs wurden nirgends aufgenommen — auch nicht in diesem Text.
            """
        case (.german, true):
            """
            Über diesen Bericht:
            1. Das Gespräch wurde lokal auf dem Aufnahmegerät transkribiert.
            2. Die Audiodaten existierten nur vorübergehend und lokal auf dem Aufnahmegerät — niemals in der Cloud oder beim KI-Dienst.
            3. Nur der Transkripttext wurde vom ausgewählten externen KI-Dienst zu einem KI-Protokoll verarbeitet.
            4. Die Audiodaten wurden sofort gelöscht, nachdem der Text fertig war.
            5. Alle Personen auf der Empfängerliste erhalten exakt dieselbe Nachricht, einschließlich des vollständigen unbearbeiteten Transkripts.
            6. Pausierte Teile des Gesprächs wurden nirgends aufgenommen — auch nicht in diesem Text.
            """
        }
    }

    /// Onderwerpregel: "Notulen — 13 juli 2026".
    public static func subject(
        date: Date,
        language: MeetingReportLanguage = .dutch
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.localeIdentifier)
        formatter.dateFormat = "d MMMM yyyy"
        let title: String
        switch language {
        case .dutch: title = "Notulen"
        case .english: title = "Meeting minutes"
        case .german: title = "Besprechungsprotokoll"
        }
        return "\(title) — \(formatter.string(from: date))"
    }

    /// De mailontvangers: alle deelnemers met een geldig ingevuld adres.
    public static func recipients(_ participants: [MeetingParticipant]) -> [String] {
        participants.compactMap { participant in
            guard participant.isValid,
                  let email = participant.email?.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return nil }
            return email
        }
    }

    /// De aanwezigenregel bevat uitsluitend de namen van e-mailontvangers.
    static func attendeesLine(_ participants: [MeetingParticipant]) -> String {
        participants
            .filter(\.isValid)
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// De volledige berichttekst — identiek voor iedere ontvanger: aanhef,
    /// aanwezigen, het transcript en de transparantie-uitleg.
    public static func mailBody(
        transcript: String,
        participants: [MeetingParticipant],
        date: Date,
        aiMinutes: String? = nil,
        language: MeetingReportLanguage = .dutch
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.localeIdentifier)
        formatter.dateFormat = "d MMMM yyyy"

        let localized: (greeting: String, intro: String, present: String, ai: String, raw: String, report: String)
        switch language {
        case .dutch:
            localized = ("Beste deelnemers,", "Hieronder staat het automatische verslag van ons gesprek op", "Aanwezig", "AI-notulen", "Volledige onbewerkte transcriptie", "Verslag")
        case .english:
            localized = ("Dear participants,", "Below is the automatic report of our conversation on", "Present", "AI minutes", "Full unedited transcript", "Report")
        case .german:
            localized = ("Guten Tag,", "Nachfolgend finden Sie den automatisch erstellten Bericht unseres Gesprächs vom", "Anwesend", "KI-Protokoll", "Vollständiges unbearbeitetes Transkript", "Bericht")
        }

        var lines: [String] = []
        lines.append(localized.greeting)
        lines.append("")
        lines.append("\(localized.intro) \(formatter.string(from: date)).")
        let attendees = attendeesLine(participants)
        if !attendees.isEmpty {
            lines.append("\(localized.present): \(attendees).")
        }
        lines.append("")
        let usedAI: Bool
        if let aiMinutes = aiMinutes?.trimmingCharacters(in: .whitespacesAndNewlines),
           !aiMinutes.isEmpty {
            usedAI = true
            lines.append("--- \(localized.ai) ---")
            lines.append("")
            lines.append(aiMinutes)
            lines.append("")
            lines.append("--- \(localized.raw) ---")
        } else {
            usedAI = false
            lines.append("--- \(localized.report) ---")
        }
        lines.append("")
        lines.append(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
        lines.append("---")
        lines.append("")
        lines.append(transparencyText(language: language, usedAI: usedAI))
        return lines.joined(separator: "\n")
    }

    /// `mailto:`-fallback wanneer er geen mailaccount in de Mail-app staat:
    /// alle ontvangers, onderwerp en berichttekst correct percent-encoded.
    /// `nil` wanneer er geen enkele ontvanger is.
    public static func mailtoURL(
        transcript: String,
        participants: [MeetingParticipant],
        date: Date,
        aiMinutes: String? = nil,
        language: MeetingReportLanguage = .dutch
    ) -> URL? {
        let to = recipients(participants)
        guard !to.isEmpty else { return nil }

        // In een mailto-URL zijn ,/?&= betekenisdragend; encodeer alles behalve
        // de echt onschuldige tekens.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")

        let body = mailBody(
            transcript: transcript,
            participants: participants,
            date: date,
            aiMinutes: aiMinutes,
            language: language
        )
        guard
            let encodedSubject = subject(date: date, language: language).addingPercentEncoding(withAllowedCharacters: allowed),
            let encodedBody = body.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }

        let addresses = to
            .compactMap { $0.addingPercentEncoding(withAllowedCharacters: allowed.union(CharacterSet(charactersIn: "@"))) }
            .joined(separator: ",")

        return URL(string: "mailto:\(addresses)?subject=\(encodedSubject)&body=\(encodedBody)")
    }
}
