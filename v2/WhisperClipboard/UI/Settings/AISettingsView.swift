import SwiftUI

/// The "AI" settings tab: Claude API key management (Keychain-backed) with a
/// connection test, and a custom-mode editor. Built-in modes are read-only but
/// duplicatable.
struct AISettingsView: View {
    @Bindable var modes: ModesService

    @State private var apiKey = ""
    @State private var keyLoaded = false
    @State private var testState: TestState = .idle
    @State private var editingMode: AIMode?
    @State private var showingEditor = false

    enum TestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                keySection
                Divider().overlay(Theme.border)
                modesSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.window)
        .onAppear(perform: loadKey)
        .sheet(isPresented: $showingEditor) {
            ModeEditorView(
                mode: editingMode,
                onSave: saveMode
            )
        }
    }

    // MARK: - API key

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude API-key")
                .font(ThemeFont.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Je sleutel wordt veilig in de Sleutelhanger bewaard en verlaat je Mac niet, behalve voor aanvragen aan Claude.")
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                SecureField("sk-ant-…", text: $apiKey)
                    .textFieldStyle(.plain)
                    .font(ThemeFont.ui(12).monospaced())
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.surfaceHover)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))

                Button("Bewaar") { saveKey() }
                    .buttonStyle(AccentButtonStyle())
            }

            HStack(spacing: 10) {
                Button("Test verbinding") { testConnection() }
                    .buttonStyle(.plain)
                    .font(ThemeFont.ui(12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))
                    .disabled(testState == .testing || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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

    // MARK: - Modes editor

    private var modesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Modi")
                    .font(ThemeFont.ui(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button {
                    editingMode = nil
                    showingEditor = true
                } label: {
                    Label("Nieuwe modus", systemImage: "plus")
                }
                .buttonStyle(AccentButtonStyle())
            }
            Text("Ingebouwde modi zijn alleen-lezen; dupliceer er een om hem aan te passen.")
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Grouped by category, one card per category.
            ForEach(AIMode.grouped(modes.allModes), id: \.category) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Label(group.category.rawValue, systemImage: group.category.icon)
                        .font(ThemeFont.ui(11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)

                    VStack(spacing: 0) {
                        ForEach(Array(group.modes.enumerated()), id: \.element.id) { index, mode in
                            modeRow(mode)
                            if index < group.modes.count - 1 {
                                Divider().overlay(Theme.border)
                            }
                        }
                    }
                    .themeCard()
                }
            }
        }
    }

    private func modeRow(_ mode: AIMode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: mode.icon)
                .foregroundStyle(Theme.accentText)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(mode.name)
                        .font(ThemeFont.ui(13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    if mode.isBuiltin {
                        Text("Ingebouwd")
                            .font(ThemeFont.ui(9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.surfaceHover)
                            .clipShape(Capsule())
                    }
                }
                Text(mode.systemPrompt)
                    .font(ThemeFont.ui(10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            Button {
                try? modes.duplicate(mode)
            } label: {
                Image(systemName: "plus.square.on.square").foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Dupliceer")

            if !mode.isBuiltin {
                Button {
                    editingMode = mode
                    showingEditor = true
                } label: {
                    Image(systemName: "pencil").foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Bewerk")

                Button(role: .destructive) {
                    try? modes.deleteMode(id: mode.id)
                } label: {
                    Image(systemName: "trash").foregroundStyle(Theme.danger)
                }
                .buttonStyle(.plain)
                .help("Verwijder")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func loadKey() {
        guard !keyLoaded else { return }
        apiKey = (try? KeychainStore.read()) ?? ""
        keyLoaded = true
    }

    private func saveKey() {
        do {
            try KeychainStore.save(apiKey)
            testState = .idle
        } catch {
            testState = .failure("Kon de sleutel niet bewaren.")
        }
    }

    private func testConnection() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        // Persist first so a successful test reflects what will actually be used.
        try? KeychainStore.save(key)
        testState = .testing
        Task {
            let client = ClaudeClient(apiKey: key)
            do {
                _ = try await client.completeText(system: "Antwoord met OK.", user: "OK")
                testState = .success
            } catch let error as ClaudeError {
                testState = .failure(error.localizedDescription)
            } catch {
                testState = .failure(ClaudeError.server(error.localizedDescription).localizedDescription)
            }
        }
    }

    private func saveMode(name: String, prompt: String, icon: String) {
        if let editing = editingMode {
            var updated = editing
            updated.name = name
            updated.systemPrompt = prompt
            updated.icon = icon
            try? modes.updateMode(updated)
        } else {
            try? modes.addMode(name: name, systemPrompt: prompt, icon: icon)
        }
        showingEditor = false
    }
}

/// A modal sheet for creating or editing a custom mode.
private struct ModeEditorView: View {
    let mode: AIMode?
    var onSave: (_ name: String, _ prompt: String, _ icon: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var prompt = ""
    @State private var icon = "sparkles"

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(mode == nil ? "Nieuwe modus" : "Modus bewerken")
                .font(ThemeFont.ui(16, weight: .bold))
                .foregroundStyle(Theme.text)

            VStack(alignment: .leading, spacing: 6) {
                Text("Naam").font(ThemeFont.ui(11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                TextField("Bijv. Blogpost", text: $name)
                    .textFieldStyle(.plain)
                    .font(ThemeFont.ui(13))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Theme.surfaceHover)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Icoon").font(ThemeFont.ui(11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                iconPicker
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Systeemprompt").font(ThemeFont.ui(11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                TextEditor(text: $prompt)
                    .font(ThemeFont.ui(12))
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 120)
                    .background(Theme.surfaceHover)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))
            }

            HStack {
                Spacer()
                Button("Annuleer") { dismiss() }
                    .buttonStyle(.plain)
                    .font(ThemeFont.ui(13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Button("Bewaar") {
                    onSave(name, prompt, icon)
                    dismiss()
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Theme.window)
        .preferredColorScheme(.dark)
        .onAppear {
            if let mode {
                name = mode.name
                prompt = mode.systemPrompt
                icon = mode.icon
            }
        }
    }

    private var iconPicker: some View {
        FlowLayout(spacing: 8) {
            ForEach(AIMode.iconChoices, id: \.self) { choice in
                Button {
                    icon = choice
                } label: {
                    Image(systemName: choice)
                        .font(.system(size: 14))
                        .foregroundStyle(icon == choice ? Theme.onAccent : Theme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(icon == choice ? Theme.accent : Theme.surfaceHover)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
