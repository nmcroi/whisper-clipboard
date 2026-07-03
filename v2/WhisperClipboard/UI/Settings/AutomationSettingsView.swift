import AppKit
import Core
import SwiftUI

/// The "Automatisering" settings tab (M7): filler-word removal, auto-export of
/// completed transcripts to a folder, and watched folders that auto-transcribe
/// any new audio/video dropped into them.
///
/// All controls bind directly to `environment.settings`, which `SettingsStore`
/// persists automatically. Folder pickers additionally store a security-scoped
/// bookmark so access survives sandboxing/moves, and adding/removing a watched
/// folder nudges the `WatchedFolderService` to re-scan immediately.
struct AutomationSettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider().overlay(Theme.border)
                fillerSection
                Divider().overlay(Theme.border)
                autoExportSection
                Divider().overlay(Theme.border)
                watchedFoldersSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.window)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            (
                Text("Automatisering")
                    .foregroundStyle(Theme.text)
                + Text(".")
                    .foregroundStyle(Theme.accent)
            )
            .font(ThemeFont.ui(18, weight: .bold))

            Text("Laat Whisper Clipboard werk uit handen nemen: stopwoorden opschonen, transcripties automatisch bewaren en hele mappen vanzelf transcriberen.")
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Filler removal

    private var fillerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stopwoorden")
                .font(ThemeFont.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)

            Toggle(isOn: Binding(
                get: { environment.settings.removeFillers },
                set: { environment.settings.removeFillers = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stopwoorden verwijderen (eh, uh, ehm…)")
                        .font(ThemeFont.ui(13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text("Verwijdert twijfelklanken zoals ‘eh’, ‘uh’ en ‘ehm’ uit je transcripties. Betekenisvolle woorden blijven altijd staan — de lijst is bewust behoudend.")
                        .font(ThemeFont.ui(11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
        }
    }

    // MARK: - Auto-export

    private var autoExportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Automatisch exporteren")
                .font(ThemeFont.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)

            Toggle(isOn: Binding(
                get: { environment.settings.autoExportEnabled },
                set: { environment.settings.autoExportEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Elke transcriptie opslaan als bestand")
                        .font(ThemeFont.ui(13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text("Schrijft elke nieuwe transcriptie (dicteren én bestandsimport) automatisch naar de gekozen map, in het gekozen formaat.")
                        .font(ThemeFont.ui(11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)

            // Destination folder row.
            VStack(alignment: .leading, spacing: 6) {
                Text("Exportmap")
                    .font(ThemeFont.ui(12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)

                HStack(spacing: 8) {
                    Text(exportDirectoryDisplay)
                        .font(ThemeFont.ui(12).monospaced())
                        .foregroundStyle(exportDirectorySet ? Theme.text : Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Theme.surfaceHover)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))

                    Button("Kies map…") { chooseExportDirectory() }
                        .buttonStyle(SecondaryButtonStyle())

                    if exportDirectorySet {
                        Button {
                            environment.settings.autoExportDirectory = ""
                            AutomationBookmarks.remove(forKey: AutomationBookmarks.autoExportKey)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Map wissen")
                    }
                }
            }
            .disabled(!environment.settings.autoExportEnabled)
            .opacity(environment.settings.autoExportEnabled ? 1 : 0.5)

            // Format picker.
            HStack {
                Text("Formaat")
                    .font(ThemeFont.ui(13))
                    .foregroundStyle(Theme.text)
                Spacer()
                Picker("", selection: Binding(
                    get: { ExportFormat(suffix: environment.settings.autoExportFormat) ?? .markdown },
                    set: { environment.settings.autoExportFormat = $0.fileExtension }
                )) {
                    ForEach(ExportFormat.allCases, id: \.self) { format in
                        Text(Self.formatLabel(format)).tag(format)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .tint(Theme.accent)
            }
            .disabled(!environment.settings.autoExportEnabled)
            .opacity(environment.settings.autoExportEnabled ? 1 : 0.5)
        }
    }

    private var exportDirectorySet: Bool {
        !environment.settings.autoExportDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var exportDirectoryDisplay: String {
        let path = environment.settings.autoExportDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? "Geen map gekozen" : abbreviate(path)
    }

    /// A friendly, human-readable label per export format.
    private static func formatLabel(_ format: ExportFormat) -> String {
        switch format {
        case .txt: return "Tekst (.txt)"
        case .markdown: return "Markdown (.md)"
        case .srt: return "Ondertitels (.srt)"
        case .vtt: return "WebVTT (.vtt)"
        case .json: return "JSON (.json)"
        }
    }

    // MARK: - Watched folders

    private var watchedFoldersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Mappen bewaken")
                    .font(ThemeFont.ui(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button {
                    addWatchedFolder()
                } label: {
                    Label("Map toevoegen", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)
                .fixedSize()
                .foregroundStyle(Theme.accent)
            }

            Text("Nieuwe audio of video die je in een bewaakte map neerzet wordt automatisch getranscribeerd. Bestanden die nog gekopieerd worden, worden pas opgepakt als ze volledig zijn.")
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if environment.settings.watchedFolders.isEmpty {
                Text("Nog geen mappen bewaakt.")
                    .font(ThemeFont.ui(12))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .themeCard()
            } else {
                VStack(spacing: 0) {
                    let folders = environment.settings.watchedFolders
                    ForEach(Array(folders.enumerated()), id: \.element) { index, path in
                        watchedRow(path)
                        if index < folders.count - 1 {
                            Divider().overlay(Theme.border)
                        }
                    }
                }
                .themeCard()
            }
        }
    }

    private func watchedRow(_ path: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Theme.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent)
                    .font(ThemeFont.ui(13, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text(abbreviate(path))
                    .font(ThemeFont.ui(10).monospaced())
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button {
                removeWatchedFolder(path)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Verwijder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func chooseExportDirectory() {
        FolderOpenPanel.present(message: "Kies een map waarin transcripties worden opgeslagen.") { url in
            environment.settings.autoExportDirectory = url.path
            AutomationBookmarks.store(url, forKey: AutomationBookmarks.autoExportKey)
        }
    }

    private func addWatchedFolder() {
        FolderOpenPanel.present(message: "Kies een map om te bewaken op nieuwe audio- of videobestanden.") { url in
            var folders = environment.settings.watchedFolders
            guard !folders.contains(where: { $0 == url.path }) else { return }
            folders.append(url.path)
            environment.settings.watchedFolders = folders
            AutomationBookmarks.storeWatched(url)
            // Start scanning the new folder right away.
            environment.watchedFolders.refresh()
        }
    }

    private func removeWatchedFolder(_ path: String) {
        environment.settings.watchedFolders.removeAll { $0 == path }
        AutomationBookmarks.removeWatched(path: path)
        environment.watchedFolders.refresh()
    }

    /// Replaces the home-directory prefix with "~" for compact display.
    private func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Folder picker

/// Presents an `NSOpenPanel` restricted to a single directory, calling `onPick`
/// with the chosen folder URL.
enum FolderOpenPanel {
    @MainActor
    static func present(message: String, onPick: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Kies"
        panel.message = message
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            onPick(url)
        }
    }
}

// MARK: - Reusable button style

/// A subtle secondary button matching the "Open Systeeminstellingen" style used
/// across the settings tabs.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ThemeFont.ui(12, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(configuration.isPressed ? Theme.surfaceHover : Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))
    }
}

#Preview {
    AutomationSettingsView()
        .environmentObject(AppEnvironment())
        .frame(width: 560, height: 460)
        .preferredColorScheme(.dark)
}
