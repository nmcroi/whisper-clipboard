import Core
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WhisperShared

/// Native iOS AI-sectie: een horizontaal scrollbare rij modus-chips, een
/// vrije-prompt-veld en live-streamende resultaatkaarten met kopieerknop.
/// Gedeeld door het transcript-detailscherm (persisteert resultaten) en de
/// notitie-samenvat-sheet (draait op de samengevoegde tekst).
///
/// - `entry`: het transcript (of synthetische notitie-entry) waarop gedraaid wordt.
/// - `modes`: de gedeelde ``ModesService`` uit ``AppModel``.
/// - `showStoredResults`: toon eerder bewaarde resultaten voor deze `entry`
///   (aan voor echte transcripties; uit voor notitie-runs die niet persisteren).
/// - `onOpenSettings`: opent de instellingen zodat de gebruiker een key kan zetten.
struct AIRunnerView: View {
    @EnvironmentObject private var app: AppModel
    let entry: TranscriptEntry
    @Bindable var modes: ModesService
    var showStoredResults: Bool = true
    var onAddToNote: (() -> Void)? = nil
    var onOpenSettings: () -> Void

    @State private var promptDraft = ""
    @State private var showGenerator = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if modes.hasAPIKey {
                generatorButton
                freePromptField
                ForEach(activeRuns) { run in
                    AIRunCardiOS(run: run, onCancel: { modes.cancel(run) })
                }
                if showStoredResults {
                    ForEach(storedResults, id: \.id) { result in
                        AIResultCardiOS(
                            result: result,
                            canRerun: canRerun(result),
                            onAddToNote: onAddToNote,
                            onDelete: { modes.deleteResult(id: result.id) },
                            onRerun: { rerun(result) }
                        )
                    }
                }
                if activeRuns.isEmpty && (!showStoredResults || storedResults.isEmpty) {
                    emptyHint
                }
            } else {
                setupCard
            }
        }
        .sheet(isPresented: $showGenerator) {
            generationSheet
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.accentText)
                Text("AI")
                    .font(ThemeFont.ui(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            Text(String(
                format: L10n.string( "%1$@ · %2$@ · alleen deze tekst, nooit audio", locale: app.interfaceLanguage.locale),
                locale: app.interfaceLanguage.locale,
                modes.currentProvider.displayName,
                modes.currentModel
            ))
                .font(ThemeFont.ui(12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var generatorButton: some View {
        Button { showGenerator = true } label: {
            HStack {
                Label("Nieuwe genereren", systemImage: "sparkles.rectangle.stack")
                Spacer()
                Image(systemName: "chevron.right")
            }
            .font(ThemeFont.ui(15, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var generationSheet: some View {
        NavigationStack {
            List(generationModes) { mode in
                Button {
                    modes.run(mode: mode, on: entry)
                    showGenerator = false
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: mode.icon)
                            .foregroundStyle(Theme.accentText)
                            .frame(width: 26)
                        Text(AIModeLocalization.name(for: mode, language: app.interfaceLanguage))
                            .font(ThemeFont.ui(17, weight: .medium))
                            .foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: "plus.circle")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 7)
                }
                .listRowBackground(Theme.window)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.window)
            .navigationTitle("Nieuwe genereren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Gereed") { showGenerator = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// E-mail is een uitvoerroute, geen AI-opdracht. Oude e-mailresultaten
    /// blijven bewaard, maar nieuwe maak je via 'Verstuur' bij een resultaat.
    private var generationModes: [AIMode] {
        modes.allModes.filter {
            $0.name.localizedCaseInsensitiveCompare("E-mail") != .orderedSame
        } + [Self.dictionarySuggestionsMode]
    }

    private static let dictionarySuggestionsMode = AIMode(
        id: "builtin.woordenlijst_suggesties",
        name: "Woordenlijstsuggesties",
        systemPrompt: """
        Analyseer dit ruwe transcript op terugkerende spraakherkenningsfouten die geschikt zijn voor een persoonlijke woordenlijst. Geef alleen voorstellen waarvan de bedoelde correcte schrijfwijze met hoge zekerheid uit de context blijkt, vooral eigennamen, productnamen, organisaties, afkortingen en vaktermen. Stel geen gewone grammaticale of stilistische verbeteringen voor. De linker tekst moet een volledig woord of een volledige woordgroep uit het transcript zijn; nooit een deel van een woord. Geef maximaal 10 voorstellen. Antwoord uitsluitend als geldige JSON-array, zonder markdown of uitleg, in deze vorm: [{"find":"verkeerd verstaan","replace":"juiste schrijfwijze","reason":"korte reden"}]. Geef [] als er geen betrouwbare voorstellen zijn.
        """,
        icon: "character.book.closed",
        category: .opschonen,
        isBuiltin: true
    )

    // MARK: - Free-form prompt

    private var trimmedPrompt: String {
        promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var freePromptField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                "Vraag iets… bv. 'haal alle afspraken eruit'",
                text: $promptDraft,
                axis: .vertical
            )
            .lineLimit(1...4)
            .font(ThemeFont.ui(15))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.surfaceHover)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .submitLabel(.send)
            .onSubmit(runFreePrompt)

            Button(action: runFreePrompt) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 44, height: 44)
                    .background(trimmedPrompt.isEmpty ? Theme.accentSoft : Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(trimmedPrompt.isEmpty)
            .accessibilityLabel("Verstuur AI-opdracht")
        }
    }

    private func runFreePrompt() {
        let instruction = trimmedPrompt
        guard !instruction.isEmpty else { return }
        modes.run(instruction: instruction, on: entry)
        promptDraft = ""
    }

    private var emptyHint: some View {
        Text(String(
            format: L10n.string( "Kies een modus of typ een eigen opdracht om deze tekst door %@ te laten verwerken.", locale: app.interfaceLanguage.locale),
            locale: app.interfaceLanguage.locale,
            modes.currentProvider.displayName
        ))
            .font(ThemeFont.ui(13))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var setupCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.horizontal")
                .foregroundStyle(Theme.accentText)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 3) {
                Text(String(
                    format: L10n.string( "Stel je API-key voor %@ in", locale: app.interfaceLanguage.locale),
                    locale: app.interfaceLanguage.locale,
                    modes.currentProvider.displayName
                ))
                    .font(ThemeFont.ui(14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Voeg de sleutel toe bij Instellingen om gekozen transcripttekst met AI te verwerken.")
                    .font(ThemeFont.ui(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Instellingen") { onOpenSettings() }
                .font(ThemeFont.ui(13, weight: .semibold))
                .foregroundStyle(Theme.accentText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Data

    private var activeRuns: [AIRun] {
        modes.activeRuns.filter { $0.transcriptId == entry.id }
    }

    private var storedResults: [AIResult] {
        _ = modes.activeRuns.count // her-evalueer zodra een run klaar is en verdwijnt
        return modes.results(for: entry.id)
            .filter { $0.modeName.localizedCaseInsensitiveCompare("E-mail") != .orderedSame }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func canRerun(_ result: AIResult) -> Bool {
        guard result.modeId != ModesService.freePromptModeId else { return false }
        return modes.allModes.contains { $0.id == result.modeId }
    }

    private func rerun(_ result: AIResult) {
        guard canRerun(result),
              let mode = modes.allModes.first(where: { $0.id == result.modeId }) else { return }
        modes.run(mode: mode, on: entry)
    }
}

// MARK: - Live run card

/// Een kaart voor een live, streamende run.
private struct AIRunCardiOS: View {
    @EnvironmentObject private var app: AppModel
    @Bindable var run: AIRun
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: run.mode.icon)
                .foregroundStyle(run.errorMessage == nil ? Theme.accentText : Theme.danger)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(AIModeLocalization.name(for: run.mode, language: app.interfaceLanguage))
                    .font(ThemeFont.ui(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(run.errorMessage.map {
                    ErrorLocalization.message(forStoredMessage: $0, language: app.interfaceLanguage)
                } ?? L10n.string( "Wordt gemaakt…", locale: app.interfaceLanguage.locale))
                    .font(ThemeFont.ui(13))
                    .foregroundStyle(run.errorMessage == nil ? Theme.textSecondary : Theme.danger)
                    .lineLimit(2)
            }
            Spacer()
            if run.isRunning {
                ProgressView().tint(Theme.accent)
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Annuleer AI-opdracht")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

}

// MARK: - Stored result card

/// Een kaart voor een bewaard (afgerond) resultaat, met kopieer / opnieuw / verwijder.
private struct AIResultCardiOS: View {
    @EnvironmentObject private var app: AppModel
    let result: AIResult
    var canRerun: Bool = true
    var onAddToNote: (() -> Void)?
    var onDelete: () -> Void
    var onRerun: () -> Void

    var body: some View {
        NavigationLink {
            AIResultDetailView(
                result: result,
                canRerun: canRerun,
                onAddToNote: onAddToNote,
                onDelete: onDelete,
                onRerun: onRerun
            )
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Theme.accentText)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                Text(AIModeLocalization.name(
                    id: result.modeId,
                    fallback: result.modeName,
                    language: app.interfaceLanguage
                ))
                        .font(ThemeFont.ui(15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    Text(result.output.replacingOccurrences(of: "\n", with: " "))
                        .font(ThemeFont.ui(13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct AIResultDetailView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let result: AIResult
    let canRerun: Bool
    var onAddToNote: (() -> Void)?
    var onDelete: () -> Void
    var onRerun: () -> Void

    @State private var exportingMarkdown = false
    @State private var copied = false

    var body: some View {
        ZStack {
            Theme.window.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        ShareLink(item: result.output) {
                            Label("Verstuur", systemImage: "paperplane")
                                .font(ThemeFont.ui(14, weight: .semibold))
                                .foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Theme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                        }
                        resultActionsMenu
                        Spacer()
                    }

                    Divider().overlay(Theme.border)

                    if result.modeId == "builtin.woordenlijst_suggesties" {
                        DictionarySuggestionsResultView(output: result.output)
                    } else {
                        Text(result.output)
                            .font(ThemeFont.ui(17))
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle(AIModeLocalization.name(
            id: result.modeId,
            fallback: result.modeName,
            language: app.interfaceLanguage
        ))
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $exportingMarkdown,
            document: MarkdownDocument(text: result.output),
            contentType: .plainText,
            defaultFilename: safeFilename
        ) { _ in }
    }

    private var resultActionsMenu: some View {
        Menu {
            if let onAddToNote {
                Button(action: onAddToNote) {
                    Label("Koppel aan notitie", systemImage: "note.text.badge.plus")
                }
            }
            Button {
                UIPasteboard.general.string = result.output
                copied = true
            } label: {
                Label(
                    copied
                        ? L10n.string( "Gekopieerd", locale: app.interfaceLanguage.locale)
                        : L10n.string( "Kopieer", locale: app.interfaceLanguage.locale),
                    systemImage: "doc.on.doc"
                )
            }
            Button { exportingMarkdown = true } label: {
                Label("Exporteer als Markdown", systemImage: "doc.badge.arrow.up")
            }
            if canRerun {
                Button {
                    onRerun()
                    dismiss()
                } label: {
                    Label("Opnieuw uitvoeren", systemImage: "arrow.clockwise")
                }
            }
            Divider()
            Button(role: .destructive) {
                onDelete()
                dismiss()
            } label: {
                Label("Verwijder", systemImage: "trash")
            }
        } label: {
            Label("Meer", systemImage: "ellipsis.circle")
                .font(ThemeFont.ui(14, weight: .semibold))
                .foregroundStyle(Theme.accentText)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )
        }
    }

    private var safeFilename: String {
        let cleaned = result.modeName.replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty ? "WhisperClip.md" : "\(cleaned).md"
    }
}

private struct DictionarySuggestion: Codable, Identifiable {
    let find: String
    let replace: String
    let reason: String
    var id: String { "\(find.lowercased())→\(replace.lowercased())" }
}

private struct DictionarySuggestionsResultView: View {
    @EnvironmentObject private var app: AppModel
    let output: String

    private var suggestions: [DictionarySuggestion] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutFence = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = withoutFence.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([DictionarySuggestion].self, from: data)) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if suggestions.isEmpty {
                Text("De AI-aanbieder vond geen betrouwbare woordenlijstsuggesties in deze transcriptie.")
                    .font(ThemeFont.ui(15))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text("Controleer elk voorstel. Alleen wat jij toevoegt komt in de woordenlijst.")
                    .font(ThemeFont.ui(14))
                    .foregroundStyle(Theme.textSecondary)

                ForEach(suggestions) { suggestion in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(suggestion.find)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(Theme.textTertiary)
                            Text(suggestion.replace)
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .font(ThemeFont.ui(16))
                        Text(suggestion.reason)
                            .font(ThemeFont.ui(13))
                            .foregroundStyle(Theme.textSecondary)
                        Button(isAdded(suggestion)
                               ? L10n.string( "Toegevoegd", locale: app.interfaceLanguage.locale)
                               : L10n.string( "Voeg toe aan woordenlijst", locale: app.interfaceLanguage.locale)) {
                            add(suggestion)
                        }
                        .font(ThemeFont.ui(14, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Theme.accent.opacity(isAdded(suggestion) ? 0.55 : 1))
                        .clipShape(Capsule())
                        .buttonStyle(.plain)
                        .disabled(isAdded(suggestion))
                    }
                    .padding(14)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
                }
            }
        }
    }

    private func isAdded(_ suggestion: DictionarySuggestion) -> Bool {
        app.replacements.contains {
            $0.find.localizedCaseInsensitiveCompare(suggestion.find) == .orderedSame
        }
    }

    private func add(_ suggestion: DictionarySuggestion) {
        guard !isAdded(suggestion),
              !suggestion.find.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !suggestion.replace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        app.replacements.append(Replacement(find: suggestion.find, replace: suggestion.replace))
    }
}

private struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
