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

            Text("Whisper Clipboard transcribeert volledig op je iPhone. Download eenmalig het Nederlandse Parakeet-model (~460 MB). Daarna werkt alles offline.")
                .font(ThemeFont.ui(14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            content
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
                Text("\(Int(progress * 100))%")
                    .font(ThemeFont.ui(13))
                    .foregroundStyle(Theme.textTertiary)
            }
        case .unsupported:
            Text("Dit toestel wordt niet ondersteund.")
                .font(ThemeFont.ui(14))
                .foregroundStyle(Theme.danger)
        default:
            Button {
                Task { await app.downloadModel() }
            } label: {
                Text("Download model")
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
}
