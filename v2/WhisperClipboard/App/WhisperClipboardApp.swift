import SwiftUI

@main
struct WhisperClipboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Whisper Clipboard", id: "main") {
            HomeView()
                .environmentObject(appDelegate.environment)
                .frame(minWidth: 700, minHeight: 480)
                // AppKit remembers the size/position per autosave name.
                .background(WindowConfigurator(autosaveName: "WhisperClipboardMain"))
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(appDelegate.environment)
        }
    }
}

/// Applies a frame-autosave name to the host window so macOS remembers its
/// size and position across launches, and sets a sensible default size the
/// first time it appears.
private struct WindowConfigurator: NSViewRepresentable {
    let autosaveName: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if window.frameAutosaveName.isEmpty {
                let hasSaved = UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)") != nil
                window.setFrameAutosaveName(autosaveName)
                if !hasSaved {
                    window.setContentSize(NSSize(width: 900, height: 600))
                    window.center()
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Tabbed settings window: "Algemeen" (placeholder for now) and "AI" (Claude
/// API key + custom mode editor).
struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("Algemeen", systemImage: "gearshape") }

            AISettingsView(modes: environment.modes)
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 520, height: 460)
        .background(Theme.window)
        .preferredColorScheme(.dark)
    }
}

/// Placeholder "Algemeen" tab (full general settings arrive in a later version).
private struct GeneralSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            (
                Text("Algemeen")
                    .foregroundStyle(Theme.text)
                + Text(".")
                    .foregroundStyle(Theme.accent)
            )
            .font(ThemeFont.ui(18, weight: .bold))

            Text("Algemene instellingen komen in een latere versie.")
                .font(ThemeFont.ui(13))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.window)
    }
}
