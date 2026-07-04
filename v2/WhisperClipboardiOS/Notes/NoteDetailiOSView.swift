import Core
import Foundation
import SwiftUI
import UIKit
import WhisperShared

/// De notitie-detailweergave: de volledige, samengevoegde tekst van de notitie
/// (oudste → nieuwste over alle toegevoegde opnames, met een subtiele
/// tijdstempel-scheiding tussen sessies) plus een opnameknop die de bestaande
/// opnamepijplijn hergebruikt (``RecordController``). Bij stop wordt de opname
/// áán deze notitie toegevoegd i.p.v. als losse Geschiedenis-entry.
struct NoteDetailiOSView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = RecordController()

    let note: Note

    /// Eenmalige auto-start: als dit id gelijk is aan `note.id` (gezet door de
    /// +-knop in de lijst) start de opname direct bij openen. Wordt meteen op
    /// `nil` gezet zodat terugnavigeren/heropenen niet opnieuw start.
    @Binding var autoStartNoteId: String?

    init(note: Note, autoStartNoteId: Binding<String?> = .constant(nil)) {
        self.note = note
        self._autoStartNoteId = autoStartNoteId
    }

    @State private var didCopy = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false

    // MARK: Samenvoegen (task 4a)
    /// Toont de picker om deze hele notitie samen te voegen met een andere.
    @State private var showMergeSheet = false

    // MARK: AI-samenvatten (i3)
    /// Toont de AI-sheet die op de samengevoegde notitie-tekst draait.
    @State private var showSummarizeSheet = false

    // MARK: Losse sessie verplaatsen (task 4b)
    /// De entry-id waarvoor de "verplaats naar andere notitie"-picker open is.
    /// Verpakt in een Identifiable wrapper voor `.sheet(item:)`.
    @State private var movingEntry: MovingEntry?

    /// Identifiable wrapper rond een entry-id (TranscriptEntry is niet Identifiable).
    private struct MovingEntry: Identifiable { let id: String }

    // MARK: Toewijzings-sheet (task 2)
    /// Eenmalige vlag: gezet zodra de auto-start-opname (via de +-knop) is
    /// afgevuurd. Alleen dán, en alleen na de éérste afgeronde opname, tonen we de
    /// "Waar hoort dit bij?"-sheet. Blijft daarna false → latere opnames in een al
    /// benoemde notitie vragen nooit opnieuw.
    @State private var awaitingFirstResult = false
    @State private var showAssignSheet = false
    /// Onthoudt of we al eens hebben getranscribeerd, zodat we de flank
    /// (isTranscribing: true → false) betrouwbaar detecteren.
    @State private var wasTranscribing = false

    var body: some View {
        ZStack {
            Theme.window.ignoresSafeArea()
            content
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task {
            // Koppel de controller aan DEZE notitie: opnames worden er áán
            // toegevoegd i.p.v. los opgeslagen.
            controller.attach(app: app, targetNoteId: note.id)
            await app.refreshModelStatus()
            // Via de +-knop binnengekomen? Start dan direct de opname (eenmalig;
            // alleen als het model er is — anders toont de balk de download-hint).
            if autoStartNoteId == note.id {
                autoStartNoteId = nil
                if app.modelStatus.isReady && !controller.isRecording {
                    // Alleen déze (auto-start) flow mag straks de toewijzings-sheet
                    // tonen zodra de eerste opname klaar is.
                    awaitingFirstResult = true
                    renameText = displayTitle
                    controller.toggle()
                }
            }
        }
        // Detecteer de flank isTranscribing: true → false van de auto-start-opname.
        // Als de notitie daarna ≥1 entry heeft (dus geen lege/mislukte opname),
        // tonen we eenmalig de "Waar hoort dit bij?"-sheet.
        .onChange(of: controller.isTranscribing) { _, transcribing in
            if transcribing {
                wasTranscribing = true
            } else if wasTranscribing {
                wasTranscribing = false
                guard awaitingFirstResult else { return }
                awaitingFirstResult = false
                if !fetchEntries().isEmpty {
                    showAssignSheet = true
                }
            }
        }
        .sheet(isPresented: $showAssignSheet) {
            AssignNoteSheet(
                tempNoteId: note.id,
                initialTitle: displayTitle,
                onMovedToOther: {
                    // De opname is naar een bestaande notitie verplaatst en deze
                    // (lege) tijdelijke notitie is verwijderd: sluit dit detail. De
                    // lijst is via de store-revisie al bijgewerkt.
                    showAssignSheet = false
                    dismiss()
                }
            )
            .environmentObject(app)
            .preferredColorScheme(app.appearance.preferredColorScheme)
        }
        // Hele notitie samenvoegen met een andere (task 4a).
        .sheet(isPresented: $showMergeSheet) {
            NotePickerSheet(
                title: "Voeg samen met…",
                header: "Alle opnames verhuizen naar de gekozen notitie",
                excludingNoteId: note.id
            ) { targetNoteId in
                mergeNote(into: targetNoteId)
            }
            .environmentObject(app)
            .preferredColorScheme(app.appearance.preferredColorScheme)
        }
        // AI-samenvatten van de hele notitie (i3).
        .sheet(isPresented: $showSummarizeSheet) {
            if let modes = app.modes {
                NoteSummarizeSheet(
                    entry: summarizeEntry(),
                    modes: modes
                )
                .environmentObject(app)
                .preferredColorScheme(app.appearance.preferredColorScheme)
            }
        }
        // Losse sessie verplaatsen naar een andere notitie (task 4b).
        .sheet(item: $movingEntry) { moving in
            NotePickerSheet(
                title: "Verplaats naar…",
                header: "Deze opname verhuist naar de gekozen notitie",
                excludingNoteId: note.id
            ) { targetNoteId in
                try? app.history?.moveEntryToNote(entryId: moving.id, noteId: targetNoteId)
            }
            .environmentObject(app)
            .preferredColorScheme(app.appearance.preferredColorScheme)
        }
        .alert("Notitie hernoemen", isPresented: $showRename) {
            TextField("Titel", text: $renameText)
            Button("Bewaar") {
                try? app.history?.renameNote(id: note.id, title: renameText)
            }
            Button("Annuleer", role: .cancel) {}
        }
        .confirmationDialog(
            "Notitie verwijderen",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Verwijder, opnames behouden") {
                // Veilige standaard: entries worden losse Geschiedenis-items.
                try? app.history?.deleteNote(id: note.id, deleteEntries: false)
                dismiss()
            }
            Button("Verwijder alles", role: .destructive) {
                try? app.history?.deleteNote(id: note.id, deleteEntries: true)
                dismiss()
            }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text("Wil je de opnames in deze notitie als losse geschiedenis behouden, of alles verwijderen?")
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    let entries = fetchEntries()
                    if entries.isEmpty {
                        emptyBody
                    } else {
                        noteBody(entries)
                        copyButton(entries)
                    }
                }
                .padding(20)
            }
            recordBar
        }
    }

    // MARK: - Body text

    @ViewBuilder
    private func noteBody(_ entries: [TranscriptEntry]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                VStack(alignment: .leading, spacing: 6) {
                    // Subtiele tijdstempel-scheiding tussen sessies — géén harde
                    // contentbreuk die als losse entries zou lezen.
                    if index > 0 {
                        sessionDivider(for: entry)
                    }
                    Text(entry.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(ThemeFont.ui(17))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .contextMenu {
                    // Losse sessie beheren (task 4b): verplaatsen of losmaken.
                    Button {
                        movingEntry = MovingEntry(id: entry.id)
                    } label: {
                        Label("Verplaats naar andere notitie…", systemImage: "arrow.right.doc.on.clipboard")
                    }
                    Button {
                        // Terug naar Geschiedenis als losse opname.
                        try? app.history?.detachEntryFromNote(entryId: entry.id)
                    } label: {
                        Label("Maak losse opname", systemImage: "arrow.uturn.backward")
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    private func sessionDivider(for entry: TranscriptEntry) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Theme.border)
                .frame(height: Theme.Metrics.hairline)
                .frame(maxWidth: 24)
            Text(sessionTime(for: entry))
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textTertiary)
            Rectangle()
                .fill(Theme.border)
                .frame(height: Theme.Metrics.hairline)
        }
        .padding(.vertical, 2)
    }

    private var emptyBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nog niets ingesproken.")
                .font(ThemeFont.ui(16, weight: .medium))
                .foregroundStyle(Theme.text)
            Text("Tik op de knop hieronder om iets aan deze notitie toe te voegen.")
                .font(ThemeFont.ui(14))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 40)
    }

    private func copyButton(_ entries: [TranscriptEntry]) -> some View {
        Button {
            UIPasteboard.general.string = concatenatedText(entries)
            didCopy = true
        } label: {
            Label(didCopy ? "Gekopieerd" : "Kopieer notitie", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                .font(ThemeFont.ui(16, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    // MARK: - Record bar (onderaan)

    @ViewBuilder
    private var recordBar: some View {
        VStack(spacing: 10) {
            if !app.modelStatus.isReady {
                Text("Model nog niet gereed. Download het via het Opnemen-tabblad.")
                    .font(ThemeFont.ui(13))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            } else {
                Text(controller.isRecording
                     ? Self.formatElapsed(controller.elapsed)
                     : (controller.isTranscribing ? "Bezig met transcriberen…" : "Tik om toe te voegen"))
                    .font(ThemeFont.ui(13))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()

                NoteRecordButton(
                    isRecording: controller.isRecording,
                    isBusy: controller.isTranscribing,
                    level: controller.level
                ) {
                    controller.toggle()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.border)
                .frame(height: Theme.Metrics.hairline)
        }
        .animation(.easeInOut(duration: 0.2), value: controller.isRecording)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Tikbare titel met subtiel potlood: tik = hernoemen (ontdekbaarheid,
        // task 3). Het menu rechtsboven houdt "Hernoem" ook als alternatief.
        ToolbarItem(placement: .principal) {
            Button {
                renameText = displayTitle
                showRename = true
            } label: {
                HStack(spacing: 5) {
                    Text(displayTitle)
                        .font(ThemeFont.ui(16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Notitie hernoemen")
        }
        // Links geplaatst (naast de terug-chevron): rechtsboven zweeft het globale
        // instellingen-tandwiel van RootView.
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button {
                    renameText = note.title
                    showRename = true
                } label: {
                    Label("Hernoem", systemImage: "pencil")
                }
                // Hele notitie samenvoegen met een andere (task 4a).
                Button {
                    showMergeSheet = true
                } label: {
                    Label("Voeg samen met andere notitie…", systemImage: "arrow.triangle.merge")
                }
                // AI-samenvatten van de hele notitie (i3): draait op de
                // samengevoegde tekst van alle opnames in deze notitie.
                Button {
                    showSummarizeSheet = true
                } label: {
                    Label("Samenvatten met AI…", systemImage: "sparkles")
                }
                .disabled(app.modes == nil)
                Divider()
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Verwijder notitie", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(Theme.accentText)
            }
        }
    }

    // MARK: - Data helpers

    private func fetchEntries() -> [TranscriptEntry] {
        _ = app.history?.revision
        return (try? app.history?.noteEntries(noteId: note.id)) ?? []
    }

    /// Voegt deze hele notitie samen met een andere (task 4a): verhuist alle
    /// opnames chronologisch naar de doelnotitie, verwijdert dan deze nu lege
    /// notitie (opnames behouden) en sluit het detail terug naar de lijst.
    private func mergeNote(into targetNoteId: String) {
        let entries = fetchEntries() // al oudste → nieuwste
        for entry in entries {
            try? app.history?.moveEntryToNote(entryId: entry.id, noteId: targetNoteId)
        }
        try? app.history?.deleteNote(id: note.id, deleteEntries: false)
        dismiss()
    }

    /// Bouwt een synthetische ``TranscriptEntry`` uit de samengevoegde tekst van
    /// de hele notitie, waarop de AI-sheet draait. De id (`note:<noteId>`) verwijst
    /// bewust niet naar een echt transcript: de FK op `ai_results` weigert daardoor
    /// een insert, zodat notitie-runs niet als los transcript-resultaat blijven
    /// hangen (i3 v1 toont/kopieert het resultaat, maar bewaart het niet).
    private func summarizeEntry() -> TranscriptEntry {
        TranscriptEntry(
            id: "note:\(note.id)",
            text: concatenatedText(fetchEntries()),
            createdAt: "",
            name: displayTitle
        )
    }

    private func concatenatedText(_ entries: [TranscriptEntry]) -> String {
        entries
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private var displayTitle: String {
        // Herlees de titel via de store zodat een hernoeming meteen zichtbaar is.
        _ = app.history?.revision
        let live = (try? app.history?.note(id: note.id))?.title ?? note.title
        let trimmed = live.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Naamloze notitie" : trimmed
    }

    private func sessionTime(for entry: TranscriptEntry) -> String {
        guard let date = entry.timestamp else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "nl_NL")
        formatter.dateFormat = "d MMM HH:mm"
        return formatter.string(from: date)
    }

    private static func formatElapsed(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Compacte opnameknop

/// De hoofdactie van het notitie-detail: dezelfde gele ring-met-vierkante-kern als
/// de Opnemen-knop, iets kleiner dan het Opnemen-tabblad maar duidelijk primair.
/// Poort van `RecordButton` uit RecordView. Rood tijdens opnemen.
private struct NoteRecordButton: View {
    let isRecording: Bool
    let isBusy: Bool
    let level: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(isRecording ? Theme.danger : Theme.accent, lineWidth: 6)
                    .frame(width: 112, height: 112)
                    .scaleEffect(isRecording ? 1 + CGFloat(level) * 0.08 : 1)

                // Verhoudingen als de app-icoon: het afgeronde vierkant is ~42%
                // van de ringdiameter (net als de Opnemen-knop).
                RoundedRectangle(cornerRadius: isRecording ? 7 : 12, style: .continuous)
                    .fill(isRecording ? Theme.danger : Theme.accent)
                    .frame(
                        width: isRecording ? 40 : 48,
                        height: isRecording ? 40 : 48
                    )

                if isBusy {
                    ProgressView()
                        .tint(Theme.onAccent)
                        .scaleEffect(1.2)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isRecording)
    }
}
