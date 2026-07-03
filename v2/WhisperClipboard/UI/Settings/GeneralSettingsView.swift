import Core
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

/// The "Algemeen" settings tab: global hotkey, hotkey behaviour, dictation
/// language, and login-item registration.
struct GeneralSettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var loginItemEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider().overlay(Theme.border)
                hotkeySection
                Divider().overlay(Theme.border)
                languageSection
                Divider().overlay(Theme.border)
                captionsSection
                Divider().overlay(Theme.border)
                loginItemSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.window)
        .onAppear { loginItemEnabled = SMAppService.mainApp.status == .enabled }
    }

    private var header: some View {
        (
            Text("Algemeen")
                .foregroundStyle(Theme.text)
            + Text(".")
                .foregroundStyle(Theme.accent)
        )
        .font(ThemeFont.ui(18, weight: .bold))
    }

    // MARK: - Hotkey

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sneltoets")
                .font(ThemeFont.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)

            HStack {
                Text("Dicteren starten/stoppen")
                    .font(ThemeFont.ui(13))
                    .foregroundStyle(Theme.text)
                Spacer()
                KeyboardShortcuts.Recorder(for: .toggleDictation)
            }

            Picker(
                "Hotkey-gedrag",
                selection: Binding(
                    get: { environment.settings.hotkeyMode },
                    set: { environment.settings.hotkeyMode = $0 }
                )
            ) {
                Text("Schakelen").tag(AppSettings.HotkeyMode.toggle)
                Text("Ingedrukt houden").tag(AppSettings.HotkeyMode.pushToTalk)
            }
            .pickerStyle(.radioGroup)
            .font(ThemeFont.ui(13))
            .foregroundStyle(Theme.text)

            Text("‘Schakelen’ start en stopt dicteren bij elke druk op de sneltoets. ‘Ingedrukt houden’ dicteert zolang je de toets vasthoudt.")
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Language

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Taal")
                .font(ThemeFont.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)

            TextField(
                "bijv. nl, en — leeg = Nederlands",
                text: Binding(
                    get: { environment.settings.language },
                    set: { environment.settings.language = $0 }
                )
            )
            .textFieldStyle(.plain)
            .font(ThemeFont.ui(13).monospaced())
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.surfaceHover)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))
            .frame(maxWidth: 280)

            Text("Taalcode voor spraakherkenning, bijv. nl, en of de. Leeg laten gebruikt Nederlands.")
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Live captions

    private var captionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live ondertitels")
                .font(ThemeFont.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)

            Toggle(isOn: Binding(
                get: { environment.settings.saveCaptions },
                set: { environment.settings.saveCaptions = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ondertitels bewaren in geschiedenis")
                        .font(ThemeFont.ui(13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text("Bewaart het volledige transcript van een ondertitel-sessie in de geschiedenis wanneer je stopt.")
                        .font(ThemeFont.ui(11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
        }
    }

    // MARK: - Login item

    private var loginItemSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Opstarten")
                .font(ThemeFont.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)

            Toggle(isOn: Binding(
                get: { loginItemEnabled },
                set: { setLoginItemEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start bij inloggen")
                        .font(ThemeFont.ui(13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text("Whisper Clipboard start automatisch op de achtergrond wanneer je inlogt.")
                        .font(ThemeFont.ui(11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)

            if let loginItemError {
                Text(loginItemError)
                    .font(ThemeFont.ui(11))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setLoginItemEnabled(_ enabled: Bool) {
        loginItemError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            loginItemError = "Kon opstartgedrag niet wijzigen: \(error.localizedDescription)"
            loginItemEnabled = SMAppService.mainApp.status == .enabled
        }
    }
}

#Preview {
    GeneralSettingsView()
        .environmentObject(AppEnvironment())
        .frame(width: 520, height: 460)
        .preferredColorScheme(.dark)
}
