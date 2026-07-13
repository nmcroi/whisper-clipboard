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

    private var meetingDate: Date { Date() }

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
        .navigationBarBackButtonHidden(controller.isRecording || controller.isTranscribing)
        .task {
            controller.attach(app: app)
            controller.transcriptSource = "meeting"
            controller.onTranscriptReady = { text in
                transcript = text
                presentMail(for: text)
            }
            // Auto-start: de setup-knop heette niet voor niets "Start opname".
            if !controller.isRecording {
                controller.toggle()
            }
        }
        .sheet(isPresented: $showMail) {
            MailComposeView(
                recipients: MeetingMinutesComposer.recipients(participants),
                subject: MeetingMinutesComposer.subject(date: meetingDate),
                body: mailBody
            ) { result in
                switch result {
                case .sent: mailStatus = "Verstuurd naar alle deelnemers."
                case .saved: mailStatus = "Bewaard als concept in Mail."
                case .cancelled: mailStatus = "Versturen geannuleerd — je kunt het hieronder opnieuw proberen."
                case .failed: mailStatus = "Versturen mislukt — probeer het opnieuw."
                @unknown default: break
                }
            }
        }
        .sheet(isPresented: $showShare) {
            if let transcript {
                ShareSheet(items: [MeetingMinutesComposer.mailBody(
                    transcript: transcript,
                    participants: participants,
                    date: meetingDate
                )])
            }
        }
    }

    private var mailBody: String {
        MeetingMinutesComposer.mailBody(
            transcript: transcript ?? "",
            participants: participants,
            date: meetingDate
        )
    }

    // MARK: - Opname

    @ViewBuilder
    private var recordingContent: some View {
        Spacer()

        Text(controller.statusLine)
            .font(ThemeFont.ui(15))
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)

        HStack(spacing: 28) {
            if controller.isRecording {
                PauseToggleButton(isPaused: false, enabled: false) {}
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            MeetingRecordButton(
                isRecording: controller.isRecording,
                isBusy: controller.isTranscribing,
                level: controller.level
            ) {
                controller.toggle()
            }
            if controller.isRecording {
                PauseToggleButton(
                    isPaused: controller.isPaused,
                    enabled: !controller.pausedByInterruption
                ) {
                    controller.togglePause()
                }
            }
        }

        if controller.isRecording {
            Text(Self.formatElapsed(controller.elapsed))
                .font(ThemeFont.ui(28, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.text)
            if controller.isPaused {
                Label(
                    controller.pausedByInterruption ? "Gepauzeerd (onderbreking)" : "Gepauzeerd",
                    systemImage: "pause.circle"
                )
                .font(ThemeFont.ui(13, weight: .medium))
                .foregroundStyle(Theme.danger)
            }
        }

        Text("Gepauzeerde stukken worden niet opgenomen en komen nergens in het verslag terecht.")
            .font(ThemeFont.ui(13))
            .foregroundStyle(Theme.textTertiary)
            .multilineTextAlignment(.center)

        Spacer()

        attendeesFooter
    }

    private var attendeesFooter: some View {
        Text("Deelnemers: \(participants.map(\.name).joined(separator: ", "))")
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

        Button("Klaar") { dismiss() }
            .font(ThemeFont.ui(15))
            .foregroundStyle(Theme.textSecondary)

        Text("Het verslag staat ook in de Geschiedenis (bron: Notulen).")
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
            date: meetingDate
        ) {
            UIApplication.shared.open(url) { opened in
                if !opened {
                    showShare = true
                    mailStatus = "Geen mail-app gevonden — deel het verslag via het deelvenster."
                }
            }
            return
        }
        showShare = true
    }

    private static func formatElapsed(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// De opnameknop van de notulist: zelfde ring + vierkant-motief als overal.
private struct MeetingRecordButton: View {
    let isRecording: Bool
    let isBusy: Bool
    let level: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(isRecording ? Theme.danger : Theme.accent, lineWidth: 6)
                    .frame(width: 132, height: 132)
                    .scaleEffect(isRecording ? 1 + CGFloat(level) * 0.08 : 1)

                RoundedRectangle(cornerRadius: isRecording ? 8 : 14, style: .continuous)
                    .fill(isRecording ? Theme.danger : Theme.accent)
                    .frame(
                        width: isRecording ? 46 : 56,
                        height: isRecording ? 46 : 56
                    )

                if isBusy {
                    ProgressView()
                        .tint(Theme.onAccent)
                        .scaleEffect(1.3)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isRecording)
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
