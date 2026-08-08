import Core
import Foundation
import SwiftUI
import WhisperShared

/// Mac-overzicht van de door iPhone en iCloud gedeelde notities.
struct NotesListView: View {
    @ObservedObject var store: HistoryStore

    @State private var selectedID: String?
    @State private var renamingID: String?
    @State private var renameText = ""

    /// De notities, één keer opgehaald per wijziging.
    ///
    /// Bevinding 2026-08-04: `notes` was een computed property die bij elke
    /// body-pass de database bevroeg — en hij werd per pass vier keer gelezen
    /// (kop, telling, lijst, lege staat).
    @State private var notes: [Note] = []

    /// Previewtekst per notitie-id.
    ///
    /// Bevinding 2026-08-04: `previewText(_:)` deed per ZICHTBARE RIJ een eigen
    /// `noteEntries`-query, bij elke body-pass opnieuw. Nu wordt de tekst één
    /// keer per verversing opgebouwd.
    @State private var previews: [String: String] = [:]

    /// De opnames van de geselecteerde notitie; vervangt de query die in het
    /// detailpaneel bij elke body-pass draaide (bevinding 2026-08-04).
    @State private var selectedEntries: [TranscriptEntry] = []

    /// Of de eerste query al gedraaid heeft; voorkomt dat de lege staat
    /// ("Nog geen notities") één frame flitst. Bevinding 2026-08-04.
    @State private var hasLoaded = false

    /// Melding van een mislukte schrijfactie naar de store. Bevinding
    /// 2026-08-03: het hernoemen liep via `try?`, dus een mislukte opslag was
    /// onzichtbaar en de titel leek gewoon aangepast.
    @State private var dataError: String?

    var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
            detailPane
                .frame(minWidth: 400, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
        .dataChangeAlert($dataError)
        .onAppear {
            refreshNotes()
            if selectedID == nil { selectedID = notes.first?.id }
            refreshSelectedEntries()
        }
        .onChange(of: selectedID) { _, _ in refreshSelectedEntries() }
        // `revision` bumpt na élke mutatie van de store — hernoemen hier, en
        // alles wat via iCloud of de iPhone binnenkomt.
        .onChange(of: store.revision) { _, _ in
            refreshNotes()
            if let selectedID, !notes.contains(where: { $0.id == selectedID }) {
                self.selectedID = notes.first?.id
            } else if selectedID == nil {
                selectedID = notes.first?.id
            }
            refreshSelectedEntries()
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notities")
                    .font(ThemeFont.ui(20, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("\(notes.count)")
                    .font(ThemeFont.ui(12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(16)

            Divider().overlay(Theme.border)

            if !hasLoaded {
                Color.clear
            } else if notes.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(notes) { note in
                            noteRow(note)
                            Divider().overlay(Theme.border)
                        }
                    }
                }
            }
        }
        .background(Theme.window)
    }

    @ViewBuilder
    private func noteRow(_ note: Note) -> some View {
        if renamingID == note.id {
            HStack(spacing: 8) {
                TextField("Titel", text: $renameText)
                    .textFieldStyle(.plain)
                    .onSubmit { commitRename(note) }
                Button("Bewaar") { commitRename(note) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accentText)
                Button("Annuleer") { renamingID = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
            }
            .font(ThemeFont.ui(12))
            .padding(14)
            .background(Theme.surfaceHover)
        } else {
            Button {
                selectedID = note.id
                // Meteen laden, zodat het detailpaneel niet één frame de opnames
                // van de vórige notitie toont (bevinding 2026-08-04).
                refreshSelectedEntries()
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "note.text")
                        .foregroundStyle(Theme.accentText)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayTitle(note))
                            .font(ThemeFont.ui(14, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        let preview = previewText(note.id)
                        if !preview.isEmpty {
                            Text(preview)
                                .font(ThemeFont.ui(12))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)
                        }
                        Text(modifiedLabel(note))
                            .font(ThemeFont.ui(11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selectedID == note.id ? Theme.surfaceHover : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Kopieer") { Clipboard.copy(fullText(note.id)) }
                Button("Hernoem") {
                    renameText = note.title
                    renamingID = note.id
                }
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let note = selectedNote {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(displayTitle(note))
                            .font(ThemeFont.ui(26, weight: .bold))
                            .foregroundStyle(Theme.text)
                        Spacer()
                        Button {
                            Clipboard.copy(fullText(note.id))
                        } label: {
                            Label("Kopieer", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                    }

                    Text(modifiedLabel(note))
                        .font(ThemeFont.ui(12))
                        .foregroundStyle(Theme.textSecondary)

                    Divider().overlay(Theme.border)

                    let entries = selectedEntries
                    if entries.isEmpty {
                        Text("Deze notitie bevat nog geen opname.")
                            .font(ThemeFont.ui(14))
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(entries, id: \.id) { entry in
                            Text(entry.text.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(ThemeFont.ui(16))
                                .foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.window)
        } else {
            emptyDetail
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "note.text")
                .font(.system(size: 28))
                .foregroundStyle(Theme.textTertiary)
            Text("Nog geen notities")
                .font(ThemeFont.ui(14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("Maak een notitie op je iPhone; hij verschijnt hier via iCloud.")
                .font(ThemeFont.ui(12))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var emptyDetail: some View {
        VStack(spacing: 10) {
            Image(systemName: "note.text")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textTertiary)
            Text("Selecteer een notitie")
                .font(ThemeFont.ui(14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
    }

    /// Haalt de notities op en bouwt meteen de previewteksten. Zelfde volgorde
    /// en dezelfde tekst als voorheen (bevinding 2026-08-04).
    private func refreshNotes() {
        let fetched = (try? store.notes()) ?? []
        notes = fetched
        previews = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, fullText($0.id)) })
        hasLoaded = true
    }

    /// Haalt de opnames van de geselecteerde notitie op.
    private func refreshSelectedEntries() {
        selectedEntries = selectedID.map { noteEntries($0) } ?? []
    }

    /// Bevinding 2026-08-04: dit deed een eigen `note(id:)`-query per body-pass.
    /// `notes()` levert álle notities, dus opzoeken in de cache geeft hetzelfde
    /// resultaat.
    private var selectedNote: Note? {
        guard let selectedID else { return nil }
        return notes.first { $0.id == selectedID }
    }

    private func noteEntries(_ id: String) -> [TranscriptEntry] {
        (try? store.noteEntries(noteId: id)) ?? []
    }

    private func previewText(_ id: String) -> String {
        previews[id] ?? ""
    }

    private func fullText(_ id: String) -> String {
        noteEntries(id)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func displayTitle(_ note: Note) -> String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Naamloze notitie" : title
    }

    private func modifiedLabel(_ note: Note) -> String {
        guard let date = note.modifiedDate else { return "Gewijzigd" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "nl_NL")
        formatter.unitsStyle = .full
        return "Gewijzigd " + formatter.localizedString(for: date, relativeTo: Date())
    }

    private func commitRename(_ note: Note) {
        // Bevinding 2026-08-03: het naamveld klapte dicht alsof de titel bewaard
        // was. Blijf bij een fout in bewerkmodus zodat de ingetypte titel blijft.
        let saved = DataChange.perform(
            "Het hernoemen van de notitie",
            reporting: $dataError
        ) {
            try store.renameNote(id: note.id, title: renameText)
        }
        guard saved else { return }
        renamingID = nil
    }
}
