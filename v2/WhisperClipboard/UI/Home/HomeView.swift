import AppKit
import Core
import SwiftUI
import UniformTypeIdentifiers
import WhisperShared

/// The main window root: a dark `NavigationSplitView` with a tight sidebar
/// (Home / Geschiedenis) and a detail pane per tab.
struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        // Drive the whole window from the single, app-owned navigation object so
        // the menu bar and SwiftUI share one source of truth and a view
        // recreation can never spawn a second navigation hierarchy.
        HomeRootView(environment: environment, navigation: environment.navigation)
    }
}

/// The window root, split out so it can `@ObservedObject` the shared navigation
/// (whose `@Published` tab drives which detail pane shows).
private struct HomeRootView: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject var navigation: AppNavigation

    var body: some View {
        // A fixed app sidebar: NavigationSplitView allowed macOS to collapse the
        // column until labels disappeared when the window became narrower.
        // This sidebar stays readable at every supported window size.
        HStack(spacing: 0) {
            Sidebar(selection: $navigation.tab)
                .frame(width: 165)
            Divider().overlay(Theme.border)

            Group {
                switch navigation.tab {
                case .home:
                    HomeContent(
                        environment: environment,
                        modelManager: environment.modelManager,
                        dictation: environment.dictation,
                        history: environment.history,
                        captions: environment.captions,
                        onOpenHistory: { navigation.openHistory(selecting: $0) }
                    )
                case .notes:
                    NotesListView(store: environment.history)
                case .history:
                    HistoryListView(store: environment.history, navigation: navigation, modes: environment.modes)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.window)
        }
        .environmentObject(navigation)
        .background(Theme.window)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text.accentDotted("Whisper Clip")
                    .font(ThemeFont.ui(18, weight: .semibold))
                    .padding(.horizontal, 15)
                    .padding(.vertical, 4)
            }
        }
        .toolbarBackground(Theme.window, for: .windowToolbar)
        .modifier(AppAppearanceModifier(environment: environment))
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
        // A plain custom list instead of `List(selection:)`: the macOS `.sidebar`
        // list style paints its selected row with the SYSTEM accent (blue) no
        // matter what `.tint` is set, which violates the no-blue design rule. A
        // button-per-row layout lets us own the selection background (yellow-tinted
        // surface) and keep it strictly on-brand.
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SidebarTab.allCases, id: \.self) { tab in
                sidebarRow(tab)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 10)
        .background(Theme.window)
    }

    private func sidebarRow(_ tab: SidebarTab) -> some View {
        let isSelected = selection == tab
        return Button { selection = tab } label: {
            Label(tab.title, systemImage: tab.symbol)
                .font(ThemeFont.ui(13, weight: .medium))
                .foregroundStyle(isSelected ? Theme.text : Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected ? Theme.accent.opacity(0.14) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tint(Theme.accent)
        .padding(.horizontal, 8)
    }
}

// MARK: - Home content

private struct HomeContent: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject var modelManager: EngineModelManager
    @ObservedObject var dictation: DictationController
    @ObservedObject var history: HistoryStore
    @ObservedObject var captions: CaptionsService
    let onOpenHistory: (String?) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 10),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let notice = environment.engineNotice {
                    noticeBanner(notice)
                }
                if let message = captions.errorMessage {
                    captionsErrorBanner(message)
                }
                if modelManager.needsDownload {
                    modelDownloadCard
                }
                actionGrid
                ImportQueueView(service: environment.fileImport)
                recentSection
            }
            .padding(24)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.window)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { refreshRecents() }
        // `revision` bumpt na élke mutatie van de store, dus ook wanneer een
        // import of een dictaat klaar is of iCloud iets binnenhaalt.
        .onChange(of: history.revision) { _, _ in refreshRecents() }
    }

    @State private var isDropTargeted = false

    /// De 10 recentste opnames, één keer opgehaald per wijziging.
    ///
    /// Bevinding 2026-08-04: dit was een computed property, en deze view
    /// observeert `dictation` — die publiceert tijdens een opname 10× per
    /// seconde (`elapsed`). De database werd daardoor tijdens het dicteren
    /// tientallen keren per seconde synchroon bevraagd op de main thread.
    @State private var recentEntries: [TranscriptEntry] = []

    /// Of de eerste query al gedraaid heeft; voorkomt dat de lege staat één
    /// frame flitst. Bevinding 2026-08-04.
    @State private var hasLoadedRecents = false

    private func openFiles() {
        MediaOpenPanel.present { urls in
            environment.fileImport.importFiles(urls)
        }
    }

    /// Handles files dropped on the window: loads each provider's URL, then
    /// enqueues the supported ones (the service rejects unsupported types).
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            environment.fileImport.importFiles(urls)
        }
        return true
    }

    // MARK: Header

    private var header: some View {
        // The wordmark lives in the sidebar; the content header shows a plain page
        // title so the brand mark isn't rendered twice.
        VStack(alignment: .leading, spacing: 10) {
            Text("Home")
            .font(ThemeFont.ui(24, weight: .bold))
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
                .foregroundStyle(Theme.accentText)
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

    /// Dutch explainer shown when a caption session fails to start — with a button
    /// to the system-audio privacy pane when the failure was a permission denial.
    private func captionsErrorBanner(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.danger)
                Text(text)
                    .font(ThemeFont.ui(12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if captions.permissionDenied {
                Button("Open Systeeminstellingen") { openSystemAudioSettings() }
                    .buttonStyle(AccentButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard(border: Theme.danger.opacity(0.4))
    }

    /// Opens Privacy & Security → Screen & System Audio Recording.
    private func openSystemAudioSettings() {
        // The screen-capture / system-audio pane. On macOS 26 this anchor lands on
        // "Schermopname en systeemaudio"; the app is listed there once it has
        // attempted a system-audio tap.
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    // MARK: Model download

    private var modelDownloadCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(Theme.accentText)
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
                symbol: dictationActive ? "stop.circle" : "mic",
                title: "Dicteren",
                subtitle: dictationSubtitle,
                enabled: canDictate,
                hint: dictationActive ? nil : environment.hotkeys.shortcutDescription,
                action: { dictation.toggle() }
            )
            ActionCard(
                symbol: "folder",
                title: "Bestanden openen",
                subtitle: "Transcribeer audio- of videobestanden",
                enabled: true,
                action: { openFiles() }
            )
            ActionCard(
                symbol: captionsRunning ? "captions.bubble.fill" : "captions.bubble",
                title: "Live ondertitels",
                subtitle: captionsRunning
                    ? "Actief — klik om te stoppen"
                    : "Toon ondertitels van systeemaudio",
                enabled: modelManager.status.isReady,
                active: captionsRunning,
                action: { environment.toggleCaptions() }
            )
            ActionCard(
                symbol: "person.2.wave.2",
                title: "Notulen",
                subtitle: "Neem een gesprek op en mail het verslag",
                enabled: modelManager.status.isReady,
                active: environment.meeting.isBusy,
                action: { showMeeting = true }
            )
        }
        .sheet(isPresented: $showMeeting) {
            MeetingSheet(controller: environment.meeting)
        }
    }

    @State private var showMeeting = false

    private var captionsRunning: Bool {
        captions.isRunning
    }

    private var canDictate: Bool {
        modelManager.status.isReady && dictation.phase != .transcribing
    }

    /// True zolang er een opname-sessie leeft (ook gepauzeerd): de kaart toont
    /// dan de stop-variant.
    private var dictationActive: Bool {
        dictation.phase == .recording || dictation.phase == .paused
    }

    private var dictationSubtitle: String {
        switch dictation.phase {
        case .recording: return "Opname loopt — klik om te stoppen"
        case .paused: return "Opname gepauzeerd — klik om te stoppen"
        default: return "Spreek in en plak de tekst"
        }
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
                    .foregroundStyle(Theme.accentText)
            }

            let recents = recentEntries
            if !hasLoadedRecents {
                EmptyView()
            } else if recents.isEmpty {
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

    /// Haalt de 10 recentste opnames op. Zelfde query als voorheen, alleen niet
    /// meer bij elke body-pass (bevinding 2026-08-04).
    private func refreshRecents() {
        recentEntries = (try? history.recent(10)) ?? []
        hasLoadedRecents = true
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
