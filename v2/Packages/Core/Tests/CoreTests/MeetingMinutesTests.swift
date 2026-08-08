import Foundation
import Testing
@testable import Core

@Suite struct MeetingMinutesTests {

    @Test func verslagLokaliseertOnderwerpEnTransparantie() {
        let testDate = Date(timeIntervalSince1970: 1_784_073_600)
        let english = MeetingMinutesComposer.mailBody(
            transcript: "Raw transcript",
            participants: [],
            date: testDate,
            aiMinutes: "AI summary",
            language: .english
        )
        #expect(MeetingMinutesComposer.subject(date: testDate, language: .english).hasPrefix("Meeting minutes —"))
        #expect(english.contains("--- AI minutes ---"))
        #expect(english.contains("--- Full unedited transcript ---"))
        #expect(english.contains("Only the transcript text"))
        #expect(!english.contains("no external AI service was used"))

        let german = MeetingMinutesComposer.mailBody(
            transcript: "Rohtranskript",
            participants: [],
            date: testDate,
            language: .german
        )
        #expect(MeetingMinutesComposer.subject(date: testDate, language: .german).hasPrefix("Besprechungsprotokoll —"))
        #expect(german.contains("--- Bericht ---"))
        #expect(german.contains("kein externer KI-Dienst"))
    }

    private let date = Date(timeIntervalSince1970: 1_784_000_000) // 13 juli 2026 (UTC)

    private var participants: [MeetingParticipant] {
        [
            MeetingParticipant(name: "Niels", email: "niels@voorbeeld.nl"),
            MeetingParticipant(name: "Marie", email: "marie@voorbeeld.fr"),
        ]
    }

    // MARK: - Validatie

    @Test func deelnemerMetNaamEnAdresIsGeldig() {
        #expect(MeetingParticipant(name: "Niels", email: "niels@voorbeeld.nl").isValid)
    }

    @Test func deelnemerZonderAdresIsOngeldig() {
        #expect(!MeetingParticipant(name: "Gast", email: nil).isValid)
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

    @Test func alleGeldigeDeelnemersKrijgenMail() {
        #expect(MeetingMinutesComposer.recipients(participants)
                == ["niels@voorbeeld.nl", "marie@voorbeeld.fr"])
    }

    @Test func ontbrekendeEnOngeldigeAdressenVallenAf() {
        let list = [
            MeetingParticipant(name: "Geen adres", email: nil),
            MeetingParticipant(name: "Leeg adres", email: "  "),
            MeetingParticipant(name: "Ongeldig adres", email: "naam@bedrijf"),
        ]
        #expect(MeetingMinutesComposer.recipients(list).isEmpty)
    }

    // MARK: - Bewaren

    @Test func geldigeOntvangerWordtAlsNieuwContactBewaard() {
        let participant = MeetingParticipant(name: "  Marie  ", email: "  marie@voorbeeld.nl ")
        let saved = MeetingContactList.saving(participant, in: [])

        #expect(saved.count == 1)
        #expect(saved[0].name == "Marie")
        #expect(saved[0].email == "marie@voorbeeld.nl")
        #expect(!saved[0].isMe)
    }

    @Test func opnieuwBewarenWerktContactBijZonderDuplicaatOfVerliesVanIsMe() {
        let existing = SavedMeetingContact(
            name: "Oude naam",
            email: "NIELS@voorbeeld.nl",
            isMe: true
        )
        let participant = MeetingParticipant(name: "Niels", email: "niels@voorbeeld.nl")
        let saved = MeetingContactList.saving(participant, in: [existing])

        #expect(saved.count == 1)
        #expect(saved[0].name == "Niels")
        #expect(saved[0].email == "niels@voorbeeld.nl")
        #expect(saved[0].isMe)
    }

    @Test func ongeldigeOntvangerWordtNietBewaard() {
        let existing = [SavedMeetingContact(name: "Niels", email: "niels@voorbeeld.nl", isMe: true)]
        let participant = MeetingParticipant(name: "Gast", email: nil)
        #expect(MeetingContactList.saving(participant, in: existing) == existing)
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
        #expect(!body.contains("anoniem"))
        for punt in 1...6 {
            #expect(body.contains("\n\(punt). "), "punt \(punt) ontbreekt")
        }
        // De kernbeloftes staan er letterlijk in.
        #expect(body.contains("alleen tijdelijk lokaal"))
        #expect(!body.contains("niet bewaard als audiobestand"))
        #expect(body.contains("geen externe AI-dienst"))
        #expect(body.contains("exact hetzelfde bericht"))
        #expect(body.contains("Gepauzeerde delen"))
    }

    @Test func transparantieInAlleTalenBeschrijftTijdelijkeLokaleAudioEerlijk() {
        let dutch = MeetingMinutesComposer.transparencyText(language: .dutch, usedAI: false)
        let english = MeetingMinutesComposer.transparencyText(language: .english, usedAI: false)
        let german = MeetingMinutesComposer.transparencyText(language: .german, usedAI: false)

        #expect(dutch.contains("alleen tijdelijk lokaal"))
        #expect(english.contains("only temporarily and locally"))
        #expect(german.contains("nur vorübergehend und lokal"))
        #expect(!english.contains("not saved as an audio file"))
        #expect(!german.contains("nicht als Audiodatei gespeichert"))
    }

    @Test func deelnemersZonderAdresKomenNietInAanwezigenregel() {
        let list = [
            MeetingParticipant(name: "A", email: "a@b.nl"),
            MeetingParticipant(name: "Gast", email: nil),
        ]
        let body = MeetingMinutesComposer.mailBody(transcript: "t", participants: list, date: date)
        #expect(body.contains("Aanwezig: A."))
        #expect(!body.contains("Gast"))
    }

    @Test func aiNotulenEnVolledigeTranscriptieBlijvenBeideInDeMail() {
        let body = MeetingMinutesComposer.mailBody(
            transcript: "Volledige letterlijke transcriptie.",
            participants: participants,
            date: date,
            aiMinutes: "Samenvatting en actiepunten."
        )
        #expect(body.contains("AI-notulen"))
        #expect(body.contains("Samenvatting en actiepunten."))
        #expect(body.contains("Volledige onbewerkte transcriptie"))
        #expect(body.contains("Volledige letterlijke transcriptie."))
    }

    @Test func notulenPromptVerzintGeenEigenaar() throws {
        let mode = try #require(AIMode.builtins.first(where: { $0.id == "builtin.notulen" }))
        #expect(mode.systemPrompt.contains("naam letterlijk"))
        #expect(mode.systemPrompt.contains("Eigenaar: niet duidelijk"))
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
        #expect(MeetingMinutesComposer.mailtoURL(transcript: "t", participants: [], date: date) == nil)
    }
}
