import AppKit
import Core
import SwiftUI

/// De notulen-sheet op de Mac: deelnemers invoeren → opnemen (met pauze) →
/// verslag mailen. Zelfde proces en dezelfde privacy-beloftes als de
/// iOS-notulist; de mail gaat via de eigen Mail-app (NSSharingService), met
/// mailto- en klembord-fallbacks zodat het verslag nooit strandt.
struct MeetingSheet: View {
    @ObservedObject var controller: MeetingController
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    /// Bewerkbare deelnemer-rijen; per sessie, nergens bewaard.
    @State private var rows: [Row] = [Row()]
    /// Statusregel over de verzending ("Mail geopend", fallback-melding, …).
    @State private var mailStatus: String?
    @State private var seededOwnContact = false

    struct Row: Identifiable {
        let id = UUID()
        var name = ""
        var email = ""
        var saveContact = false

        var participant: MeetingParticipant? {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty || !trimmedEmail.isEmpty else { return nil }
            return MeetingParticipant(
                name: trimmedName.isEmpty ? "Deelnemer" : trimmedName,
                email: trimmedEmail
            )
        }
    }

    private var participants: [MeetingParticipant] { rows.compactMap(\.participant) }

    private var canStart: Bool {
        participants.allSatisfy(\.isValid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if let message = controller.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(ThemeFont.ui(12, weight: .medium))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch controller.phase {
            case .idle:
                setupSection
            case .preparing:
                preparingSection
            case .recording, .paused:
                recordingSection
            case .transcribing:
                transcribingSection
            // Bij een mislukte opslag blijft het verslag zichtbaar zodat het nog
            // gekopieerd kan worden; de foutmelding staat er al boven.
            case .finished, .savingFailed:
                finishedSection
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 600, height: 540)
        .background(Theme.window)
        // Tijdens opname/transcriptie kan de sheet niet (per ongeluk) dicht.
        .interactiveDismissDisabled(controller.isBusy)
        .onAppear(perform: seedOwnContact)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text.accentDotted("Notulen")
                    .font(ThemeFont.ui(20, weight: .bold))
                Text("Opname en transcriptie gebeuren volledig lokaal. Audio wordt alleen tijdelijk lokaal bewaard en na transcriptie verwijderd; gepauzeerde stukken bestaan nergens. Iedereen op de lijst krijgt exact hetzelfde verslag.")
                    .font(ThemeFont.ui(11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                controller.reset()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(controller.isBusy)
            .help("Sluit")
        }
    }

    // MARK: - Stap 1: deelnemers

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Deelnemers")
                .font(ThemeFont.ui(14, weight: .semibold))
                .foregroundStyle(Theme.text)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach($rows) { $row in
                        participantRow($row)
                    }
                }
            }
            .frame(maxHeight: 220)

            HStack(spacing: 10) {
                Button {
                    rows.append(Row())
                } label: {
                    Label("Nieuwe deelnemer", systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .foregroundStyle(Theme.accentText)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                if !environment.meetingContacts.isEmpty {
                    Menu {
                        ForEach(environment.meetingContacts.filter(\.isValid)) { contact in
                            Button(contact.name) { add(contact) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                            Text("Kies vaste deelnemer")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .foregroundStyle(Theme.accentText)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(maxWidth: .infinity)
                }

                Button {
                    startMeeting()
                } label: {
                    Label("Start opname", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .foregroundStyle(Color.black)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .disabled(!canStart)
            }

            Text("Iedere ingevulde deelnemer is een e-mailontvanger. Laat de lijst leeg om alleen lokaal te transcriberen. Vaste deelnemers synchroniseren via iCloud.")
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func seedOwnContact() {
        guard !seededOwnContact else { return }
        seededOwnContact = true
        guard let own = environment.meetingContacts.first(where: \.isMe) else { return }
        rows = []
        add(own)
    }

    private func add(_ contact: SavedMeetingContact) {
        guard !rows.contains(where: {
            $0.name.caseInsensitiveCompare(contact.name) == .orderedSame
                && $0.email.caseInsensitiveCompare(contact.email) == .orderedSame
        }) else { return }
        rows.append(Row(name: contact.name, email: contact.email))
    }

    private func participantRow(_ row: Binding<Row>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                TextField("Naam", text: row.name)
                    .textFieldStyle(.plain)
                    .font(ThemeFont.ui(13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceHover)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                Button {
                    rows.removeAll { $0.id == row.wrappedValue.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Verwijder deelnemer")
            }
            TextField("E-mailadres", text: row.email)
                .textFieldStyle(.plain)
                .font(ThemeFont.ui(13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.surfaceHover)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            if !isStoredContact(row.wrappedValue) {
                Toggle("Bewaren", isOn: row.saveContact)
                    .font(ThemeFont.ui(12))
                    .toggleStyle(.checkbox)
                    .disabled(!(row.wrappedValue.participant?.isValid ?? false))
                    .help("Bewaar deze naam en dit e-mailadres voor volgende vergaderingen.")
            }
        }
        .padding(10)
        .themeCard()
    }

    private func startMeeting() {
        var contacts = environment.meetingContacts
        for row in rows where row.saveContact && !isStoredContact(row) {
            guard let participant = row.participant else { continue }
            contacts = MeetingContactList.saving(participant, in: contacts)
        }
        if contacts != environment.meetingContacts {
            environment.meetingContacts = contacts
        }
        controller.start()
    }

    private func isStoredContact(_ row: Row) -> Bool {
        let email = row.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return false }
        return environment.meetingContacts.contains {
            $0.email.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(email) == .orderedSame
        }
    }

    // MARK: - Stap 2: opname

    private var recordingSection: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)

            HStack(spacing: 10) {
                Circle()
                    .fill(controller.phase == .paused ? Theme.textTertiary : Theme.danger)
                    .frame(width: 10, height: 10)
                Text(RecordingHUDView.timeString(controller.elapsed))
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text)
            }

            Text(controller.phase == .paused ? "Gepauzeerd" : "Aan het opnemen…")
                .font(ThemeFont.ui(13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 12) {
                if controller.phase == .paused {
                    Button {
                        controller.resume()
                    } label: {
                        Label("Hervat", systemImage: "play.fill")
                    }
                    .buttonStyle(AccentButtonStyle())
                } else {
                    Button {
                        controller.pause()
                    } label: {
                        Label("Pauzeer", systemImage: "pause.fill")
                    }
                    .buttonStyle(AccentButtonStyle())
                }

                Button {
                    controller.stop()
                } label: {
                    Label("Stop en transcribeer", systemImage: "stop.fill")
                }
                .buttonStyle(AccentButtonStyle())
            }

            Text("Gepauzeerde stukken worden niet opgenomen en komen nergens in het verslag terecht.")
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)

            Spacer(minLength: 8)

            Text("Deelnemers: \(participants.map(\.name).joined(separator: ", "))")
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
    }

    /// Tussen "Start opname" en het werkelijk lopen van de microfoon zit op een
    /// koude start de modellading. Die tijd hoort niet te worden gepresenteerd
    /// als een lopende opname (bevinding 2026-08-03).
    private var preparingSection: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.small)
                .tint(Theme.accent)
            Text("Even klaarzetten…")
                .font(ThemeFont.ui(13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("De opname begint zodra de microfoon klaarstaat.")
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var transcribingSection: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.small)
                .tint(Theme.accent)
            Text("Aan het transcriberen…")
                .font(ThemeFont.ui(13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Stap 3: versturen

    @ViewBuilder
    private var finishedSection: some View {
        if let transcript = controller.transcript {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    Text(transcript)
                        .font(ThemeFont.ui(13))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxHeight: 240)
                .themeCard()

                if let mailStatus {
                    Text(mailStatus)
                        .font(ThemeFont.ui(12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button {
                        sendMail(transcript)
                    } label: {
                        Label("Verstuur notulen", systemImage: "envelope")
                    }
                    .buttonStyle(AccentButtonStyle())

                    Spacer()

                    Button("Klaar") {
                        controller.reset()
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                }

                Text("Het verslag staat ook in de Geschiedenis (bron: Notulen).")
                    .font(ThemeFont.ui(11))
                    .foregroundStyle(Theme.textTertiary)
            }
        } else {
            // Leeg transcript ("Geen spraak herkend"): alleen terug naar start.
            VStack(spacing: 12) {
                Spacer()
                Button("Opnieuw beginnen") { controller.reset() }
                    .buttonStyle(AccentButtonStyle())
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Opent de best beschikbare mail-route: de Mail-composer via
    /// NSSharingService, anders een mailto-URL (een andere mail-app kan die
    /// claimen), en als laatste vangnet het klembord.
    private func sendMail(_ transcript: String) {
        let date = Date()
        let body = MeetingMinutesComposer.mailBody(
            transcript: transcript,
            participants: participants,
            date: date
        )

        if let service = NSSharingService(named: .composeEmail) {
            service.recipients = MeetingMinutesComposer.recipients(participants)
            service.subject = MeetingMinutesComposer.subject(date: date)
            if service.canPerform(withItems: [body]) {
                service.perform(withItems: [body])
                mailStatus = "Mail geopend — controleer en druk op versturen."
                return
            }
        }

        if let url = MeetingMinutesComposer.mailtoURL(
            transcript: transcript,
            participants: participants,
            date: date
        ), NSWorkspace.shared.open(url) {
            mailStatus = "Mail geopend — controleer en druk op versturen."
            return
        }

        Clipboard.copy(body)
        mailStatus = "Geen mail-app gevonden — het volledige verslag (met ontvangers in gedachten) staat op je klembord."
    }
}
