import Core
import SwiftUI
import UIKit
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
    let entry: TranscriptEntry
    @Bindable var modes: ModesService
    var showStoredResults: Bool = true
    var onOpenSettings: () -> Void

    @State private var promptDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if modes.hasAPIKey {
                chipRow
                freePromptField
                ForEach(activeRuns) { run in
                    AIRunCardiOS(run: run)
                }
                if showStoredResults {
                    ForEach(storedResults, id: \.id) { result in
                        AIResultCardiOS(
                            result: result,
                            canRerun: canRerun(result),
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
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.accentText)
            Text("AI")
                .font(ThemeFont.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
        }
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(modes.allModes) { mode in
                    chip(for: mode)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(for mode: AIMode) -> some View {
        Button {
            modes.run(mode: mode, on: entry)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.icon).font(.system(size: 11))
                Text(mode.name)
            }
            .font(ThemeFont.ui(13, weight: .medium))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.accent)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

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
                    .frame(width: 40, height: 40)
                    .background(trimmedPrompt.isEmpty ? Theme.accentSoft : Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(trimmedPrompt.isEmpty)
        }
    }

    private func runFreePrompt() {
        let instruction = trimmedPrompt
        guard !instruction.isEmpty else { return }
        modes.run(instruction: instruction, on: entry)
        promptDraft = ""
    }

    private var emptyHint: some View {
        Text("Kies een modus of typ een eigen opdracht om deze tekst door Claude te laten verwerken.")
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
                Text("Stel je Claude API-key in")
                    .font(ThemeFont.ui(14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Voeg je Claude API-sleutel toe bij Instellingen om tekst met AI te verwerken.")
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
    @Bindable var run: AIRun
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: run.mode.icon).font(.system(size: 12))
                Text(run.mode.name)
                    .font(ThemeFont.ui(13, weight: .semibold))
                Spacer(minLength: 0)
                if run.isRunning {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                } else if run.errorMessage == nil && !run.output.isEmpty {
                    copyButton(for: run.output)
                }
            }
            .foregroundStyle(Theme.textSecondary)

            if let error = run.errorMessage {
                errorRow(error)
            } else if run.output.isEmpty && run.isRunning {
                Text("Claude denkt na…")
                    .font(ThemeFont.ui(13))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Text(run.output)
                    .font(ThemeFont.ui(15))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    private func copyButton(for text: String) -> some View {
        Button {
            UIPasteboard.general.string = text
            flashCopied()
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? Theme.accent : Theme.textSecondary)
                .font(.system(size: 13))
        }
        .buttonStyle(.plain)
    }

    private func flashCopied() {
        copied = true
        Task {
            try? await Task.sleep(for: .milliseconds(1400))
            copied = false
        }
    }

    private func errorRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
                .font(.system(size: 13))
            Text(text)
                .font(ThemeFont.ui(13))
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Stored result card

/// Een kaart voor een bewaard (afgerond) resultaat, met kopieer / opnieuw / verwijder.
private struct AIResultCardiOS: View {
    let result: AIResult
    var canRerun: Bool = true
    var onDelete: () -> Void
    var onRerun: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(result.modeName)
                    .font(ThemeFont.ui(13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = result.output
                    flashCopied()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? Theme.accent : Theme.textSecondary)
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)

                if canRerun {
                    Button { onRerun() } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(Theme.textSecondary)
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                }

                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(Theme.danger)
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
            }

            Text(result.output)
                .font(ThemeFont.ui(15))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private func flashCopied() {
        copied = true
        Task {
            try? await Task.sleep(for: .milliseconds(1400))
            copied = false
        }
    }
}
