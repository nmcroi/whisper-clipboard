import Core
import Foundation
import SwiftUI
import WhisperShared

/// Een herbruikbare picker die één bestaande notitie laat kiezen (spiegelt de
/// lijststijl van ``AddToNoteSheet``/``AssignNoteSheet``). Sluit de huidige notitie
/// uit via `excludingNoteId`. Gebruikt voor:
///  • het hele-notitie samenvoegen (task 4a), en
///  • het verplaatsen van één losse sessie (task 4b).
/// Bij keuze wordt `onPick(noteId)` aangeroepen en de sheet gesloten.
struct NotePickerSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Navigatietitel bovenin (bijv. "Voeg samen met…").
    let title: String
    /// Korte bevestigingsregel als sectie-header ("… verhuizen naar …").
    let header: String
    /// De notitie die niet gekozen mag worden (meestal de huidige).
    let excludingNoteId: String
    /// Aangeroepen met de gekozen notitie-id.
    let onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.window.ignoresSafeArea()
                listBody
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuleer") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private var listBody: some View {
        let others = otherNotes()
        if others.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "note.text")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.textTertiary)
                Text("Geen andere notities")
                    .font(ThemeFont.ui(17, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Er is nog geen andere notitie om naartoe te verplaatsen.")
                    .font(ThemeFont.ui(14))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        } else {
            List {
                Section {
                    ForEach(others, id: \.id) { note in
                        Button {
                            onPick(note.id)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "note.text")
                                    .foregroundStyle(Theme.accentText)
                                Text(displayTitle(for: note))
                                    .font(ThemeFont.ui(16))
                                    .foregroundStyle(Theme.text)
                            }
                        }
                        .listRowBackground(Theme.window)
                        .listRowSeparatorTint(Theme.border)
                    }
                } header: {
                    Text(header)
                        .font(ThemeFont.ui(13))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }

    private func otherNotes() -> [Note] {
        let notes = (try? app.history?.notes()) ?? []
        return notes.filter { $0.id != excludingNoteId }
    }

    private func displayTitle(for note: Note) -> String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? L10n.string( "Naamloze notitie", locale: app.interfaceLanguage.locale)
            : trimmed
    }
}
