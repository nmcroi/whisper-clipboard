import Core
import Foundation
import SwiftUI
import WhisperShared

/// Een sheet die een bestaande opname (uit de Geschiedenis) áán een notitie
/// toevoegt. Toont een lijst van bestaande notities plus "Nieuwe notitie…". Bij
/// keuze wordt de opname z'n `note_id` gezet — daarmee verdwijnt hij uit de losse
/// Geschiedenis (die filtert op `note_id IS NULL`) en verschijnt hij in de notitie.
struct AddToNoteSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    /// De opname die verplaatst wordt.
    let entryId: String
    /// Aangeroepen nadat de opname succesvol aan een notitie is toegevoegd.
    var onMoved: (() -> Void)?

    @State private var showNewNote = false
    @State private var newNoteTitle = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.window.ignoresSafeArea()
                listBody
            }
            .navigationTitle("Voeg toe aan notitie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuleer") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .alert("Nieuwe notitie", isPresented: $showNewNote) {
                TextField("Titel", text: $newNoteTitle)
                Button("Maak aan") { createAndMove() }
                Button("Annuleer", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private var listBody: some View {
        let notes = (try? app.history?.notes()) ?? []
        List {
            Section {
                Button {
                    newNoteTitle = defaultNoteTitle
                    showNewNote = true
                } label: {
                    Label("Nieuwe notitie…", systemImage: "plus")
                        .font(ThemeFont.ui(16, weight: .medium))
                        .foregroundStyle(Theme.accentText)
                }
                .listRowBackground(Theme.window)
            }
            if !notes.isEmpty {
                Section {
                    ForEach(notes, id: \.id) { note in
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
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func title(for note: Note) -> String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? L10n.string( "Naamloze notitie", locale: app.interfaceLanguage.locale)
            : trimmed
    }

    private func move(to noteId: String) {
        guard let history = app.history else { return }
        do {
            try history.moveEntryToNote(entryId: entryId, noteId: noteId)
            onMoved?()
            dismiss()
        } catch {
            app.presentDataChangeError(error)
        }
    }

    private func createAndMove() {
        guard let history = app.history else { return }
        do {
            guard try history.createNote(title: newNoteTitle, movingEntryId: entryId) != nil else {
                return
            }
            onMoved?()
            dismiss()
        } catch {
            app.presentDataChangeError(error)
        }
    }

    private var defaultNoteTitle: String {
        let locale = app.interfaceLanguage.locale
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return String(
            format: L10n.string( "Notitie %@", locale: locale),
            locale: locale,
            formatter.string(from: Date())
        )
    }
}
