import Core
import SwiftUI

struct PlaudSettingsiOSView: View {
    @ObservedObject var service: PlaudSynciOSService

    var body: some View {
        Form {
            PlaudSettingsContent(service: service)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.window)
        .foregroundStyle(Theme.text)
        .navigationTitle("PLAUD")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Dezelfde PLAUD-instellingen kunnen rechtstreeks in Synchronisatie staan,
/// zonder de gebruiker door nog een extra subpagina te sturen.
struct PlaudSettingsContent: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var service: PlaudSynciOSService
    @State private var email = ""
    @State private var password = ""
    @State private var hasSavedCredentials = PlaudCredentials.load()?.isConfigured == true
    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var testSucceeded = false
    @AppStorage("ios.plaud.windowHours") private var windowHours = 48

    private var periods: [(label: String, hours: Int)] {
        let locale = app.interfaceLanguage.locale
        return [
            (L10n.string( "1 uur", locale: locale), 1),
            (L10n.string( "3 uur", locale: locale), 3),
            (L10n.string( "1 dag", locale: locale), 24),
            (L10n.string( "48 uur", locale: locale), 48),
            (L10n.string( "1 week", locale: locale), 7 * 24),
            (L10n.string( "1 maand", locale: locale), 30 * 24),
            (L10n.string( "Kwartaal", locale: locale), 90 * 24),
            (L10n.string( "Halfjaar", locale: locale), 183 * 24),
            (L10n.string( "1 jaar", locale: locale), 365 * 24),
            (L10n.string( "Alles", locale: locale), 0),
        ]
    }

    var body: some View {
        Group {
            Section {
                Text("Accountgegevens")
                    .font(ThemeFont.ui(16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .listRowSeparator(.hidden)

                TextField("E-mailadres", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .foregroundStyle(Theme.textSecondary)
                // Een opgeslagen wachtwoord wordt nooit teruggetoond, maar het
                // lege veld las als "gegevens kwijt" (bevinding 2026-08-02).
                // De plaatsaanduiding laat daarom zien dát er iets staat.
                SecureField(
                    hasSavedCredentials && password.isEmpty
                        ? "••••••••"
                        : L10n.string( "Wachtwoord", locale: app.interfaceLanguage.locale),
                    text: $password
                )
                .foregroundStyle(Theme.textSecondary)
                .accessibilityLabel(L10n.string( "Wachtwoord", locale: app.interfaceLanguage.locale))
                .accessibilityValue(
                    hasSavedCredentials && password.isEmpty
                        ? L10n.string( "Opgeslagen", locale: app.interfaceLanguage.locale)
                        : ""
                )

                Button {
                    saveCredentials()
                } label: {
                    Label("Account opslaan", systemImage: "checkmark.circle")
                }
                .foregroundStyle(Theme.accentText)
                .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          (password.isEmpty && !hasSavedCredentials))

                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Label("Verbinding testen", systemImage: "network")
                        if isTesting { Spacer(); ProgressView() }
                    }
                }
                .foregroundStyle(Theme.accentText)
                .disabled(isTesting || (!hasSavedCredentials && password.isEmpty))

                if let testMessage {
                    Label(testMessage, systemImage: testSucceeded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(ThemeFont.ui(13))
                        .foregroundStyle(testSucceeded ? Theme.textSecondary : Theme.danger)
                        .listRowSeparator(.hidden)
                }

                Text("Opnamen ophalen")
                    .font(ThemeFont.ui(18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.top, 22)
                    .padding(.bottom, 3)
                    .listRowSeparator(.hidden)

                Picker("Periode", selection: $windowHours) {
                    ForEach(periods, id: \.hours) { period in
                        Text(period.label).tag(period.hours)
                    }
                }

                Button {
                    service.syncNow()
                } label: {
                    HStack {
                        RotatingSyncIcon(active: service.isSyncing)
                        Text("Synchroniseer PLAUD")
                            .font(ThemeFont.ui(17, weight: .semibold))
                    }
                    .foregroundStyle(Color.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)
                    .padding(.horizontal, 18)
                    .background(Theme.accent, in: Capsule())
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .center)
                .disabled(!hasSavedCredentials || service.isSyncing)

                if service.isSyncing {
                    Button("Stop", role: .destructive) { service.cancel() }
                    ProgressView(value: service.progressFraction)
                }

                if !service.progressText.isEmpty {
                    Text(service.progressText)
                        .font(ThemeFont.ui(14))
                        .foregroundStyle(service.lastError == nil ? Theme.textSecondary : Theme.danger)
                        .listRowSeparator(.hidden)
                }

                if let last = service.lastSyncedAt {
                    LabeledContent(
                        "Laatst bijgewerkt",
                        value: last.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(app.interfaceLanguage.locale))
                    )
                    .font(ThemeFont.ui(14))
                    .foregroundStyle(Theme.textSecondary)
                    .listRowSeparator(.hidden)
                }
                // Alleen tonen wanneer er werkelijk iets is binnengekomen; een
                // vaste regel met nul voegde alleen een scheidingslijn toe.
                if service.lastImportedCount > 0 {
                    LabeledContent("Nieuw toegevoegd", value: "\(service.lastImportedCount)")
                        .font(ThemeFont.ui(14))
                        .foregroundStyle(Theme.textSecondary)
                        .listRowSeparator(.hidden)
                }
            } header: {
                VStack(alignment: .leading, spacing: 7) {
                    Text("PLAUD")
                        .font(ThemeFont.ui(22, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text("Haalt nieuwe opnamen uit je PLAUD-account op. WhisperClip transcribeert ze lokaal en verwijdert daarna de tijdelijke audio van deze iPhone.")
                        .font(ThemeFont.ui(14))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textCase(nil)
                }
                .padding(.top, 24)
                .padding(.bottom, 5)
            } footer: {
                Text("Je wachtwoord wordt alleen in de beveiligde Sleutelhanger van deze iPhone bewaard. Kies bij Periode hoe ver WhisperClip terugzoekt. PLAUD-opnamen gebruiken de transcriptietaal onder Opnemen en transcriptie. Transcripties worden via iCloud met je Mac gesynchroniseerd wanneer iCloud hierboven aanstaat.")
            }
            .listRowBackground(Theme.surface)
        }
        .onAppear {
            if let saved = PlaudCredentials.load() {
                email = saved.email
                hasSavedCredentials = saved.isConfigured
            }
        }
    }

    private func credentialsForAction() -> PlaudCredentials? {
        if password.isEmpty, let saved = PlaudCredentials.load() { return saved }
        let credentials = PlaudCredentials(
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
        return credentials.isConfigured ? credentials : nil
    }

    private func saveCredentials() {
        guard let credentials = credentialsForAction() else { return }
        do {
            try credentials.save()
            hasSavedCredentials = true
            password = ""
            testMessage = L10n.string( "Account opgeslagen", locale: app.interfaceLanguage.locale)
            testSucceeded = true
        } catch {
            testMessage = L10n.string(
                "PLAUD-account kon niet veilig worden opgeslagen.",
                locale: app.interfaceLanguage.locale
            )
            testSucceeded = false
        }
    }

    private func testConnection() async {
        guard let credentials = credentialsForAction() else { return }
        isTesting = true
        let error = await service.testConnection(credentials)
        isTesting = false
        if let error {
            testMessage = error
            testSucceeded = false
        } else {
            testMessage = L10n.string( "Verbinding geslaagd", locale: app.interfaceLanguage.locale)
            testSucceeded = true
        }
    }
}

/// Het vertrouwde synchronisatie-icoon is zelf de activiteitsindicator. Zo ziet
/// de gebruiker meteen dat de tik is aangekomen, ook vóór de eerste opname is
/// opgehaald en de voortgangsbalk kan bewegen.
private struct RotatingSyncIcon: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { context in
            let angle = active
                ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
                : 0
            Image(systemName: "arrow.triangle.2.circlepath")
                .rotationEffect(.degrees(angle))
                .frame(width: 20, height: 20)
        }
    }
}
