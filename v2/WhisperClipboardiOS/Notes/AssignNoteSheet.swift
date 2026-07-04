import Core
import Foundation
import SwiftUI
import WhisperShared

/// De "Waar hoort dit bij?"-sheet: verschijnt éénmalig nadat de éérste opname van
/// een vers via de +-knop aangemaakte notitie klaar is. Twee uitkomsten:
///
///  • **Bewaar** — hernoemt de tijdelijke notitie naar de getypte titel; de
///    gebruiker blijft in de (nu benoemde) notitie.
///  • **Voeg toe aan een bestaande notitie** — verplaatst de zojuist opgenomen
///    entry naar de gekozen notitie (``moveEntryToNote``), verwijdert de nu lege
///    tijdelijke notitie, en sluit het detail (``onMovedToOther``).
///
/// Wegvegen = titel behouden (gebruiker kan later hernoemen).
struct AssignNoteSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    /// De zojuist aangemaakte, tijdelijke notitie (bevat nu de eerste opname).
    let tempNoteId: String
    /// Voorgevulde titel (de auto-titel) voor het naamveld.
    let initialTitle: String
    /// Aangeroepen nadat de opname naar een ándere notitie is verplaatst en deze
    /// tijdelijke notitie is verwijderd — zodat het detail zich kan sluiten.
    var onMovedToOther: (() -> Void)?

    @State private var titleText: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.window.ignoresSafeArea()
                listBody
            }
            .navigationTitle("Waar hoort dit bij?")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            let trimmed = initialTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            titleText = (trimmed == "Naamloze notitie") ? "" : trimmed
        }
    }

    @ViewBuilder
    private var listBody: some View {
        List {
            Section {
                TextField("Bijv. Vakantie", text: $titleText)
                    .font(ThemeFont.ui(17))
                    .foregroundStyle(Theme.text)
                    .submitLabel(.done)
                    .onSubmit(saveName)
                    .listRowBackground(Theme.surfaceHover)

                Button(action: saveName) {
                    Text("Bewaar")
                        .font(ThemeFont.ui(16, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .listRowBackground(Theme.window)
            } header: {
                Text("Geef deze notitie een naam")
                    .font(ThemeFont.ui(13))
                    .foregroundStyle(Theme.textSecondary)
            }

            let others = otherNotes()
            if !others.isEmpty {
                Section {
                    ForEach(others, id: \.id) { note in
                        Button {
                            move(to: note.id)
                        } label: {
                            HStack {
                                Image(systemName: "note.text")
                                    .foregroundStyle(Theme.accentText)
                                Text(title(for: note))
                                    .font(ThemeFont.ui(16))
                                    .foregroundStyle(Theme.text)
                            }
                        }
                        .listRowBackground(Theme.window)
                        .listRowSeparatorTint(Theme.border)
                    }
                } header: {
                    Text("Of voeg toe aan een bestaande notitie")
                        .font(ThemeFont.ui(13))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Data

    /// Alle bestaande notities behalve de tijdelijke zelf.
    private func otherNotes() -> [Note] {
        let notes = (try? app.history?.notes()) ?? []
        return notes.filter { $0.id != tempNoteId }
    }

    private func title(for note: Note) -> String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Naamloze notitie" : trimmed
    }

    // MARK: - Uitkomsten

    /// Hernoemt de tijdelijke notitie en sluit de sheet; de gebruiker blijft in de
    /// nu benoemde notitie.
    private func saveName() {
        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? app.history?.renameNote(id: tempNoteId, title: trimmed)
        dismiss()
    }

    /// Verplaatst de zojuist opgenomen entry naar de gekozen notitie, verwijdert de
    /// nu lege tijdelijke notitie, sluit de sheet en laat het detail zich sluiten.
    private func move(to targetNoteId: String) {
        let entries = (try? app.history?.noteEntries(noteId: tempNoteId)) ?? []
        for entry in entries {
            try? app.history?.moveEntryToNote(entryId: entry.id, noteId: targetNoteId)
        }
        // De tijdelijke notitie is nu leeg (entries verplaatst) → veilig te
        // verwijderen zonder entry-verlies.
        try? app.history?.deleteNote(id: tempNoteId, deleteEntries: false)
        dismiss()
        onMovedToOther?()
    }
}
