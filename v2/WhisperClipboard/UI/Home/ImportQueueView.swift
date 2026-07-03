import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Presents an `NSOpenPanel` for picking supported media files, calling `onPick`
/// with the chosen URLs. Multi-select, filtered to supported content types.
enum MediaOpenPanel {
    @MainActor
    static func present(onPick: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = SupportedMedia.contentTypes
        panel.prompt = "Importeren"
        panel.message = "Kies audio- of videobestanden om te transcriberen."
        panel.begin { response in
            guard response == .OK else { return }
            onPick(panel.urls)
        }
    }
}

/// The compact import-queue panel shown on Home: one row per job with a state
/// label, a yellow progress bar while decoding, and a red retry row on failure.
struct ImportQueueView: View {
    @Bindable var service: FileImportService

    var body: some View {
        if !service.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Bestanden importeren")
                    .font(ThemeFont.ui(15, weight: .semibold))
                    .foregroundStyle(Theme.text)

                VStack(spacing: 8) {
                    ForEach(service.jobs) { job in
                        ImportJobRow(job: job, service: service)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ImportJobRow: View {
    @Bindable var job: ImportJob
    let service: FileImportService

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 5) {
                Text(job.url.lastPathComponent)
                    .font(ThemeFont.ui(13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(statusText)
                    .font(ThemeFont.ui(11))
                    .foregroundStyle(isFailed ? Theme.danger : Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if case .decoding(let progress) = job.state {
                    ProgressBar(value: progress)
                        .frame(height: 4)
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: 8)

            trailing
        }
        .padding(12)
        .themeCard(border: isFailed ? Theme.danger.opacity(0.5) : Theme.border)
    }

    @ViewBuilder private var trailing: some View {
        switch job.state {
        case .transcribing, .diarizing:
            ProgressView()
                .controlSize(.small)
                .tint(Theme.accent)
        case .failed:
            Button("Opnieuw") { service.retry(job) }
                .buttonStyle(AccentButtonStyle())
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.accentText)
        case .waiting, .decoding:
            EmptyView()
        }
    }

    private var isFailed: Bool { if case .failed = job.state { return true }; return false }

    private var icon: String {
        switch job.state {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "waveform"
        }
    }

    private var iconColor: Color {
        switch job.state {
        case .done: return Theme.accentText
        case .failed: return Theme.danger
        default: return Theme.textSecondary
        }
    }

    private var statusText: String {
        switch job.state {
        case .waiting: return "In wachtrij…"
        case .decoding(let p): return "Bestand lezen… \(Int((p * 100).rounded()))%"
        case .transcribing: return "Transcriberen…"
        case .diarizing(let p):
            if let p { return "Sprekermodel downloaden… \(Int((p * 100).rounded()))%" }
            return "Sprekers herkennen…"
        case .done: return "Getranscribeerd en gekopieerd"
        case .failed(let message): return message
        }
    }
}

/// A thin yellow progress bar on the dark surface.
private struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceHover)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
    }
}
