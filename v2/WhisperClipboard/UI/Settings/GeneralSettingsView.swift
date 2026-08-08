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
    @State private var showICloudMergeConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider().overlay(Theme.border)
                appearanceSection
                Divider().overlay(Theme.border)
                hotkeySection
                Divider().overlay(Theme.border)
                languageSection
                Divider().overlay(Theme.border)
                captionsSection
                Divider().overlay(Theme.border)
                recordingBackupSection
                diarizationSection
                Divider().overlay(Theme.border)
                icloudSyncSection
                Divider().overlay(Theme.border)
                hudSection
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
        Text.accentDotted("Algemeen")
        .font(ThemeFont.ui(18, weight: .bold))
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Weergave")
                .font(ThemeFont.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)

            Picker(
                "Thema",
                selection: Binding(
                    get: { environment.settings.appearance },
                    set: { environment.settings.appearance = $0 }
                )
            ) {
                Text("Systeem").tag(AppSettings.AppearanceMode.system)
                Text("Donker").tag(AppSettings.AppearanceMode.dark)
                Text("Licht").tag(AppSettings.AppearanceMode.light)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320, alignment: .leading)

            Text("‘Systeem’ volgt de weergave van macOS. ‘Donker’ is het standaardthema; ‘Licht’ zet een witte achtergrond met dezelfde gele en rode accenten.")
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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

            Toggle(isOn: Binding(
                get: { environment.settings.translateCaptionsToDutch },
                set: { environment.settings.translateCaptionsToDutch = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live vertalen naar Nederlands")
                        .font(ThemeFont.ui(13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text("Vertaalt afgeronde ondertitelregels live naar het Nederlands met Apple Vertalen. De originele tekst blijft klein en gedimd boven de vertaling staan. Bij het eerste gebruik vraagt macOS om het Nederlandse taalpakket te downloaden.")
                        .font(ThemeFont.ui(11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
        }
    }

    // MARK: - Speaker diarization

    /// Het audiovangnet stond wel in de instellingen-structuur maar was nergens
    /// bereikbaar, en er werd ook nooit audio weggeschreven (bevinding
    /// 2026-08-03). Nu allebei.
    private var recordingBackupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Opname bewaren")
                .font(ThemeFont.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)

            Toggle(isOn: Binding(
                get: { environment.settings.saveRecordings },
                set: { environment.settings.saveRecordings = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Geluidsopname bewaren na transcriptie")
                        .font(ThemeFont.ui(13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text("Bewaart de opname bij de transcriptie, zodat je hem opnieuw kunt laten uitschrijven als er iets misgaat. Kost ongeveer 115 MB per uur spraak. Staat dit uit, dan wordt de opname na het transcriberen weggegooid en is een mislukte transcriptie definitief.")
                        .font(ThemeFont.ui(11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
        }
    }

    private var diarizationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sprekerherkenning")
                .font(ThemeFont.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)

            Toggle(isOn: Binding(
                get: { environment.settings.speakerRecognitionEnabled },
                set: {
                    environment.settings.speakerRecognitionEnabled = $0
                    // Houd het verouderde import-veld gelijk aan de hoofdschakelaar,
                    // zodat een oudere build (die nog op `diarizeImports` leest)
                    // hetzelfde gedrag vertoont.
                    environment.settings.diarizeImports = $0
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sprekers herkennen")
                        .font(ThemeFont.ui(13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text("Labelt automatisch ‘Spreker 1’, ‘Spreker 2’ enz. — zowel bij live dictaat als bij geïmporteerde gesprekken en interviews. Korte dictaten (< 10 sec.) blijven zonder labels, zodat je klembord snel gevuld wordt. Bij het eerste gebruik wordt eenmalig een klein sprekermodel gedownload (±14 MB).")
                        .font(ThemeFont.ui(11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
        }
    }

    // MARK: - iCloud sync

    private var icloudSyncSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("iCloud-synchronisatie")
                .font(ThemeFont.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)

            Toggle(isOn: Binding(
                get: { environment.settings.icloudSyncEnabled },
                set: { environment.settings.icloudSyncEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Geschiedenis synchroniseren via iCloud")
                        .font(ThemeFont.ui(13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text("Deelt je transcript-geschiedenis met je andere apparaten (bijv. je iPhone) via je eigen iCloud. Er komt geen externe server aan te pas; opnames, wijzigingen en verwijderingen volgen automatisch mee.")
                        .font(ThemeFont.ui(11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)

            HStack(spacing: 12) {
                Text("Status: \(environment.historySync.status.dutchLabel)")
                    .font(ThemeFont.ui(11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if syncRequiresApproval {
                    Button("Koppel dit iCloud-account") {
                        showICloudMergeConfirmation = true
                    }
                    .font(ThemeFont.ui(11, weight: .medium))
                } else {
                    Button("Synchroniseer nu") {
                        Task { await environment.historySync.syncNow() }
                    }
                    .font(ThemeFont.ui(11, weight: .medium))
                    .disabled(!environment.settings.icloudSyncEnabled)
                }
            }
        }
        .alert("Lokale geschiedenis samenvoegen?", isPresented: $showICloudMergeConfirmation) {
            Button("Annuleer", role: .cancel) {}
            Button("Samenvoegen") {
                Task { await environment.historySync.approveCurrentAccountMerge() }
            }
        } message: {
            Text(icloudApprovalMessage)
        }
    }

    private var syncRequiresApproval: Bool {
        if case .requiresApproval = environment.historySync.status { return true }
        return false
    }

    private var icloudApprovalMessage: String {
        guard case .requiresApproval(let localCount, let accountChanged) = environment.historySync.status else {
            return ""
        }
        if accountChanged {
            return "Er is een ander iCloud-account aangemeld. Voeg de \(localCount) lokale items alleen samen als deze geschiedenis bij dat account mag horen. Er wordt niets lokaal verwijderd."
        }
        return "De \(localCount) bestaande lokale items worden samengevoegd met dit iCloud-account. Er wordt niets lokaal verwijderd."
    }

    // MARK: - HUD

    private var hudSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HUD")
                .font(ThemeFont.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)

            HStack {
                Text("HUD zichtbaar na dicteren")
                    .font(ThemeFont.ui(13))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(Self.dutchSeconds(environment.settings.hudLingerSeconds))
                    .font(ThemeFont.ui(13, weight: .medium).monospaced())
                    .foregroundStyle(Theme.accentText)
                    .frame(width: 52, alignment: .trailing)
            }

            Slider(
                value: Binding(
                    get: { environment.settings.hudLingerSeconds },
                    set: { environment.settings.hudLingerSeconds = $0 }
                ),
                in: 1...10,
                step: 0.5
            )
            .tint(Theme.accent)

            Text("Hoe lang de bevestiging in beeld blijft nadat een dictaat is afgerond.")
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Formats seconds with a Dutch decimal comma, e.g. `3.0` → "3,0 s".
    private static func dutchSeconds(_ value: Double) -> String {
        String(format: "%.1f s", value).replacingOccurrences(of: ".", with: ",")
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
                    Text("Whisper Clip start automatisch op de achtergrond wanneer je inlogt.")
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
