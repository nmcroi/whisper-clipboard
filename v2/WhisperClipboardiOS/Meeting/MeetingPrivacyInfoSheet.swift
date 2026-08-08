import AVFoundation
import SwiftUI

/// Heldere uitleg vóór een notulen-opname. Deze wordt pas op verzoek getoond
/// of voorgelezen; het openen of afspelen start nadrukkelijk géén opname.
struct MeetingPrivacyInfoSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var narrator = MeetingPrivacyNarrator()
    let makeAIMinutes: Bool

    private var copy: MeetingPrivacyCopy {
        MeetingPrivacyCopy.make(
            languageCode: app.interfaceLanguage.resolvedCode,
            includesAI: makeAIMinutes
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.window.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(Theme.accentText)

                        Text(copy.title)
                            .font(ThemeFont.ui(28, weight: .bold))
                            .foregroundStyle(Theme.text)

                        Text(copy.subtitle)
                            .font(ThemeFont.ui(16))
                            .foregroundStyle(Theme.textSecondary)

                        ForEach(copy.cards) { card in
                            explanationCard(title: card.title, symbol: card.symbol, text: card.text)
                        }

                        Button {
                            narrator.toggle(text: copy.spokenText, language: app.interfaceLanguage.speechLanguage)
                        } label: {
                            Label(
                                narrator.isSpeaking ? copy.stop : copy.play,
                                systemImage: narrator.isSpeaking ? "stop.fill" : "play.fill"
                            )
                            .font(ThemeFont.ui(16, weight: .semibold))
                            .foregroundStyle(Theme.onAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(copy.voiceAccessibilityHint)

                        Text(copy.voiceHint)
                            .font(ThemeFont.ui(13))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Uitleg")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Gereed") {
                        narrator.stop()
                        dismiss()
                    }
                    .foregroundStyle(Theme.accentText)
                }
            }
        }
    }

    private func explanationCard(title: String, symbol: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(ThemeFont.ui(16, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(text)
                .font(ThemeFont.ui(15))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .themeCard()
    }
}

@MainActor
private final class MeetingPrivacyNarrator: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(text: String, language: String) {
        if synthesizer.isSpeaking {
            stop()
            return
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = 0.47
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
        }
    }
}
