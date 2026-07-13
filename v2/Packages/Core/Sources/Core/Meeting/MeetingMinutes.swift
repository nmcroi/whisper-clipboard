import Foundation

/// Eén deelnemer aan een notulen-opname (de private notulist). `email == nil`
/// betekent: anoniem aanwezig — telt mee in de aanwezigenlijst maar ontvangt
/// geen mail.
public struct MeetingParticipant: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var email: String?

    public init(id: UUID = UUID(), name: String, email: String? = nil) {
        self.id = id
        self.name = name
        self.email = email
    }

    /// Geldig om mee te doen: een niet-lege naam, en het e-mailadres is óf
    /// afwezig (anoniem) óf plausibel (bevat een @ met daarna een punt).
    public var isValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        guard let email else { return true }
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

/// Stelt de notulen-mail samen: onderwerp, ontvangers, en één identieke
/// berichttekst voor iedereen — transcript plus de vaste transparantie-uitleg.
/// Puur Foundation, dus volledig unit-testbaar (ook in de Linux-CI).
public enum MeetingMinutesComposer {

    /// De vaste, feitelijke uitleg die onder elk verslag staat. De zes punten
    /// volgen het proces van de notulist-modus en zijn geformuleerd conform wat
    /// de app werkelijk doet (audio wordt nooit als bestand opgeslagen; de
    /// samples worden na de transcriptie uit het geheugen gewist).
    public static let transparencyText = """
    Over dit verslag:
    1. Het gesprek is getranscribeerd en niet bewaard als audiobestand.
    2. De audio bestond alleen tijdelijk lokaal op het toestel dat opnam — nooit in de cloud.
    3. De transcriptie is gemaakt door een lokaal taalmodel op dat toestel; er is geen externe AI-dienst gebruikt.
    4. De audio is direct gewist zodra de tekst klaar was.
    5. Iedereen op de verzendlijst ontvangt exact hetzelfde bericht.
    6. Gepauzeerde delen van het gesprek zijn nergens in opgenomen — ook niet in deze tekst.
    """

    /// Onderwerpregel: "Notulen — 13 juli 2026".
    public static func subject(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "nl_NL")
        formatter.dateFormat = "d MMMM yyyy"
        return "Notulen — \(formatter.string(from: date))"
    }

    /// De mail-ontvangers: alle deelnemers mét e-mailadres (anoniemen vallen af).
    public static func recipients(_ participants: [MeetingParticipant]) -> [String] {
        participants.compactMap { participant in
            guard let email = participant.email?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !email.isEmpty else { return nil }
            return email
        }
    }

    /// De aanwezigenregel: namen van deelnemers met adres, plus een telling van
    /// de anonieme deelnemers ("1 deelnemer anoniem" / "n deelnemers anoniem").
    static func attendeesLine(_ participants: [MeetingParticipant]) -> String {
        let named = participants
            .filter { $0.email != nil }
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let anonymous = participants.filter { $0.email == nil }.count

        var parts = named
        if anonymous == 1 {
            parts.append("1 deelnemer anoniem")
        } else if anonymous > 1 {
            parts.append("\(anonymous) deelnemers anoniem")
        }
        return parts.joined(separator: ", ")
    }

    /// De volledige berichttekst — identiek voor iedere ontvanger: aanhef,
    /// aanwezigen, het transcript en de transparantie-uitleg.
    public static func mailBody(
        transcript: String,
        participants: [MeetingParticipant],
        date: Date
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "nl_NL")
        formatter.dateFormat = "d MMMM yyyy"

        var lines: [String] = []
        lines.append("Beste deelnemers,")
        lines.append("")
        lines.append("Hieronder staat het automatische verslag van ons gesprek op \(formatter.string(from: date)).")
        let attendees = attendeesLine(participants)
        if !attendees.isEmpty {
            lines.append("Aanwezig: \(attendees).")
        }
        lines.append("")
        lines.append("--- Verslag ---")
        lines.append("")
        lines.append(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
        lines.append("---")
        lines.append("")
        lines.append(transparencyText)
        return lines.joined(separator: "\n")
    }

    /// `mailto:`-fallback wanneer er geen mailaccount in de Mail-app staat:
    /// alle ontvangers, onderwerp en berichttekst correct percent-encoded.
    /// `nil` wanneer er geen enkele ontvanger is.
    public static func mailtoURL(
        transcript: String,
        participants: [MeetingParticipant],
        date: Date
    ) -> URL? {
        let to = recipients(participants)
        guard !to.isEmpty else { return nil }

        // In een mailto-URL zijn ,/?&= betekenisdragend; encodeer alles behalve
        // de echt onschuldige tekens.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")

        let body = mailBody(transcript: transcript, participants: participants, date: date)
        guard
            let encodedSubject = subject(date: date).addingPercentEncoding(withAllowedCharacters: allowed),
            let encodedBody = body.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }

        let addresses = to
            .compactMap { $0.addingPercentEncoding(withAllowedCharacters: allowed.union(CharacterSet(charactersIn: "@"))) }
            .joined(separator: ",")

        return URL(string: "mailto:\(addresses)?subject=\(encodedSubject)&body=\(encodedBody)")
    }
}
