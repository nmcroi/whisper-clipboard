import Foundation
import Testing
@testable import Core

@Suite struct MeetingMinutesTests {

    private let date = Date(timeIntervalSince1970: 1_784_000_000) // 13 juli 2026 (UTC)

    private var participants: [MeetingParticipant] {
        [
            MeetingParticipant(name: "Niels", email: "niels@voorbeeld.nl"),
            MeetingParticipant(name: "Marie", email: "marie@voorbeeld.fr"),
            MeetingParticipant(name: "Gast", email: nil),
        ]
    }

    // MARK: - Validatie

    @Test func deelnemerMetNaamEnAdresIsGeldig() {
        #expect(MeetingParticipant(name: "Niels", email: "niels@voorbeeld.nl").isValid)
    }

    @Test func anoniemeDeelnemerIsGeldig() {
        #expect(MeetingParticipant(name: "Gast", email: nil).isValid)
    }

    @Test func legeNaamIsOngeldig() {
        #expect(!MeetingParticipant(name: "   ", email: nil).isValid)
    }

    @Test func onwaarschijnlijkeAdressenZijnOngeldig() {
        #expect(!MeetingParticipant(name: "X", email: "geen-apenstaart").isValid)
        #expect(!MeetingParticipant(name: "X", email: "naam@bedrijf").isValid)
        #expect(!MeetingParticipant(name: "X", email: "@bedrijf.nl").isValid)
        #expect(!MeetingParticipant(name: "X", email: "naam@.nl").isValid)
        #expect(!MeetingParticipant(name: "X", email: "naam@bedrijf.").isValid)
        #expect(!MeetingParticipant(name: "X", email: "naam @bedrijf.nl").isValid)
        #expect(MeetingParticipant(name: "X", email: "naam@bedrijf.nl").isValid)
    }

    // MARK: - Ontvangers

    @Test func anoniemenKrijgenGeenMail() {
        #expect(MeetingMinutesComposer.recipients(participants)
                == ["niels@voorbeeld.nl", "marie@voorbeeld.fr"])
    }

    @Test func legeAdressenVallenAf() {
        let list = [MeetingParticipant(name: "X", email: "  ")]
        #expect(MeetingMinutesComposer.recipients(list).isEmpty)
    }

    // MARK: - Onderwerp

    @Test func onderwerpBevatNederlandseDatum() {
        let subject = MeetingMinutesComposer.subject(date: date)
        #expect(subject.hasPrefix("Notulen — "))
        #expect(subject.contains("2026"))
        #expect(subject.contains("juli"))
    }

    // MARK: - Berichttekst

    @Test func bodyBevatTranscriptAanwezigenEnAlleZesPunten() {
        let body = MeetingMinutesComposer.mailBody(
            transcript: "Dit is het verslag.",
            participants: participants,
            date: date
        )
        #expect(body.contains("Dit is het verslag."))
        #expect(body.contains("Niels"))
        #expect(body.contains("Marie"))
        #expect(body.contains("1 deelnemer anoniem"))
        for punt in 1...6 {
            #expect(body.contains("\n\(punt). "), "punt \(punt) ontbreekt")
        }
        // De kernbeloftes staan er letterlijk in.
        #expect(body.contains("niet bewaard als audiobestand"))
        #expect(body.contains("geen externe AI-dienst"))
        #expect(body.contains("exact hetzelfde bericht"))
        #expect(body.contains("Gepauzeerde delen"))
    }

    @Test func meerdereAnoniemenWordenGeteld() {
        let list = [
            MeetingParticipant(name: "A", email: "a@b.nl"),
            MeetingParticipant(name: "Gast 1", email: nil),
            MeetingParticipant(name: "Gast 2", email: nil),
        ]
        let body = MeetingMinutesComposer.mailBody(transcript: "t", participants: list, date: date)
        #expect(body.contains("2 deelnemers anoniem"))
    }

    @Test func geenAnoniemenGeenTelling() {
        let list = [MeetingParticipant(name: "A", email: "a@b.nl")]
        let body = MeetingMinutesComposer.mailBody(transcript: "t", participants: list, date: date)
        #expect(!body.contains("anoniem"))
    }

    // MARK: - mailto-fallback

    @Test func mailtoBevatAlleOntvangersEnEncodeertDeInhoud() throws {
        let url = try #require(MeetingMinutesComposer.mailtoURL(
            transcript: "Regel één\nRegel twee, met komma & teken",
            participants: participants,
            date: date
        ))
        let raw = url.absoluteString
        #expect(raw.hasPrefix("mailto:"))
        #expect(raw.contains("niels%40voorbeeld.nl") || raw.contains("niels@voorbeeld.nl"))
        #expect(raw.contains(","))          // scheiding tussen ontvangers
        #expect(raw.contains("subject="))
        #expect(raw.contains("body="))
        // Newlines, komma's en ampersands uit de body mogen niet rauw in de URL.
        #expect(!raw.contains("\n"))
        #expect(raw.contains("%0A"))        // ge-encodeerde newline
        #expect(raw.contains("%26"))        // ge-encodeerde ampersand uit de body
    }

    @Test func mailtoZonderOntvangersIsNil() {
        let list = [MeetingParticipant(name: "Gast", email: nil)]
        #expect(MeetingMinutesComposer.mailtoURL(transcript: "t", participants: list, date: date) == nil)
    }
}
