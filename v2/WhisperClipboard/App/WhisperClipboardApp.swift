import SwiftUI

@main
struct WhisperClipboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Whisper Clipboard", id: "main") {
            HomeView()
                .environmentObject(appDelegate.environment)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(appDelegate.environment)
        }
    }
}

/// Placeholder settings pane for M0.
struct SettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            (
                Text("Instellingen")
                    .foregroundStyle(NightStory.marine)
                + Text(".")
                    .foregroundStyle(NightStory.terra)
            )
            .font(NightStoryFont.heading(size: 20, weight: .bold))

            Text("Instellingen komen in een latere versie.")
                .font(NightStoryFont.body(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 380, height: 200, alignment: .topLeading)
        .background(NightStory.bg)
    }
}
