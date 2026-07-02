import SwiftUI

/// NightStory-styled Home view. In M1 the "Dicteren" card is live: it shows the
/// current hotkey and a "Test opname" button, and a model-download card appears
/// when the Dutch speech model is not yet installed.
struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        // Observe the nested observable objects so the view refreshes when the
        // model status or dictation phase changes.
        HomeContent(
            environment: environment,
            modelManager: environment.modelManager,
            dictation: environment.dictation
        )
    }
}

private struct HomeContent: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject var modelManager: EngineModelManager
    @ObservedObject var dictation: DictationController

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            statusPill
            if let notice = environment.engineNotice {
                engineNoticeBanner(notice)
            }
            if modelManager.needsDownload {
                modelDownloadCard
            }
            dictationCard
            actionGrid
            Spacer(minLength: 0)
            footer
        }
        .padding(28)
        .frame(minWidth: 460, minHeight: 500)
        .background(NightStory.bg)
    }

    // MARK: - Sections

    private var header: some View {
        (
            Text("Whisper Clipboard")
                .foregroundStyle(NightStory.marine)
            + Text(".")
                .foregroundStyle(NightStory.terra)
        )
        .font(NightStoryFont.heading(size: 30, weight: .bold))
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(environment.appState.isRecording ? NightStory.terra : NightStory.softblue)
                .frame(width: 8, height: 8)
            Text(environment.appState.statusText)
                .font(NightStoryFont.body(size: 13, weight: .medium))
                .foregroundStyle(NightStory.marine)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(NightStory.lightterra.opacity(0.6))
        .clipShape(Capsule())
    }

    private func engineNoticeBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(NightStory.marine)
            Text(text)
                .font(NightStoryFont.body(size: 12, weight: .medium))
                .foregroundStyle(NightStory.marine)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NightStory.softblue.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var modelDownloadCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(NightStory.terra)
                Text("Parakeet-spraakmodel")
                    .font(NightStoryFont.body(size: 15, weight: .semibold))
                    .foregroundStyle(NightStory.marine)
            }
            Text("Het lokale Parakeet-model (meertalig, incl. Nederlands) wordt eenmalig gedownload voordat je kunt dicteren. Dit gebeurt volledig op je Mac.")
                .font(NightStoryFont.body(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if modelManager.isDownloading {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: downloadFraction)
                        .controlSize(.small)
                        .tint(NightStory.terra)
                    Text(downloadProgressLabel)
                        .font(NightStoryFont.body(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Parakeet-model downloaden (494 MB)…") { environment.downloadModel() }
                    .buttonStyle(.borderedProminent)
                    .tint(NightStory.terra)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(NightStory.card)
        .clipShape(RoundedRectangle(cornerRadius: NightStoryMetrics.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NightStoryMetrics.cardCornerRadius, style: .continuous)
                .strokeBorder(NightStory.terra.opacity(0.5), lineWidth: 1)
        )
        .nightStoryShadowSmall()
    }

    private var dictationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "mic")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(NightStory.terra)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dicteren")
                        .font(NightStoryFont.body(size: 15, weight: .semibold))
                        .foregroundStyle(NightStory.marine)
                    Text("Spreek in en plak de tekst")
                        .font(NightStoryFont.body(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Label(environment.hotkeys.shortcutDescription, systemImage: "keyboard")
                    .font(NightStoryFont.body(size: 12, weight: .medium))
                    .foregroundStyle(NightStory.marine)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(NightStory.sand.opacity(0.5))
                    .clipShape(Capsule())

                Spacer()

                Button(testButtonTitle) { dictation.toggle() }
                    .buttonStyle(.borderedProminent)
                    .tint(NightStory.terra)
                    .disabled(!canTest)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(NightStory.card)
        .clipShape(RoundedRectangle(cornerRadius: NightStoryMetrics.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NightStoryMetrics.cardCornerRadius, style: .continuous)
                .strokeBorder(NightStory.sand, lineWidth: 1)
        )
        .nightStoryShadowSmall()
    }

    /// Current download progress (0…1) from the model status, for the bar.
    private var downloadFraction: Double {
        switch modelManager.status {
        case .downloading(let progress), .needsDownload(let progress):
            return progress
        default:
            return 0
        }
    }

    private var downloadProgressLabel: String {
        let percent = Int((downloadFraction * 100).rounded())
        return "Downloaden… \(percent)%"
    }

    private var testButtonTitle: String {
        dictation.phase == .recording ? "Stop opname" : "Test opname"
    }

    private var canTest: Bool {
        modelManager.status.isReady && dictation.phase != .transcribing
    }

    private var actionGrid: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ActionCard(symbol: "folder", title: "Bestanden openen", subtitle: "Transcribeer audio- of videobestanden")
            ActionCard(symbol: "clock.arrow.circlepath", title: "Geschiedenis", subtitle: "Eerdere transcripties terugvinden")
        }
        .disabled(true)
        .opacity(0.9)
    }

    private var footer: some View {
        Text("NightStory · 2026")
            .font(NightStoryFont.body(size: 11, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

#Preview {
    HomeView()
        .environmentObject(AppEnvironment())
}
