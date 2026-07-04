import Core
import SwiftUI

/// The iOS companion app entry point: a two-tab shell ("Opnemen" / "Geschiedenis")
/// with a Settings gear in the toolbar. Record → transcribe locally with Parakeet
/// (Dutch) → history, iCloud-synced with the Mac in a later round.
@main
struct WhisperClipboardiOSApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
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

            HistoryListiOSView()
                .tabItem { Label("Geschiedenis", systemImage: "clock.fill") }
        }
        .overlay(alignment: .topTrailing) {
            // Settings gear floats over the tab content (each tab is its own
            // NavigationStack, so a shared toolbar item would duplicate).
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
    }
}
