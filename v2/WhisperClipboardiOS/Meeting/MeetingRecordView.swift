import Core
import MessageUI
import SwiftUI
import WhisperShared

/// Stap 2 van de private notulist: de opname zelf. Start automatisch bij
/// verschijnen, met een prominente pauzeknop ("gepauzeerde stukken worden niet
/// opgenomen"). Na stoppen wordt lokaal getranscribeerd, als "Notulen" in de
/// Geschiedenis bewaard en opent de vooringevulde mail met het verslag voor
/// alle deelnemers.
struct MeetingRecordView: View {
    let participants: [MeetingParticipant]
    let makeAIMinutes: Bool
    let language: TranscriptionLanguage

    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = RecordController()

    /// Het afgeronde verslag (verwerkte transcript-tekst), zodra beschikbaar.
    @State private var transcript: String?
    /// Mail-composer zichtbaar (alleen wanneer een mailaccount bestaat).
    @State private var showMail = false
    /// Systeem-deelvenster als laatste vangnet (geen account én mailto faalt).
    @State private var showShare = false
    /// Statusregel over de verzending ("Verstuurd", "Geannuleerd", …).
    @State private var mailStatus: String?
    @State private var aiMinutes: String?
    @State private var isCreatingAI = false
    @State private var aiError: String?
    /// De lokale rij blijft bestaan totdat de gebruiker expliciet verwijdert.
    /// Een mailresultaat wijzigt deze keuze nooit.
    @State private var savedEntryID: String?
    @State private var confirmDelete = false

    private let meetingDate = Date()

    var body: some View {
        ZStack {
            Theme.window.ignoresSafeArea()
            VStack(spacing: 24) {
                if let transcript {
                    finishedContent(transcript)
                } else {
                    recordingContent
                }
            }
            .padding(20)
        }
        .navigationTitle("Notulen-opname")
        .navigationBarTitleDisplayMode(.inline)
        // Tijdens de opname niet per ongeluk terug-swipen.
        .navigationBarBackButtonHidden(
            controller.isRecording || controller.isTranscribing || transcript != nil
        )
        .task {
            controller.attach(app: app)
            controller.transcriptSource = "meeting"
            controller.onTranscriptReady = { text, entry in
                transcript = text
                savedEntryID = entry?.id
                if makeAIMinutes, let entry {
                    Task { await createAIMinutes(for: entry) }
                } else {
                    presentMail(for: text)
                }
            }
            // Auto-start: de setup-knop heette niet voor niets "Start opname".
            if !controller.isRecording {
                controller.toggle(language: language)
            }
        }
        .sheet(isPresented: $showMail) {
            MailComposeView(
                recipients: MeetingMinutesComposer.recipients(participants),
                subject: MeetingMinutesComposer.subject(date: meetingDate, language: reportLanguage),
                body: mailBody
            ) { result in
                switch result {
                case .sent:
                    mailStatus = L10n.string( "Verstuurd naar alle deelnemers.", locale: app.interfaceLanguage.locale)
                case .saved:
                    mailStatus = L10n.string( "Bewaard als concept in Mail.", locale: app.interfaceLanguage.locale)
                case .cancelled:
                    mailStatus = L10n.string( "Versturen geannuleerd — je kunt het hieronder opnieuw proberen.", locale: app.interfaceLanguage.locale)
                case .failed:
                    mailStatus = L10n.string( "Versturen mislukt — probeer het opnieuw.", locale: app.interfaceLanguage.locale)
                @unknown default: break
                }
            }
        }
        .sheet(isPresented: $showShare) {
            if transcript != nil {
                ShareSheet(items: [mailBody])
            }
        }
        .confirmationDialog(
            "Transcript verwijderen?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Verwijder transcript", role: .destructive) { deleteTranscriptAndFinish() }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text("Dit verwijdert het transcript definitief van dit toestel en, wanneer iCloud-synchronisatie aanstaat, ook uit je gesynchroniseerde geschiedenis.")
        }
    }

    private var mailBody: String {
        MeetingMinutesComposer.mailBody(
            transcript: transcript ?? "",
            participants: participants,
            date: meetingDate,
            aiMinutes: aiMinutes,
            language: reportLanguage
        )
    }

    private var reportLanguage: MeetingReportLanguage {
        MeetingReportLanguage(rawValue: app.interfaceLanguage.resolvedCode) ?? .dutch
    }

    // MARK: - Opname

    @ViewBuilder
    private var recordingContent: some View {
        Spacer()

        Text(controller.statusLine)
            .font(ThemeFont.ui(15))
            .foregroundStyle(controller.isPaused ? Theme.danger : Theme.textSecondary)
            .multilineTextAlignment(.center)

        if controller.isRecording {
            PauseToggleButton(
                isPaused: controller.isPaused,
                enabled: !controller.pausedByInterruption,
                size: 190,
                symbolSize: 60,
                prominent: true
            ) {
                controller.togglePause()
            }
        } else if controller.isTranscribing {
            ProgressView()
                .tint(Theme.accent)
                .scaleEffect(1.4)
                .frame(width: 190, height: 190)
                .themeCard(radius: 95, border: Theme.borderStrong)
        } else {
            ProgressView()
                .tint(Theme.accent)
                .frame(width: 190, height: 190)
        }

        if controller.isRecording {
            Text(Self.formatElapsed(controller.elapsed))
                .font(ThemeFont.ui(28, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.text)
        }

        if controller.isRecording {
            Button {
                controller.toggle()
            } label: {
                Label("Stop en transcribeer", systemImage: "stop.fill")
                    .font(ThemeFont.ui(14, weight: .semibold))
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.dangerSoft)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }

        Spacer()

        attendeesFooter
    }

    private var attendeesFooter: some View {
        Text(String(
            format: L10n.string( "Deelnemers: %@", locale: app.interfaceLanguage.locale),
            locale: app.interfaceLanguage.locale,
            participants.map(\.name).joined(separator: ", ")
        ))
            .font(ThemeFont.ui(12))
            .foregroundStyle(Theme.textTertiary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
    }

    // MARK: - Afgerond

    @ViewBuilder
    private func finishedContent(_ transcript: String) -> some View {
        ScrollView {
            Text(transcript)
                .font(ThemeFont.ui(15))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(16)
        }
        .themeCard()

        if let mailStatus {
            Text(mailStatus)
                .font(ThemeFont.ui(14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }

        if isCreatingAI {
            HStack(spacing: 10) {
                ProgressView().tint(Theme.accent)
                Text("AI-notulen worden gemaakt…")
                    .font(ThemeFont.ui(14, weight: .medium))
            }
            .foregroundStyle(Theme.textSecondary)
        } else if let aiError {
            Text(aiError)
                .font(ThemeFont.ui(13))
                .foregroundStyle(Theme.danger)
                .multilineTextAlignment(.center)
        } else if aiMinutes != nil {
            Label("AI-notulen toegevoegd", systemImage: "checkmark.circle.fill")
                .font(ThemeFont.ui(14, weight: .medium))
                .foregroundStyle(Theme.accentText)
        }

        Button {
            presentMail(for: transcript)
        } label: {
            Label("Verstuur notulen", systemImage: "envelope")
                .font(ThemeFont.ui(16, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isCreatingAI)

        VStack(spacing: 10) {
            Text("Wat wil je met dit transcript doen?")
                .font(ThemeFont.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)

            Button(savedEntryID == nil ? "Bewaren opnieuw proberen" : "Bewaar transcript") {
                if savedEntryID != nil {
                    dismiss()
                } else if let saved = controller.retryPendingSave() {
                    savedEntryID = saved.id
                    dismiss()
                }
            }
                .font(ThemeFont.ui(16, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))

            Button("Verwijder transcript", role: .destructive) { confirmDelete = true }
                .font(ThemeFont.ui(16, weight: .semibold))
                .foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Theme.dangerSoft)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
        }

        Text("Totdat je kiest, blijft het verslag veilig in Geschiedenis staan (bron: Notulen).")
            .font(ThemeFont.ui(12))
            .foregroundStyle(Theme.textTertiary)
    }

    /// Opent de best beschikbare mail-route: de composer (mailaccount aanwezig),
    /// anders `mailto:` (een andere mail-app kan die claimen), en als laatste
    /// vangnet het deelvenster — het verslag mag nooit stranden.
    private func presentMail(for transcript: String) {
        if MailComposeView.canSendMail {
            showMail = true
            return
        }
        if let url = MeetingMinutesComposer.mailtoURL(
            transcript: transcript,
            participants: participants,
            date: meetingDate,
            aiMinutes: aiMinutes,
            language: reportLanguage
        ) {
            UIApplication.shared.open(url) { opened in
                if !opened {
                    showShare = true
                    mailStatus = L10n.string( "Geen mail-app gevonden — deel het verslag via het deelvenster.", locale: app.interfaceLanguage.locale)
                }
            }
            return
        }
        showShare = true
    }

    private func deleteTranscriptAndFinish() {
        guard let savedEntryID else {
            dismiss()
            return
        }
        do {
            try app.history?.delete(id: savedEntryID)
            dismiss()
        } catch {
            app.errorMessage = String(
                format: L10n.string( "Het transcript kon niet worden verwijderd: %@", locale: app.interfaceLanguage.locale),
                locale: app.interfaceLanguage.locale,
                error.localizedDescription
            )
        }
    }

    private func createAIMinutes(for entry: TranscriptEntry) async {
        guard let modes = app.modes,
              let mode = modes.allModes.first(where: { $0.id == "builtin.notulen" })
        else {
            aiError = L10n.string( "AI-notulen konden niet worden gestart; de volledige transcriptie blijft beschikbaar.", locale: app.interfaceLanguage.locale)
            presentMail(for: entry.text)
            return
        }

        isCreatingAI = true
        aiError = nil
        do {
            let result = try await modes.runToCompletion(mode: mode, on: entry)
            aiMinutes = result.output
        } catch {
            let localizedError = ErrorLocalization.message(for: error, language: app.interfaceLanguage)
            aiError = String(
                format: L10n.string( "AI-notulen konden niet worden gemaakt: %@ De volledige transcriptie blijft beschikbaar.", locale: app.interfaceLanguage.locale),
                locale: app.interfaceLanguage.locale,
                localizedError
            )
        }
        isCreatingAI = false
        presentMail(for: entry.text)
    }

    private static func formatElapsed(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Dun deelvenster-wrappertje (laatste vangnet wanneer mail niet kan).
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
