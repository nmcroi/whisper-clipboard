import SwiftUI

@main
struct WhisperClipboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Whisper Clip", id: "main") {
            HomeView()
                .environmentObject(appDelegate.environment)
                // Min width fits the Geschiedenis three-pane layout without
                // cramping: 180 (sidebar) + 320 (list) + 380 (detail) = 880.
                .frame(minWidth: 900, minHeight: 520)
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

/// Shared modifier applied at the root of the main window and the settings
/// window: forces the chosen colour scheme live from the setting and pins the
/// control/selection tint to the (readable) yellow accent so nothing renders in
/// system blue in either mode.
struct AppAppearanceModifier: ViewModifier {
    @ObservedObject var environment: AppEnvironment

    func body(content: Content) -> some View {
        content
            .tint(Theme.accentText)
            .preferredColorScheme(environment.settings.appearance.preferredColorScheme)
    }
}

/// Applies a frame-autosave name to the host window so macOS remembers its
/// size and position across launches, and sets a sensible default size the
/// first time it appears.
private struct WindowConfigurator: NSViewRepresentable {
    let autosaveName: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWhenReady(view, attempt: 0)
        return view
    }

    /// Waits (briefly, retrying) until the view is in its window, then applies
    /// the autosave frame AND promotes the app to a regular, frontmost app.
    ///
    /// Without the activation, a content window opening while another app is
    /// frontmost appears on top but the *previous* app keeps owning the menu
    /// bar. `windowDidBecomeKey` can't fix this — a window only becomes key once
    /// the app is already active — so we force it here, the moment the main
    /// window actually reaches the screen.
    private func configureWhenReady(_ view: NSView, attempt: Int) {
        DispatchQueue.main.async {
            guard let window = view.window else {
                if attempt < 20 { configureWhenReady(view, attempt: attempt + 1) }
                return
            }
            if window.frameAutosaveName.isEmpty {
                let hasSaved = UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)") != nil
                window.setFrameAutosaveName(autosaveName)
                if !hasSaved {
                    window.setContentSize(NSSize(width: 900, height: 600))
                    window.center()
                }
            }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Tabbed settings window: "Algemeen" (hotkey, taal, opstarten), "Woordenlijst"
/// (personal find→replace dictionary), "Invoegen" (direct text insertion),
/// "Automatisering" (filler removal, auto-export, watched folders), "PLAUD"
/// (PLAUD cloud sync of NotePin recordings) and "AI" (Claude API key + custom
/// mode editor).
struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("Algemeen", systemImage: "gearshape") }

            DictionarySettingsView()
                .tabItem { Label("Woordenlijst", systemImage: "character.book.closed") }

            InsertionSettingsView()
                .tabItem { Label("Invoegen", systemImage: "text.cursor") }

            AutomationSettingsView()
                .tabItem { Label("Automatisering", systemImage: "gearshape.2") }

            PlaudSettingsView()
                .tabItem { Label("PLAUD", systemImage: "waveform.badge.mic") }

            AISettingsView(modes: environment.modes)
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 560, height: 460)
        .background(Theme.window)
        .modifier(AppAppearanceModifier(environment: environment))
    }
}
