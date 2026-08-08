import Core
import SwiftUI

/// The iOS companion app entry point: a four-tab shell ("Opnemen" / "Notule" /
/// "Notities" / "Geschiedenis") with a Settings gear in the toolbar. Record →
/// transcribe locally with Parakeet (Dutch) → history, iCloud-synced with the Mac
/// in a later round. Notities are doorlopende, benoemde notities waaraan je kunt
/// blijven toevoegen (i2; nog niet gesynct — zie HistorySchema/TranscriptCloudRecord).
@main
struct WhisperClipboardiOSApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environment(\.locale, app.interfaceLanguage.locale)
                .preferredColorScheme(app.appearance.preferredColorScheme)
                .tint(Theme.accentText)
        }
    }
}

/// The tab shell. Tinted, themed, with the shared error alert.
struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showSettings = false

    var body: some View {
        TabView {
            RecordView()
                .tabItem { Label("Opnemen", systemImage: "mic.fill") }

            NavigationStack {
                MeetingSetupView()
            }
            .tabItem { Label("Notule", systemImage: "person.2.wave.2.fill") }

            NotesListiOSView()
                .tabItem { Label("Notities", systemImage: "note.text") }

            HistoryListiOSView()
                .tabItem { Label("Geschiedenis", systemImage: "clock.fill") }
        }
        .overlay(alignment: .topTrailing) {
            // Settings gear floats over de tab-content (elke tab is z'n eigen
            // NavigationStack, dus een gedeelde toolbar-knop zou dupliceren).
            // Bewust op ÉLKE pagina zichtbaar — ook in gepushte detailweergaven.
            // Die detailschermen zetten hun eigen knoppen daarom links (topBarLeading),
            // zodat niets rechtsboven met dit tandwiel botst.
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(10)
            }
            .padding(.trailing, 8)
            .padding(.top, 4)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environmentObject(app)
                .preferredColorScheme(app.appearance.preferredColorScheme)
        }
        .alert(
            "Er ging iets mis",
            isPresented: Binding(
                get: { app.errorMessage != nil },
                set: { if !$0 { app.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) { app.errorMessage = nil } },
            message: { Text(app.errorMessage ?? "") }
        )
        .alert(
            "Opname hersteld",
            isPresented: Binding(
                get: { app.noticeMessage != nil },
                set: { if !$0 { app.noticeMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) { app.noticeMessage = nil } },
            message: { Text(app.noticeMessage ?? "") }
        )
    }
}
