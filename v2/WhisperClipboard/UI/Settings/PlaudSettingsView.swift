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
    /// True while the interval "Aangepast…" custom field is shown. Set on appear to
    /// match a stored value that isn't one of the presets, and toggled by the Picker.
    @State private var intervalIsCustom = false
    /// The raw text in the custom-interval field (minutes). Committed (clamped) on
    /// submit/blur; kept as text so a mid-edit empty field doesn't reset to 1.
    @State private var customIntervalText = ""

    enum TestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    /// Sensible interval presets (minutes) offered in the menu, plus an
    /// "Aangepast…" escape hatch for any other value.
    private static let intervalPresets = [5, 10, 15, 30, 60, 120, 240]

    /// Window presets (days) offered near the sync section; `0` = "Alles" (all
    /// history). Wired to `plaudSyncWindowDays`.
    private static let windowPresets = [7, 30, 90, 365, 0]

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

            // Interval: a menu of sensible presets plus an "Aangepast…" option that
            // reveals a numeric field for any value (1…1440 min).
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Interval")
                        .font(ThemeFont.ui(13))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Picker("", selection: intervalPickerSelection) {
                        ForEach(Self.intervalPresets, id: \.self) { minutes in
                            Text(Self.intervalLabel(minutes)).tag(minutes)
                        }
                        Divider()
                        Text("Aangepast…").tag(Self.customIntervalTag)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .tint(Theme.accent)
                }

                if intervalIsCustom {
                    HStack(spacing: 8) {
                        TextField("minuten", text: $customIntervalText)
                            .textFieldStyle(.plain)
                            .font(ThemeFont.ui(12))
                            .foregroundStyle(Theme.text)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.surfaceHover)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))
                            .onSubmit(commitCustomInterval)
                        Text("minuten (1–1440)")
                            .font(ThemeFont.ui(11))
                            .foregroundStyle(Theme.textSecondary)
                        Button("Toepassen", action: commitCustomInterval)
                            .buttonStyle(SecondaryButtonStyle())
                        Spacer(minLength: 0)
                    }
                }
            }
            .disabled(!environment.settings.plaudSyncEnabled)
            .opacity(environment.settings.plaudSyncEnabled ? 1 : 0.5)

            // Sync window: how far back a sync looks. Same preset-menu pattern.
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Haal de laatste dagen op")
                        .font(ThemeFont.ui(13))
                        .foregroundStyle(Theme.text)
                    Text("Beperkt hoe ver terug een synchronisatie zoekt. Voorkomt dat de eerste keer je hele PLAUD-geschiedenis wordt opgehaald.")
                        .font(ThemeFont.ui(11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Picker("", selection: Binding(
                    get: { environment.settings.plaudSyncWindowDays },
                    set: { environment.settings.plaudSyncWindowDays = max(0, $0) }
                )) {
                    ForEach(Self.windowPresets, id: \.self) { days in
                        Text(Self.windowLabel(days)).tag(days)
                    }
                    // Show a stored non-preset value as a selectable extra tag so the
                    // menu doesn't blank out (e.g. a hand-edited settings.json).
                    if !Self.windowPresets.contains(environment.settings.plaudSyncWindowDays) {
                        Text(Self.windowLabel(environment.settings.plaudSyncWindowDays))
                            .tag(environment.settings.plaudSyncWindowDays)
                    }
                }
                .labelsHidden()
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

    // MARK: - Interval picker helpers

    /// Sentinel tag for the "Aangepast…" menu item (an out-of-range minute value so
    /// it can never collide with a real interval).
    private static let customIntervalTag = -1

    /// Binding driving the interval Picker. Reading maps the stored interval to a
    /// preset tag, or the custom tag when it isn't a preset (so a custom value shows
    /// as "Aangepast…" selected). Writing either applies a preset immediately or
    /// switches into custom mode (seeding the field with the current value).
    private var intervalPickerSelection: Binding<Int> {
        Binding(
            get: {
                let current = environment.settings.plaudSyncIntervalMinutes
                if intervalIsCustom { return Self.customIntervalTag }
                return Self.intervalPresets.contains(current) ? current : Self.customIntervalTag
            },
            set: { tag in
                if tag == Self.customIntervalTag {
                    // Enter custom mode; seed the field with the current interval.
                    customIntervalText = String(environment.settings.plaudSyncIntervalMinutes)
                    intervalIsCustom = true
                } else {
                    intervalIsCustom = false
                    applyInterval(tag)
                }
            }
        )
    }

    /// Applies a new poll interval (clamped) and reschedules the sync timer so the
    /// change takes effect without relaunch.
    private func applyInterval(_ minutes: Int) {
        environment.settings.plaudSyncIntervalMinutes = PlaudSyncLogic.clampIntervalMinutes(minutes)
        environment.plaudSync.refresh()
    }

    /// Commits the custom-interval field: parse → clamp → apply. An unparseable or
    /// empty field falls back to the current stored value (no-op) and re-syncs the
    /// text so the field shows the effective value.
    private func commitCustomInterval() {
        let trimmed = customIntervalText.trimmingCharacters(in: .whitespaces)
        if let value = Int(trimmed) {
            applyInterval(value)
        }
        // Reflect the clamped/effective value back into the field.
        customIntervalText = String(environment.settings.plaudSyncIntervalMinutes)
    }

    /// A Dutch label for an interval preset, e.g. "Elke 30 minuten" / "Elk uur".
    private static func intervalLabel(_ minutes: Int) -> String {
        switch minutes {
        case 60: return "Elk uur"
        case 120: return "Elke 2 uur"
        case 240: return "Elke 4 uur"
        default: return "Elke \(minutes) minuten"
        }
    }

    /// A Dutch label for a window preset (days); `0` = "Alles".
    private static func windowLabel(_ days: Int) -> String {
        switch days {
        case 0: return "Alles"
        case 365: return "1 jaar"
        default: return "\(days) dagen"
        }
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
        // Open the interval control in custom mode when the stored value isn't a
        // preset, seeding the field so it shows the actual value.
        let interval = environment.settings.plaudSyncIntervalMinutes
        if !Self.intervalPresets.contains(interval) {
            intervalIsCustom = true
            customIntervalText = String(interval)
        }
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
