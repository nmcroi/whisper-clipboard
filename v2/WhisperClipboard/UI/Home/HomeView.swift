import Core
import SwiftUI

/// The main window root: a dark `NavigationSplitView` with a tight sidebar
/// (Home / Geschiedenis) and a detail pane per tab.
struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var navigation = AppNavigation()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar(selection: $navigation.tab)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Group {
                switch navigation.tab {
                case .home:
                    HomeContent(
                        environment: environment,
                        modelManager: environment.modelManager,
                        dictation: environment.dictation,
                        history: environment.history,
                        onOpenHistory: { navigation.openHistory(selecting: $0) }
                    )
                case .history:
                    HistoryListView(store: environment.history, navigation: navigation)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.window)
        }
        .environmentObject(navigation)
        .background(Theme.window)
        .toolbarBackground(Theme.window, for: .windowToolbar)
        .preferredColorScheme(.dark)
        .onReceive(environment.$menuNavigationRequest.compactMap { $0 }) { request in
            apply(request)
        }
        .onAppear {
            // Consume any request queued before this view subscribed (e.g. the
            // menu bar opened the window straight onto the history tab).
            if let request = environment.menuNavigationRequest {
                apply(request)
            }
        }
    }

    private func apply(_ request: AppEnvironment.MenuNavigationRequest) {
        switch request {
        case .home:
            navigation.tab = .home
        case .history(let id):
            navigation.openHistory(selecting: id)
        }
        environment.menuNavigationRequest = nil
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Binding var selection: SidebarTab

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(SidebarTab.allCases, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.symbol)
                        .font(ThemeFont.ui(13, weight: .medium))
                        .tag(tab)
                }
            } header: {
                Wordmark(size: 17)
                    .padding(.bottom, 6)
                    .padding(.top, 2)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.window)
        .tint(Theme.accent)
    }
}

// MARK: - Home content

private struct HomeContent: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject var modelManager: EngineModelManager
    @ObservedObject var dictation: DictationController
    @ObservedObject var history: HistoryStore
    let onOpenHistory: (String?) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let notice = environment.engineNotice {
                    noticeBanner(notice)
                }
                if modelManager.needsDownload {
                    modelDownloadCard
                }
                actionGrid
                recentSection
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.window)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Wordmark(size: 30)
            statusPill
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(environment.appState.isRecording ? Theme.danger : Theme.accent)
                .frame(width: 7, height: 7)
            Text(environment.appState.statusText)
                .font(ThemeFont.ui(12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.surface)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(ThemeFont.ui(12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard(radius: Theme.Metrics.radius)
    }

    // MARK: Model download

    private var modelDownloadCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(Theme.accent)
                Text("Parakeet-spraakmodel")
                    .font(ThemeFont.ui(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            Text("Het lokale Parakeet-model (meertalig, incl. Nederlands) wordt eenmalig gedownload voordat je kunt dicteren. Dit gebeurt volledig op je Mac.")
                .font(ThemeFont.ui(12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if modelManager.isDownloading {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: downloadFraction)
                        .controlSize(.small)
                        .tint(Theme.accent)
                    Text(downloadProgressLabel)
                        .font(ThemeFont.ui(11))
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                Button("Model downloaden (494 MB)…") { environment.downloadModel() }
                    .buttonStyle(AccentButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .themeCard(border: Theme.accent.opacity(0.4))
    }

    private var downloadFraction: Double {
        switch modelManager.status {
        case .downloading(let progress), .needsDownload(let progress):
            return progress
        default:
            return 0
        }
    }

    private var downloadProgressLabel: String {
        "Downloaden… \(Int((downloadFraction * 100).rounded()))%"
    }

    // MARK: Actions

    private var actionGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ActionCard(
                symbol: dictation.phase == .recording ? "stop.circle" : "mic",
                title: "Dicteren",
                subtitle: dictation.phase == .recording ? "Opname loopt — klik om te stoppen" : "Spreek in en plak de tekst",
                enabled: canDictate,
                hint: dictation.phase == .recording ? nil : environment.hotkeys.shortcutDescription,
                action: { dictation.toggle() }
            )
            ActionCard(
                symbol: "folder",
                title: "Bestanden openen",
                subtitle: "Transcribeer audio- of videobestanden",
                enabled: false,
                badge: "M3"
            )
            ActionCard(
                symbol: "captions.bubble",
                title: "Live ondertitels",
                subtitle: "Toon ondertitels tijdens het spreken",
                enabled: false,
                badge: "Later"
            )
        }
    }

    private var canDictate: Bool {
        modelManager.status.isReady && dictation.phase != .transcribing
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent")
                    .font(ThemeFont.ui(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button("Alles bekijken") { onOpenHistory(nil) }
                    .buttonStyle(.plain)
                    .font(ThemeFont.ui(12, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }

            let recents = recentEntries
            if recents.isEmpty {
                emptyRecent
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recents.enumerated()), id: \.element.id) { index, entry in
                        Button { onOpenHistory(entry.id) } label: {
                            TranscriptRow(entry: entry, compact: true)
                        }
                        .buttonStyle(.plain)
                        if index < recents.count - 1 {
                            Divider().overlay(Theme.border)
                        }
                    }
                }
                .themeCard()
            }
        }
    }

    private var emptyRecent: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(Theme.textTertiary)
            Text("Nog geen transcripties. Start een opname om te beginnen.")
                .font(ThemeFont.ui(12))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }

    /// The 10 most recent entries. Recomputed whenever the store bumps `revision`.
    private var recentEntries: [TranscriptEntry] {
        _ = history.revision
        return (try? history.recent(10)) ?? []
    }
}

// MARK: - Accent button style

/// A yellow-filled primary button matching the design language.
struct AccentButtonStyle: ButtonStyle {
    var prominent: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ThemeFont.ui(13, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
            .contentShape(Rectangle())
    }
}

#Preview {
    HomeView()
        .environmentObject(AppEnvironment())
}
