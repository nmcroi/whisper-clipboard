import Core
import SwiftUI
import WhisperShared

/// Instellingen-sheet: thema, iCloud-sync, de Claude API-key (AI-nabewerking) en
/// een "Over"-blok.
struct SettingsSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    // MARK: - AI (Claude) key state

    /// Of er al een key in de Keychain staat (gemaskeerd getoond).
    @State private var hasStoredKey = KeychainStore.hasKey()
    /// Invoerveld voor een nieuwe key (leeg wanneer er een key is opgeslagen).
    @State private var apiKeyInput = ""
    /// Bezig met een verbindingstest.
    @State private var isTesting = false
    /// Resultaat van de laatste verbindingstest (Dutch), nil = nog niet getest.
    @State private var testResult: KeyTestResult?

    private enum KeyTestResult: Equatable {
        case success
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.window.ignoresSafeArea()
                Form {
                    Section("Thema") {
                        Picker("Weergave", selection: $app.appearance) {
                            ForEach(AppSettings.AppearanceMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .listRowBackground(Theme.surface)

                    Section {
                        NavigationLink {
                            DictionaryiOSView()
                        } label: {
                            Label("Woordenlijst", systemImage: "character.book.closed")
                                .foregroundStyle(Theme.text)
                        }
                    } header: {
                        Text("Transcriptie")
                    } footer: {
                        Text("Eigen woorden die de spraakherkenning moet corrigeren. Synchroniseert automatisch met je Mac via iCloud.")
                    }
                    .listRowBackground(Theme.surface)

                    Section {
                        Toggle("Geschiedenis synchroniseren via iCloud", isOn: $app.icloudSyncEnabled)
                            .tint(Theme.accent)

                        HStack(spacing: 12) {
                            Text("Status: \(app.historySync?.status.dutchLabel ?? "niet beschikbaar")")
                                .font(ThemeFont.ui(12))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Synchroniseer nu") {
                                Task { await app.historySync?.syncNow() }
                            }
                            .font(ThemeFont.ui(12, weight: .medium))
                            .disabled(!app.icloudSyncEnabled)
                        }
                    } header: {
                        Text("iCloud")
                    } footer: {
                        Text("Deelt je transcript-geschiedenis met je andere apparaten (bijv. je Mac) via je eigen iCloud. Er komt geen externe server aan te pas.")
                    }
                    .listRowBackground(Theme.surface)

                    aiSection

                    Section {
                        LabeledContent("Model", value: "Parakeet TDT 0.6b v3")
                        LabeledContent("Taal", value: "Nederlands")
                    } header: {
                        Text("Over")
                    } footer: {
                        Text("Alle transcriptie gebeurt lokaal op je iPhone. Er verlaat geen audio je toestel.")
                    }
                    .listRowBackground(Theme.surface)
                }
                .scrollContentBackground(.hidden)
                .foregroundStyle(Theme.text)
            }
            .navigationTitle("Instellingen")
            .onChange(of: apiKeyInput) { _, _ in testResult = nil }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Gereed") { dismiss() }
                        .foregroundStyle(Theme.accentText)
                }
            }
        }
    }

    // MARK: - AI (Claude) section

    @ViewBuilder
    private var aiSection: some View {
        Section {
            if hasStoredKey {
                LabeledContent("API-key", value: "•••• opgeslagen")
                Button(role: .destructive) {
                    try? KeychainStore.delete()
                    hasStoredKey = false
                    apiKeyInput = ""
                    testResult = nil
                } label: {
                    Label("Verwijder key", systemImage: "trash")
                }
                .foregroundStyle(Theme.danger)
            } else {
                SecureField("sk-ant-…", text: $apiKeyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(ThemeFont.ui(16))
                Button {
                    saveKey()
                } label: {
                    Label("Opslaan", systemImage: "checkmark.circle")
                }
                .foregroundStyle(Theme.accentText)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    Label("Verbinding testen", systemImage: "bolt.horizontal.circle")
                    if isTesting {
                        Spacer()
                        ProgressView().tint(Theme.accent)
                    }
                }
            }
            .foregroundStyle(Theme.text)
            .disabled(isTesting || (!hasStoredKey && apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))

            switch testResult {
            case .success:
                Label("Verbinding geslaagd", systemImage: "checkmark.seal.fill")
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
            Text("AI (Claude)")
        } footer: {
            Text("Nodig om transcripties en notities te laten samenvatten of herschrijven met Claude. De sleutel wordt alleen op dit toestel in de Keychain bewaard en synchroniseert niet vanaf je Mac.")
        }
        .listRowBackground(Theme.surface)
    }

    private func saveKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try KeychainStore.save(trimmed)
            hasStoredKey = true
            apiKeyInput = ""
            testResult = nil
        } catch {
            testResult = .failure("Kon de key niet opslaan in de Keychain.")
        }
    }

    /// Minimale round-trip om de key te valideren. Gebruikt de zojuist ingevoerde
    /// key (nog niet opgeslagen) of de opgeslagen key.
    private func testConnection() async {
        // Sla een verse invoer eerst op, zodat de test de echte key gebruikt.
        if !hasStoredKey {
            saveKey()
        }
        guard let key = try? KeychainStore.read(), !key.isEmpty else {
            testResult = .failure(ClaudeError.missingKey.localizedDescription)
            return
        }
        isTesting = true
        testResult = nil
        defer { isTesting = false }
        let client = ClaudeClient(apiKey: key)
        do {
            _ = try await client.completeText(system: "Antwoord met het woord OK.", user: "Test")
            testResult = .success
        } catch let error as ClaudeError {
            testResult = .failure(error.localizedDescription)
        } catch {
            testResult = .failure(ClaudeError.server(error.localizedDescription).localizedDescription)
        }
    }
}
