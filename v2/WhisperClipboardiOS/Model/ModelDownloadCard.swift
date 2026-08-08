import SwiftUI
import WhisperShared

/// First-launch onboarding card shown on the Record tab until the ~460 MB
/// Parakeet model is on device. Drives ``AppModel/downloadModel()`` and shows
/// live progress. Once installed it disappears and the record button takes over.
struct ModelDownloadCard: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Theme.accentText)

            Text("Spraakmodel downloaden")
                .font(ThemeFont.ui(18, weight: .semibold))
                .foregroundStyle(Theme.text)

            Text("WhisperClip transcribeert volledig op je iPhone. Download eenmalig het meertalige Parakeet-model (~460 MB). Daarna werkt alles offline.")
                .font(ThemeFont.ui(14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            content

            if let message = app.errorMessage {
                Text(message)
                    .font(ThemeFont.ui(13))
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .themeCard()
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var content: some View {
        switch app.modelStatus {
        case .downloading(let progress):
            VStack(spacing: 8) {
                ProgressView(value: progress)
                    .tint(Theme.accent)
                Text(progressLabel(progress))
                    .font(ThemeFont.ui(13))
                    .foregroundStyle(Theme.textTertiary)
                    .contentTransition(.numericText())
                Text("Houd de app open tijdens het downloaden.")
                    .font(ThemeFont.ui(12))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
        case .unsupported:
            Text("Dit toestel wordt niet ondersteund.")
                .font(ThemeFont.ui(14))
                .foregroundStyle(Theme.danger)
        default:
            Button {
                Task { await app.downloadModel() }
            } label: {
                // After a failure the button doubles as the retry action.
                Text(app.errorMessage == nil
                     ? L10n.string( "Download model", locale: app.interfaceLanguage.locale)
                     : L10n.string( "Opnieuw proberen", locale: app.interfaceLanguage.locale))
                    .font(ThemeFont.ui(16, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    /// "45% · 210 van 460 MB" when byte progress is known, else just the percent.
    private func progressLabel(_ progress: Double) -> String {
        let percent = "\(Int(progress * 100))%"
        if let bytes = app.downloadBytes, bytes.totalMB > 0 {
            return String(
                format: L10n.string( "%1$@ · %2$lld van %3$lld MB", locale: app.interfaceLanguage.locale),
                locale: app.interfaceLanguage.locale,
                percent,
                bytes.downloadedMB,
                bytes.totalMB
            )
        }
        return percent
    }
}
