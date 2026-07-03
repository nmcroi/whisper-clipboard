import AppKit
import Core
import SwiftUI

/// The "AI" section shown below a transcript's body: a row of mode chips that
/// run a Claude prompt mode on the transcript, live-streaming result cards with
/// copy / rerun / delete. Previously stored results load with the transcript.
///
/// When no API key is set, a compact setup card is shown instead of the chips.
struct TranscriptAISection: View {
    let entry: TranscriptEntry
    @Bindable var modes: ModesService
    /// Opens the Settings window (to the AI tab) so the user can add a key.
    var onOpenSettings: () -> Void

    /// The free-form one-off prompt the user is typing.
    @State private var promptDraft = ""
    /// Confirmation feedback after saving a one-off prompt as a mode.
    @State private var savedAsModeName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if modes.hasAPIKey {
                chipRow
                freePromptField
                // Live, in-progress runs for this transcript.
                ForEach(activeRuns) { run in
                    AIRunCard(run: run)
                }
                // Previously stored results (newest first).
                ForEach(storedResults, id: \.id) { result in
                    AIResultCard(
                        result: result,
                        onDelete: { modes.deleteResult(id: result.id) },
                        onRerun: { rerun(result) }
                    )
                }
                if activeRuns.isEmpty && storedResults.isEmpty {
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
                .foregroundStyle(Theme.accent)
            (
                Text("AI")
                    .foregroundStyle(Theme.text)
                + Text(".")
                    .foregroundStyle(Theme.accent)
            )
            .font(ThemeFont.ui(15, weight: .semibold))
            Spacer(minLength: 0)
        }
    }

    private var chipRow: some View {
        // Mode chips grouped by category, each category on its own labelled row.
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AIMode.grouped(modes.allModes), id: \.category) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.category.rawValue.uppercased())
                        .font(ThemeFont.ui(9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    FlowLayout(spacing: 8) {
                        ForEach(group.modes) { mode in
                            chip(for: mode)
                        }
                    }
                }
            }
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
            .font(ThemeFont.ui(12, weight: .medium))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.accent)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(mode.name)
    }

    // MARK: - Free-form prompt

    private var trimmedPrompt: String {
        promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var freePromptField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                TextField(
                    "Vraag iets over deze transcriptie… bv. 'maak een verslag voor de huisarts' of 'haal alle afspraken met datums eruit'",
                    text: $promptDraft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(ThemeFont.ui(12))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.surfaceHover)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))
                .onSubmit(runFreePrompt)

                Button(action: runFreePrompt) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 32, height: 32)
                        .background(trimmedPrompt.isEmpty ? Theme.accentSoft : Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                }
                .buttonStyle(.plain)
                .disabled(trimmedPrompt.isEmpty)
                .help("Voer deze opdracht uit")
            }

            if !trimmedPrompt.isEmpty {
                Button {
                    saveDraftAsMode()
                } label: {
                    Label("Bewaar als modus", systemImage: "bookmark")
                        .font(ThemeFont.ui(11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Bewaar deze opdracht als een herbruikbare modus")
            } else if let name = savedAsModeName {
                Label("Bewaard als \"\(name)\" — te vinden bij Instellingen", systemImage: "checkmark.circle.fill")
                    .font(ThemeFont.ui(11))
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private func runFreePrompt() {
        let instruction = trimmedPrompt
        guard !instruction.isEmpty else { return }
        modes.run(instruction: instruction, on: entry)
        promptDraft = ""
        savedAsModeName = nil
    }

    private func saveDraftAsMode() {
        let instruction = trimmedPrompt
        guard !instruction.isEmpty else { return }
        let name = ModesService.freePromptLabel(for: instruction)
            .replacingOccurrences(of: "Eigen prompt: ", with: "")
        let systemPrompt = ModesService.freeInstructionSystemPrompt(instruction)
        if let mode = try? modes.addMode(name: name, systemPrompt: systemPrompt, icon: "sparkles") {
            savedAsModeName = mode.name
            promptDraft = ""
        }
    }

    private var emptyHint: some View {
        Text("Kies een modus hierboven of typ een eigen opdracht om deze transcriptie door Claude te laten verwerken.")
            .font(ThemeFont.ui(12))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var setupCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.horizontal")
                .foregroundStyle(Theme.accent)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 3) {
                Text("Stel je Claude API-key in")
                    .font(ThemeFont.ui(13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Voeg je Claude API-sleutel toe om transcripties met AI te verwerken.")
                    .font(ThemeFont.ui(11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Instellingen…") { onOpenSettings() }
                .buttonStyle(AccentButtonStyle())
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard(border: Theme.accent.opacity(0.4))
    }

    // MARK: - Data

    private var activeRuns: [AIRun] {
        modes.activeRuns.filter { $0.transcriptId == entry.id }
    }

    private var storedResults: [AIResult] {
        _ = modes.activeRuns.count // re-evaluate when a run finishes and is removed
        return modes.results(for: entry.id)
    }

    private func rerun(_ result: AIResult) {
        // Find the mode by id; fall back to a synthetic mode carrying the stored
        // name (so a deleted custom mode can still be rerun using its name).
        let mode = modes.allModes.first { $0.id == result.modeId }
            ?? AIMode(id: result.modeId, name: result.modeName, systemPrompt: "", icon: "sparkles")
        // If the mode no longer exists we can't reconstruct its prompt; only
        // rerun known modes.
        if modes.allModes.contains(where: { $0.id == result.modeId }) {
            modes.run(mode: mode, on: entry)
        }
    }
}

// MARK: - Result cards

/// A card rendering a live, streaming run.
private struct AIRunCard: View {
    @Bindable var run: AIRun

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: run.mode.icon).font(.system(size: 11))
                Text(run.mode.name)
                    .font(ThemeFont.ui(12, weight: .semibold))
                Spacer(minLength: 0)
                if run.isRunning {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                }
            }
            .foregroundStyle(Theme.textSecondary)

            if let error = run.errorMessage {
                errorRow(error)
            } else if run.output.isEmpty && run.isRunning {
                Text("Claude denkt na…")
                    .font(ThemeFont.ui(12))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Text(run.output)
                    .font(ThemeFont.ui(13))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }

    private func errorRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
                .font(.system(size: 12))
            Text(text)
                .font(ThemeFont.ui(12))
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A card rendering a stored (completed) result, with copy / rerun / delete.
private struct AIResultCard: View {
    let result: AIResult
    var onDelete: () -> Void
    var onRerun: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(result.modeName)
                    .font(ThemeFont.ui(12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                Button {
                    Clipboard.copy(result.output)
                    flashCopied()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? Theme.accent : Theme.textSecondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help(copied ? "Gekopieerd" : "Kopieer")

                Button { onRerun() } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(Theme.textSecondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Opnieuw uitvoeren")

                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(Theme.danger)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Verwijder resultaat")
            }

            Text(result.output)
                .font(ThemeFont.ui(13))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }

    private func flashCopied() {
        copied = true
        Task {
            try? await Task.sleep(for: .milliseconds(1400))
            copied = false
        }
    }
}

// MARK: - Simple wrapping layout

/// A minimal flow layout that wraps its subviews onto multiple rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows = layout(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        rows.removeAll()
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = layout(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = subviews[item].sizeThatFits(.unspecified)
                subviews[item].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = (current.items.isEmpty ? 0 : spacing) + size.width
            if x + needed > maxWidth, !current.items.isEmpty {
                rows.append(current)
                current = Row()
                x = 0
            }
            let lead = current.items.isEmpty ? 0 : spacing
            current.items.append(index)
            x += lead + size.width
            current.width = x
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
