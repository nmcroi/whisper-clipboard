import Core
import SwiftUI

/// The "PLAUD" settings tab: connect a PLAUD account so NotePin recordings are
/// pulled from PLAUD's cloud and run through Whisper Clipboard's transcription
/// pipeline automatically.
///
/// Email is stored in `AppSettings` (for display); the password/token live
/// **only** in the Keychain (``PlaudCredentials``). "Verbinding testen" performs
/// a real login and reports the result in Dutch. A status area shows the last
/// sync time, imported count, and last error.
struct PlaudSettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var email = ""
    @State private var password = ""
    @State private var loaded = false
    @State private var testState: TestState = .idle
    /// Cached "are persisted credentials configured?" — set in `loadCredentials()`
    /// and after every save/test, so `body` never does a synchronous Keychain read
    /// (`SecItemCopyMatching`) on each SwiftUI render.
    @State private var credentialsSaved = false

    enum TestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider().overlay(Theme.border)
                accountSection
                Divider().overlay(Theme.border)
                syncSection
                Divider().overlay(Theme.border)
                statusSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.window)
        .onAppear(perform: loadCredentials)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text.accentDotted("PLAUD")
            .font(ThemeFont.ui(18, weight: .bold))

            Text("Haal je PLAUD-opnamen automatisch uit de cloud en laat ze door Whisper Clipboard transcriberen. Dit gebruikt PLAUD's onofficiële cloud-API met jouw eigen account.")
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Let op: een opname verschijnt hier pas nadat hij vanaf je NotePin naar PLAUD is gesynchroniseerd (via de PLAUD-app).")
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PLAUD-account")
                .font(ThemeFont.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Je wachtwoord wordt veilig in de Sleutelhanger bewaard en verlaat je Mac niet, behalve om in te loggen bij PLAUD.")
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("E-mailadres")
                    .font(ThemeFont.ui(11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                TextField("jij@voorbeeld.nl", text: $email)
                    .textFieldStyle(.plain)
                    .font(ThemeFont.ui(12))
                    .foregroundStyle(Theme.text)
                    .textContentType(.username)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.surfaceHover)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))
                    .onChange(of: email) { _, _ in testState = .idle }

                Text("Wachtwoord")
                    .font(ThemeFont.ui(11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 8) {
                    SecureField("••••••••", text: $password)
                        .textFieldStyle(.plain)
                        .font(ThemeFont.ui(12))
                        .foregroundStyle(Theme.text)
                        .textContentType(.password)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Theme.surfaceHover)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))
                        .onChange(of: password) { _, _ in testState = .idle }

                    Button("Bewaar") { saveCredentials() }
                        .buttonStyle(AccentButtonStyle())
                }
            }

            HStack(spacing: 10) {
                Button("Verbinding testen") { testConnection() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(testState == .testing || !credentialsEntered)

                testIndicator
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var testIndicator: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).tint(Theme.accent)
                Text("Testen…").font(ThemeFont.ui(11)).foregroundStyle(Theme.textSecondary)
            }
        case .success:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accentText)
                Text("Verbinding oké").font(ThemeFont.ui(11)).foregroundStyle(Theme.textSecondary)
            }
        case .failure(let message):
            HStack(spacing: 5) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
                Text(message).font(ThemeFont.ui(11)).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Sync settings

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Automatisch synchroniseren")
                .font(ThemeFont.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)

            Toggle(isOn: Binding(
                get: { environment.settings.plaudSyncEnabled },
                set: { newValue in
                    environment.settings.plaudSyncEnabled = newValue
                    environment.plaudSync.refresh()
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PLAUD-opnamen automatisch ophalen")
                        .font(ThemeFont.ui(13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text("Controleert periodiek op nieuwe opnamen in je PLAUD-cloud en transcribeert ze. Al opgehaalde opnamen worden nooit dubbel verwerkt.")
                        .font(ThemeFont.ui(11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)

            // Interval stepper.
            HStack {
                Text("Interval")
                    .font(ThemeFont.ui(13))
                    .foregroundStyle(Theme.text)
                Spacer()
                Stepper(value: Binding(
                    get: { environment.settings.plaudSyncIntervalMinutes },
                    set: { newValue in
                        environment.settings.plaudSyncIntervalMinutes = PlaudSyncLogic.clampIntervalMinutes(newValue)
                        environment.plaudSync.refresh()
                    }
                ), in: 1...240, step: 1) {
                    Text("Elke \(environment.settings.plaudSyncIntervalMinutes) min")
                        .font(ThemeFont.ui(12))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
                .fixedSize()
                .tint(Theme.accent)
            }
            .disabled(!environment.settings.plaudSyncEnabled)
            .opacity(environment.settings.plaudSyncEnabled ? 1 : 0.5)

            // Manual sync.
            HStack(spacing: 10) {
                Button {
                    environment.plaudSync.syncNow()
                } label: {
                    Label("Synchroniseer nu", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(!credentialsSaved || environment.plaudSync.isSyncing)

                if environment.plaudSync.isSyncing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(Theme.accent)
                        Text("Synchroniseren…").font(ThemeFont.ui(11)).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Status")
                .font(ThemeFont.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)

            VStack(alignment: .leading, spacing: 8) {
                statusRow(label: "Laatste synchronisatie", value: lastSyncedText)
                Divider().overlay(Theme.border)
                statusRow(label: "Aantal geïmporteerd", value: "\(environment.plaudSync.lastImportedCount)")
                Divider().overlay(Theme.border)
                statusRow(
                    label: "Laatste fout",
                    value: environment.plaudSync.lastError ?? "Geen",
                    valueColor: environment.plaudSync.lastError == nil ? Theme.textSecondary : Theme.danger
                )
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themeCard()
        }
    }

    private func statusRow(label: String, value: String, valueColor: Color = Theme.textSecondary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(ThemeFont.ui(12, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: 170, alignment: .leading)
            Text(value)
                .font(ThemeFont.ui(12))
                .foregroundStyle(valueColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lastSyncedText: String {
        guard let date = environment.plaudSync.lastSyncedAt else { return "Nog niet" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "nl_NL")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Derived

    private var credentialsEntered: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The credentials currently entered in the fields (trimmed email).
    private var currentCredentials: PlaudCredentials {
        PlaudCredentials(
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
    }

    // MARK: - Actions

    private func loadCredentials() {
        guard !loaded else { return }
        if let creds = PlaudCredentials.load() {
            email = creds.email
            password = creds.password
            credentialsSaved = creds.isConfigured
        } else {
            email = environment.settings.plaudEmail
            credentialsSaved = false
        }
        loaded = true
    }

    /// Saves the entered credentials to the Keychain. Returns the saved
    /// credentials on success (so callers can reuse them) or nil on failure.
    @discardableResult
    private func saveCredentials() -> PlaudCredentials? {
        let creds = currentCredentials
        do {
            try creds.save()
            // Mirror the email into settings for display; the password stays only
            // in the Keychain.
            environment.settings.plaudEmail = creds.email
            credentialsSaved = creds.isConfigured
            testState = .idle
            return creds
        } catch {
            testState = .failure("Kon de inloggegevens niet bewaren.")
            return nil
        }
    }

    private func testConnection() {
        guard credentialsEntered else { return }
        // Persist first so a successful test reflects what will actually be used,
        // and reuse the exact credentials we just saved (no second build).
        guard let creds = saveCredentials() else { return }
        testState = .testing
        Task {
            let error = await environment.plaudSync.testConnection(creds)
            if let error {
                testState = .failure(error)
            } else {
                testState = .success
            }
        }
    }
}

#Preview {
    PlaudSettingsView()
        .environmentObject(AppEnvironment())
        .frame(width: 560, height: 460)
        .preferredColorScheme(.dark)
}
