import Core
import Charts
import SwiftUI
import WhisperShared

/// Instellingen-sheet: thema, transcriptie, iCloud en afzonderlijke BYOK-
/// instellingen voor Claude, OpenAI en Gemini.
struct SettingsSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    // MARK: - AI provider state

    @State private var storedKeyProviders = Set(
        AIProvider.allCases.filter { KeychainStore.hasKey(for: $0) }
    )
    @State private var apiKeyInputs: [AIProvider: String] = [:]
    @State private var testingProvider: AIProvider?
    @State private var testResults: [AIProvider: KeyTestResult] = [:]
    @State private var liveModels: [AIProvider: [String]] = [:]
    /// Tweede, expliciete bevestiging voordat bestaande lokale data naar het
    /// huidige iCloud-account mag worden gestuurd.
    @State private var showICloudMergeConfirmation = false

    private enum KeyTestResult: Equatable {
        case success
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.window.ignoresSafeArea()
                Form {
                    Section {
                        NavigationLink {
                            generalSettings
                        } label: {
                            settingsLink("Algemeen", symbol: "slider.horizontal.3")
                        }
                        NavigationLink {
                            transcriptionSettings
                        } label: {
                            settingsLink("Opnemen en transcriptie", symbol: "waveform")
                        }
                        NavigationLink {
                            meetingSettings
                        } label: {
                            settingsLink("Notulen", symbol: "person.2.wave.2")
                        }
                        NavigationLink {
                            aiSettings
                        } label: {
                            settingsLink("AI", symbol: "sparkles")
                        }
                        NavigationLink {
                            syncSettings
                        } label: {
                            settingsLink("Synchronisatie", symbol: "arrow.triangle.2.circlepath")
                        }
                        NavigationLink {
                            aboutSettings
                        } label: {
                            settingsLink("Privacy en over WhisperClip", symbol: "hand.raised")
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
                .scrollContentBackground(.hidden)
                .foregroundStyle(Theme.text)
            }
            .navigationTitle(Text(verbatim: L10n.string(
                "Instellingen",
                locale: app.interfaceLanguage.locale
            )))
            .alert("Lokale geschiedenis samenvoegen?", isPresented: $showICloudMergeConfirmation) {
                Button("Annuleer", role: .cancel) {}
                Button("Samenvoegen") {
                    Task { await app.historySync?.approveCurrentAccountMerge() }
                }
            } message: {
                Text(iCloudApprovalMessage)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Gereed") { dismiss() }
                        .foregroundStyle(Theme.accentText)
                }
            }
        }
        // Navigation titles/back labels are cached by iOS while a stack is
        // pushed. Recreate this settings stack after a language switch so no
        // title remains in the previous language.
        .id(app.interfaceLanguage)
    }

    private func settingsLink(_ title: LocalizedStringKey, symbol: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: 32, alignment: .center)
            Text(title)
                .foregroundStyle(Theme.text)
            Spacer()
        }
        .padding(.vertical, 7)
    }

    private var generalSettings: some View {
        Form {
            Section("Weergave") {
                Picker("Taal van de app", selection: $app.interfaceLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.pickerLabel(in: app.interfaceLanguage)).tag(language)
                    }
                }
                Picker("Weergave", selection: $app.appearance) {
                    ForEach(AppSettings.AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.label(in: app.interfaceLanguage)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Hulptips tonen", isOn: $app.showHelpTips)
                    .tint(Theme.accent)
            }
            .listRowBackground(Theme.surface)
        }
        .settingsPageStyle()
        .navigationTitle("Algemeen")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var transcriptionSettings: some View {
        Form {
            Section {
                NavigationLink {
                    DictionaryiOSView()
                } label: {
                    Label("Woordenlijst", systemImage: "character.book.closed")
                }
            } footer: {
                Text("Voeg eigen namen en woorden toe die de spraakherkenning moet corrigeren.")
            }
            .listRowBackground(Theme.surface)
            Section("Spraakherkenning") {
                Picker("Transcriptietaal", selection: $app.transcriptionLanguage) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.whisperClipLabel(in: app.interfaceLanguage)).tag(language)
                    }
                }
                LabeledContent("Model", value: "Parakeet TDT 0.6b v3")
            }
            .listRowBackground(Theme.surface)
        }
        .settingsPageStyle()
        .navigationTitle("Opnemen en transcriptie")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var meetingSettings: some View {
        Form {
            Section {
                NavigationLink {
                    MeetingContactsSettingsView()
                } label: {
                    Label("Vaste deelnemers", systemImage: "person.2")
                }
            } footer: {
                Text("Beheer ontvangers die je snel aan een vergadering kunt toevoegen.")
            }
            .listRowBackground(Theme.surface)
            Section {
                Toggle("AI bij Notulen toestaan", isOn: $app.allowMeetingAI)
                    .tint(Theme.accent)
                    .disabled(!app.hasAPIKey(for: app.aiProvider))
            } footer: {
                if app.hasAPIKey(for: app.aiProvider) {
                    Text(String(
                        format: L10n.string( "AI staat per vergadering opnieuw standaard uit. Alleen transcripttekst gaat naar %@, nooit audio.", locale: app.interfaceLanguage.locale),
                        locale: app.interfaceLanguage.locale,
                        app.aiProvider.displayName
                    ))
                } else {
                    Text(String(
                        format: L10n.string( "Stel eerst onder AI een API-key voor %@ in. Daarna kun je AI voor Notulen toestaan.", locale: app.interfaceLanguage.locale),
                        locale: app.interfaceLanguage.locale,
                        app.aiProvider.displayName
                    ))
                }
            }
            .listRowBackground(Theme.surface)
        }
        .settingsPageStyle()
        .navigationTitle("Notulen")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var aiSettings: some View {
        Form { aiSection }
            .settingsPageStyle()
            .navigationTitle("AI")
            .navigationBarTitleDisplayMode(.inline)
    }

    private var syncSettings: some View {
        Form {
            Section {
                Toggle("Synchroniseren via iCloud", isOn: $app.icloudSyncEnabled)
                    .tint(Theme.accent)
                    .disabled(!Self.iCloudControlsEnabled)
                if let sync = app.historySync {
                    Text(String(
                        format: L10n.string( "Status: %@", locale: app.interfaceLanguage.locale),
                        locale: app.interfaceLanguage.locale,
                        sync.status.label(in: app.interfaceLanguage)
                    ))
                        .font(ThemeFont.ui(13))
                        .foregroundStyle(Theme.textSecondary)
                    if syncRequiresApproval {
                        Button("Koppel dit iCloud-account") { showICloudMergeConfirmation = true }
                            .foregroundStyle(Theme.accentText)
                    } else if app.icloudSyncEnabled {
                        Button { Task { await sync.syncNow() } } label: {
                            Label("Synchroniseer iCloud", systemImage: "arrow.triangle.2.circlepath")
                                .font(ThemeFont.ui(17, weight: .semibold))
                                .foregroundStyle(Color.black)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)
                                .padding(.horizontal, 18)
                                .background(Theme.accent, in: Capsule())
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 7) {
                    Text("iCloud")
                        .font(ThemeFont.ui(22, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text("Bewaart je gesynchroniseerde geschiedenis, notities, woordenlijst en vaste deelnemers in je persoonlijke iCloud en houdt WhisperClip op je iPhone en Mac gelijk.")
                        .font(ThemeFont.ui(14))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textCase(nil)
                }
                .padding(.bottom, 5)
            }
            .listRowBackground(Theme.surface)
            #if WHISPERCLIP_PERSONAL || !WHISPERCLIP_PUBLIC
            PlaudSettingsContent(service: app.plaudSync)
            #endif
        }
        .settingsPageStyle()
        .navigationTitle("Synchronisatie")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var aboutSettings: some View {
        Form {
            Section("WhisperClip") {
                LabeledContent(
                    "Transcriptietaal",
                    value: app.transcriptionLanguage.whisperClipLabel(in: app.interfaceLanguage)
                )
                LabeledContent("Model", value: "Parakeet TDT 0.6b v3")
            }
            .listRowBackground(Theme.surface)
            Section("Privacy") {
                Label("Transcriptie gebeurt lokaal", systemImage: "iphone")
                Label("Tijdelijke audio wordt na transcriptie verwijderd", systemImage: "waveform.slash")
                Label("Er verlaat geen audio je toestel", systemImage: "lock.shield")
            }
            .listRowBackground(Theme.surface)
        }
        .settingsPageStyle()
        .navigationTitle("Privacy en over")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static var iCloudControlsEnabled: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private var syncRequiresApproval: Bool {
        guard let sync = app.historySync else { return false }
        if case .requiresApproval = sync.status { return true }
        return false
    }

    private var iCloudApprovalMessage: String {
        guard let sync = app.historySync,
              case .requiresApproval(let localCount, let accountChanged) = sync.status
        else { return "" }
        let locale = app.interfaceLanguage.locale
        if accountChanged {
            return String(
                format: L10n.string( "Er is een ander iCloud-account aangemeld. Voeg de %lld lokale items alleen samen als deze geschiedenis bij dat account mag horen. Er wordt niets lokaal verwijderd.", locale: locale),
                locale: locale,
                localCount
            )
        }
        return String(
            format: L10n.string( "De %lld bestaande lokale items worden samengevoegd met dit iCloud-account. Er wordt niets lokaal verwijderd.", locale: locale),
            locale: locale,
            localCount
        )
    }

    // MARK: - AI providers

    @ViewBuilder
    private var aiSection: some View {
        Section {
            Picker("Standaardaanbieder", selection: $app.aiProvider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }

            Picker("Standaardmodel", selection: modelBinding(for: app.aiProvider)) {
                ForEach(models(for: app.aiProvider), id: \.self) { model in
                    Text(model).tag(model)
                }
            }

            Text("Bij iedere AI-opdracht wordt zichtbaar welke aanbieder en welk model de gekozen transcripttekst ontvangen. Audio wordt nooit verstuurd.")
                .font(ThemeFont.ui(13))
                .foregroundStyle(Theme.textSecondary)
        } header: {
            Text("Standaard voor AI-opdrachten")
        }
        .listRowBackground(Theme.surface)

        ForEach(AIProvider.allCases) { provider in
            Section {
                Picker("Model", selection: modelBinding(for: provider)) {
                    ForEach(models(for: provider), id: \.self) { model in
                        Text(model).tag(model)
                    }
                }

                if storedKeyProviders.contains(provider) {
                    HStack {
                        Text("API-key")
                        Spacer()
                        // Een opgeslagen waarde is status, geen hoofdinhoud, en
                        // hoort dus grijs (bevinding 2026-08-02).
                        Text(L10n.string( "•••• opgeslagen", locale: app.interfaceLanguage.locale))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Button(role: .destructive) {
                        deleteKey(for: provider)
                    } label: {
                        Label("Verwijder API-key", systemImage: "trash")
                    }
                    .foregroundStyle(Theme.danger)
                } else {
                    SecureField(keyPlaceholder(for: provider), text: keyInputBinding(for: provider))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(ThemeFont.ui(16))
                    Button {
                        saveKey(for: provider)
                    } label: {
                        Label("API-key opslaan", systemImage: "checkmark.circle")
                    }
                    // Geel zolang de knop werkelijk iets doet; gedempt zodra er
                    // niets in te vullen valt (bevinding 2026-08-02).
                    .foregroundStyle(canSaveKey(for: provider) ? Theme.accentText : Theme.textSecondary)
                    .disabled(!canSaveKey(for: provider))
                }

                Button {
                    Task { await testConnection(for: provider) }
                } label: {
                    HStack {
                        Label("Verbinding en modellen testen", systemImage: "bolt.horizontal.circle")
                        if testingProvider == provider {
                            Spacer()
                            ProgressView().tint(Theme.accent)
                        }
                    }
                }
                .foregroundStyle(canTestConnection(for: provider) ? Theme.accentText : Theme.textSecondary)
                .disabled(!canTestConnection(for: provider))

                switch testResults[provider] {
                case .success:
                    Label("Verbinding geslaagd; modellen bijgewerkt", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.accentText)
                        .font(ThemeFont.ui(14))
                case .failure(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                        .font(ThemeFont.ui(14))
                case nil:
                    EmptyView()
                }
            } header: {
                // Zelfde rang en vorm als de koppen bij iCloud en PLAUD, zodat
                // herkenbaar is wat een titel is (bevinding 2026-08-02).
                Text(provider.displayName)
                    .font(ThemeFont.ui(22, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .textCase(nil)
                    .padding(.top, 10)
                    .padding(.bottom, 5)
            } footer: {
                Text("De sleutel staat alleen in de Keychain van dit toestel en wordt niet gesynchroniseerd of gelogd.")
            }
            .listRowBackground(Theme.surface)
        }

        if let modes = app.modes {
            Section {
                NavigationLink {
                    APIUsageDetailView(modes: modes)
                } label: {
                    HStack {
                        Label("API-verbruik", systemImage: "dollarsign.circle")
                            .font(ThemeFont.ui(15, weight: .semibold))
                        Spacer()
                        // Deze rij navigeert naar een volgende pagina en heeft
                        // dus al een pijltje; geel is hier voorbehouden aan
                        // acties zonder pijltje (regel Niels, 2026-08-02).
                        Text(modes.estimatedCostUSD.formatted(
                            .currency(code: "USD").locale(app.interfaceLanguage.locale)
                        ))
                            .font(ThemeFont.ui(17, weight: .bold))
                            .foregroundStyle(Theme.text)
                    }
                }
            } footer: {
                Text("Tokenaantallen en kosten zijn schattingen per aanbieder en model; de factuur van de aanbieder is altijd leidend.")
            }
            .listRowBackground(Theme.surface)
        }
    }

    private func models(for provider: AIProvider) -> [String] {
        var values = liveModels[provider] ?? provider.fallbackModels
        let selected = app.selectedModel(for: provider)
        if !values.contains(selected) { values.insert(selected, at: 0) }
        return values
    }

    private func modelBinding(for provider: AIProvider) -> Binding<String> {
        Binding(
            get: { app.selectedModel(for: provider) },
            set: { app.setSelectedModel($0, for: provider) }
        )
    }

    private func keyInputBinding(for provider: AIProvider) -> Binding<String> {
        Binding(
            get: { keyInput(for: provider) },
            set: {
                apiKeyInputs[provider] = $0
                testResults[provider] = nil
            }
        )
    }

    private func keyInput(for provider: AIProvider) -> String {
        apiKeyInputs[provider] ?? ""
    }

    /// Er valt alleen iets op te slaan zodra er werkelijk tekst is ingevoerd.
    private func canSaveKey(for provider: AIProvider) -> Bool {
        !keyInput(for: provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Testen kan met een opgeslagen sleutel of met een zojuist ingevoerde, en
    /// nooit terwijl er al een test loopt.
    private func canTestConnection(for provider: AIProvider) -> Bool {
        guard testingProvider == nil else { return false }
        return storedKeyProviders.contains(provider) || canSaveKey(for: provider)
    }

    private func keyPlaceholder(for provider: AIProvider) -> String {
        switch provider {
        case .anthropic: "sk-ant-…"
        case .openAI: "sk-…"
        case .gemini: "AIza…"
        }
    }

    private func saveKey(for provider: AIProvider) {
        let value = keyInput(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try KeychainStore.save(value, for: provider)
            storedKeyProviders.insert(provider)
            apiKeyInputs[provider] = ""
            testResults[provider] = nil
        } catch {
            testResults[provider] = .failure(String(
                localized: "Kon de API-key niet opslaan in de Keychain.",
                locale: app.interfaceLanguage.locale
            ))
        }
    }

    private func deleteKey(for provider: AIProvider) {
        do {
            try KeychainStore.delete(for: provider)
        } catch {
            testResults[provider] = .failure(L10n.string(
                "Kon de API-key niet uit de Keychain verwijderen.",
                locale: app.interfaceLanguage.locale
            ))
            return
        }
        storedKeyProviders.remove(provider)
        apiKeyInputs[provider] = ""
        liveModels[provider] = nil
        testResults[provider] = nil
        if provider == app.aiProvider { app.allowMeetingAI = false }
    }

    private func testConnection(for provider: AIProvider) async {
        if !storedKeyProviders.contains(provider) { saveKey(for: provider) }
        guard let key = try? KeychainStore.read(for: provider), !key.isEmpty else {
            testResults[provider] = .failure(AIServiceError.missingKey(provider).localizedDescription)
            return
        }
        testingProvider = provider
        testResults[provider] = nil
        defer { testingProvider = nil }
        let client = AIClientFactory.make(provider: provider, apiKey: key)
        do {
            _ = try await client.completeText(
                system: "Answer with exactly OK.",
                user: "Connection test",
                model: app.selectedModel(for: provider)
            )
            let fetched = try await client.listModels()
            if !fetched.isEmpty {
                liveModels[provider] = fetched
                if !fetched.contains(app.selectedModel(for: provider)), let first = fetched.first {
                    app.setSelectedModel(first, for: provider)
                }
            }
            testResults[provider] = .success
        } catch {
            testResults[provider] = .failure(ErrorLocalization.message(for: error, language: app.interfaceLanguage))
        }
    }
}

private extension View {
    func settingsPageStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.window)
            .foregroundStyle(Theme.text)
    }
}

private struct APIUsageDetailView: View {
    @EnvironmentObject private var app: AppModel
    @Bindable var modes: ModesService
    @State private var grouping = UsageGrouping.day

    var body: some View {
        List {
            Section {
                Picker("Periode", selection: $grouping) {
                    ForEach(UsageGrouping.allCases) { Text($0.label(in: app.interfaceLanguage)).tag($0) }
                }
                .pickerStyle(.segmented)

                if buckets.isEmpty {
                    Text("Vanaf deze versie wordt elke AI-aanvraag afzonderlijk bijgehouden. Eerder gebruik is alleen in het totaal opgenomen.")
                        .font(ThemeFont.ui(14))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.vertical, 14)
                } else {
                    Chart(buckets) { bucket in
                        BarMark(
                            x: .value("Periode", bucket.date, unit: grouping.calendarComponent),
                            y: .value("Kosten", bucket.cost)
                        )
                        .foregroundStyle(Theme.accent)
                    }
                    .chartYAxisLabel("USD")
                    .frame(height: 210)
                    .padding(.vertical, 10)
                }
            } header: {
                Text("Kostenverloop")
            }

            Section("Overzicht") {
                usageRow(L10n.string( "Vandaag", locale: app.interfaceLanguage.locale), events: events(since: Calendar.current.startOfDay(for: Date())))
                usageRow(L10n.string( "Deze week", locale: app.interfaceLanguage.locale), events: events(since: startOfWeek))
                usageRow(L10n.string( "Deze maand", locale: app.interfaceLanguage.locale), events: events(since: startOfMonth))
                LabeledContent("Totaal", value: currency(modes.estimatedCostUSD))
            }

            if !providerTotals.isEmpty {
                Section("Per aanbieder en model") {
                    ForEach(providerTotals, id: \.name) { total in
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent(total.name, value: currency(total.cost))
                            Text(String(
                                format: L10n.string( "%1$@ tokens in · %2$@ uit", locale: app.interfaceLanguage.locale),
                                locale: app.interfaceLanguage.locale,
                                number(total.input),
                                number(total.output)
                            ))
                                .font(ThemeFont.ui(12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }

            if !buckets.isEmpty {
                Section("Per periode") {
                    ForEach(buckets.reversed()) { bucket in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(bucketLabel(bucket.date))
                                    .font(ThemeFont.ui(15, weight: .medium))
                                Text(String(
                                    format: L10n.string( "%1$@ in · %2$@ uit", locale: app.interfaceLanguage.locale),
                                    locale: app.interfaceLanguage.locale,
                                    number(bucket.input),
                                    number(bucket.output)
                                ))
                                    .font(ThemeFont.ui(12))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Text(currency(bucket.cost))
                                .font(ThemeFont.ui(14, weight: .semibold))
                                .foregroundStyle(bucket.id == peakBucket?.id ? Theme.accentText : Theme.text)
                        }
                    }
                }
            }

            if !modes.usageEvents.isEmpty {
                Section("Per AI-opdracht") {
                    ForEach(modeTotals, id: \.name) { total in
                        LabeledContent(total.name, value: currency(total.cost))
                    }
                }
            }
        }
        .navigationTitle("API-verbruik")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func usageRow(_ label: String, events: [ModesService.UsageEvent]) -> some View {
        let cost = events.reduce(0) { $0 + $1.estimatedCostUSD }
        return LabeledContent(label, value: currency(cost))
    }

    private func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(app.interfaceLanguage.locale))
    }

    private func number(_ value: Int) -> String {
        value.formatted(.number.locale(app.interfaceLanguage.locale))
    }

    private func events(since date: Date) -> [ModesService.UsageEvent] {
        modes.usageEvents.filter { $0.date >= date }
    }

    private var startOfWeek: Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
    }

    private var startOfMonth: Date {
        Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    }

    private var buckets: [UsageBucket] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: modes.usageEvents) { event in
            calendar.dateInterval(of: grouping.calendarComponent, for: event.date)?.start
                ?? calendar.startOfDay(for: event.date)
        }
        return groups.map { date, events in
            UsageBucket(
                date: date,
                input: events.reduce(0) { $0 + $1.inputTokens },
                output: events.reduce(0) { $0 + $1.outputTokens },
                cost: events.reduce(0) { $0 + $1.estimatedCostUSD }
            )
        }.sorted { $0.date < $1.date }
    }

    private var peakBucket: UsageBucket? { buckets.max { $0.cost < $1.cost } }

    private var modeTotals: [(name: String, cost: Double)] {
        Dictionary(grouping: modes.usageEvents, by: \.modeName)
            .map { name, events in (
                AIModeLocalization.localizedBuiltinName(name, language: app.interfaceLanguage) ?? name,
                events.reduce(0) { $0 + $1.estimatedCostUSD }
            ) }
            .sorted { $0.cost > $1.cost }
    }

    private var providerTotals: [(name: String, input: Int, output: Int, cost: Double)] {
        let groups = Dictionary(grouping: modes.usageEvents) { event in
            let provider = event.provider?.displayName ?? "Anthropic Claude"
            let model = event.model ?? L10n.string( "eerder model", locale: app.interfaceLanguage.locale)
            return "\(provider) · \(model)"
        }
        return groups.map { name, events in
            (
                name,
                events.reduce(0) { $0 + $1.inputTokens },
                events.reduce(0) { $0 + $1.outputTokens },
                events.reduce(0) { $0 + $1.estimatedCostUSD }
            )
        }.sorted { $0.name < $1.name }
    }

    private func bucketLabel(_ date: Date) -> String {
        switch grouping {
        case .day:
            date.formatted(.dateTime.day().month(.abbreviated).year().locale(app.interfaceLanguage.locale))
        case .week:
            String(
                format: L10n.string( "Week %1$lld · %2$@", locale: app.interfaceLanguage.locale),
                locale: app.interfaceLanguage.locale,
                Calendar.current.component(.weekOfYear, from: date),
                date.formatted(.dateTime.year().locale(app.interfaceLanguage.locale))
            )
        case .month:
            date.formatted(.dateTime.month(.wide).year().locale(app.interfaceLanguage.locale))
        }
    }
}

private enum UsageGrouping: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    func label(in language: AppLanguage) -> String { switch self {
    case .day: L10n.string( "Dag", locale: language.locale)
    case .week: L10n.string( "Week", locale: language.locale)
    case .month: L10n.string( "Maand", locale: language.locale)
    } }
    var calendarComponent: Calendar.Component { switch self { case .day: .day; case .week: .weekOfYear; case .month: .month } }
}

private struct UsageBucket: Identifiable {
    let date: Date
    let input: Int
    let output: Int
    let cost: Double
    var id: Date { date }
}

private struct MeetingContactsSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var newName = ""
    @State private var newEmail = ""

    var body: some View {
        Form {
            Section {
                ForEach($app.meetingContacts) { $contact in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Naam", text: $contact.name)
                        TextField("E-mailadres", text: $contact.email)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Toggle("Dit ben ik", isOn: Binding(
                            get: { contact.isMe },
                            set: { makeMe(contact.id, enabled: $0) }
                        ))
                        .tint(Theme.accent)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { app.meetingContacts.remove(atOffsets: $0) }
            } header: {
                Text("Opgeslagen")
            } footer: {
                Text("Tik op een naam of e-mailadres om het te wijzigen. ‘Dit ben ik’ wordt bij een nieuwe notulenopname alvast geselecteerd. De lijst synchroniseert met je Mac via iCloud.")
            }

            Section {
                TextField("Naam", text: $newName)
                TextField("E-mailadres", text: $newEmail)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Voeg toe") { addContact() }
                    .disabled(!newContactIsValid)
                if duplicateEmailWarning {
                    Text("Dit e-mailadres staat al in de lijst. Wijzig die deelnemer hierboven in plaats van een tweede toe te voegen.")
                        .font(ThemeFont.ui(13))
                        .foregroundStyle(Theme.danger)
                }
            } header: {
                Text("Deelnemer toevoegen")
            }
        }
        .navigationTitle("Vaste deelnemers")
    }

    private func addContact() {
        let contact = SavedMeetingContact(
            name: newName.trimmingCharacters(in: .whitespacesAndNewlines),
            email: newEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            isMe: app.meetingContacts.isEmpty
        )
        app.meetingContacts.append(contact)
        newName = ""
        newEmail = ""
    }

    private var newContactIsValid: Bool {
        SavedMeetingContact(
            name: newName.trimmingCharacters(in: .whitespacesAndNewlines),
            email: newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        ).isValid && !duplicateEmailWarning
    }

    /// Voorkomt de dubbele deelnemer die ontstond toen een correctie via dit
    /// formulier werd ingevoerd in plaats van in de lijst hierboven
    /// (bevinding 2026-08-02).
    private var duplicateEmailWarning: Bool {
        let candidate = newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return false }
        return app.meetingContacts.contains {
            $0.email.compare(candidate, options: .caseInsensitive) == .orderedSame
        }
    }

    private func makeMe(_ id: UUID, enabled: Bool) {
        for index in app.meetingContacts.indices {
            app.meetingContacts[index].isMe = enabled && app.meetingContacts[index].id == id
        }
    }
}
