import AppKit
import Core
import SwiftUI

/// De notulen-sheet op de Mac: deelnemers invoeren → opnemen (met pauze) →
/// verslag mailen. Zelfde proces en dezelfde privacy-beloftes als de
/// iOS-notulist; de mail gaat via de eigen Mail-app (NSSharingService), met
/// mailto- en klembord-fallbacks zodat het verslag nooit strandt.
struct MeetingSheet: View {
    @ObservedObject var controller: MeetingController
    @Environment(\.dismiss) private var dismiss

    /// Bewerkbare deelnemer-rijen; per sessie, nergens bewaard.
    @State private var rows: [Row] = [Row()]
    /// Statusregel over de verzending ("Mail geopend", fallback-melding, …).
    @State private var mailStatus: String?

    struct Row: Identifiable {
        let id = UUID()
        var name = ""
        var email = ""
        var isAnonymous = false

        var participant: MeetingParticipant {
            MeetingParticipant(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                email: isAnonymous ? nil : email.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private var participants: [MeetingParticipant] { rows.map(\.participant) }

    private var canStart: Bool {
        !rows.isEmpty
            && participants.allSatisfy(\.isValid)
            && !MeetingMinutesComposer.recipients(participants).isEmpty
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
            case .recording, .paused:
                recordingSection
            case .transcribing:
                transcribingSection
            case .finished:
                finishedSection
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 480, height: 520)
        .background(Theme.window)
        // Tijdens opname/transcriptie kan de sheet niet (per ongeluk) dicht.
        .interactiveDismissDisabled(controller.isBusy)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text.accentDotted("Notulen")
                    .font(ThemeFont.ui(20, weight: .bold))
                Text("Opname en transcriptie gebeuren volledig lokaal. De audio wordt nooit als bestand opgeslagen; gepauzeerde stukken bestaan nergens. Iedereen op de lijst krijgt exact hetzelfde verslag.")
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

            HStack {
                Button {
                    rows.append(Row())
                } label: {
                    Label("Voeg deelnemer toe", systemImage: "person.badge.plus")
                }
                .buttonStyle(AccentButtonStyle())

                Spacer()

                Button {
                    controller.start()
                } label: {
                    Label("Start opname", systemImage: "record.circle")
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(!canStart)
            }

            Text("Anonieme deelnemers tellen mee als aanwezig maar krijgen geen mail. Deze lijst wordt nergens bewaard.")
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                Toggle("Anoniem", isOn: row.isAnonymous)
                    .font(ThemeFont.ui(12))
                    .toggleStyle(.checkbox)
                Button {
                    rows.removeAll { $0.id == row.wrappedValue.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Verwijder deelnemer")
            }
            if !row.wrappedValue.isAnonymous {
                TextField("E-mailadres", text: row.email)
                    .textFieldStyle(.plain)
                    .font(ThemeFont.ui(13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceHover)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            }
        }
        .padding(10)
        .themeCard()
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
