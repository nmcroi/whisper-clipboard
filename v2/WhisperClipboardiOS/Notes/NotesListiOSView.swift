import Core
import Foundation
import SwiftUI
import WhisperShared

/// Het "Notities"-tabblad: een lijst van doorlopende, benoemde notities waaraan je
/// over uren/dagen kunt blijven toevoegen. Elke rij toont de titel, wanneer hij
/// laatst gewijzigd is en een korte preview van het staartje van de opgebouwde
/// tekst. De "+" maakt een nieuwe notitie (met een standaardtitel op datum) en
/// opent hem meteen zodat je 'm kunt hernoemen of direct kunt inspreken.
struct NotesListiOSView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    /// Navigatiepad: een net aangemaakte notitie wordt hierop gepusht zodat hij
    /// meteen opent (hernoemen / direct inspreken).
    @State private var path: [String] = []
    /// Notitie-id waarvoor de opname automatisch moet starten zodra de
    /// detailweergave opent (gezet door de +-knop, eenmalig geconsumeerd door
    /// `NoteDetailiOSView`).
    @State private var autoStartNoteId: String?
    /// Notitie die "verwijderd" is via de veeg-actie maar nog binnen het
    /// undo-venster zit: hij is al uit de lijst verborgen, maar de echte
    /// DB-verwijdering gebeurt pas in ``commitPendingDelete()``. Sneuvelt de app
    /// binnen dat venster, dan bestaat de notitie gewoon nog — veilige uitkomst.
    @State private var pendingDeleteNoteId: String?
    @State private var pendingDeleteTask: Task<Void, Never>?

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.window.ignoresSafeArea()
                // De lijst scrolt bóven de vaste onderbalk met de grote
                // spreek-knop (net als het Opnemen-tabblad) — bewust niet
                // zwevend over de rijen.
                VStack(spacing: 0) {
                    MainPageHeader(title: "Notities")
                    listBody
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .undoToast(
                            isPresented: pendingDeleteNoteId != nil,
                            message: L10n.string( "Notitie verwijderd", locale: app.interfaceLanguage.locale),
                            actionTitle: L10n.string( "Ongedaan maken", locale: app.interfaceLanguage.locale)
                        ) {
                            undoDelete()
                        }
                    recordBar
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Wordmark(size: 20)
                }
            }
            .navigationDestination(for: String.self) { id in
                if let note = noteByID(id) {
                    NoteDetailiOSView(note: note, autoStartNoteId: $autoStartNoteId)
                }
            }
            // Verlaat de gebruiker dit scherm of de app vóór het undo-venster om
            // is, voer de verwijdering dan meteen uit — hij mag niet zoekraken.
            .onDisappear { commitPendingDelete() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { commitPendingDelete() }
            }
        }
    }

    /// Vaste onderbalk met de grote centrale spreek-knop — visueel gelijk aan de
    /// Opnemen-knop (gele ring + gele kern). Maakt een notitie, opent hem en start
    /// direct de opname (Niels' flow: tik = meteen inspreken, naam komt later).
    private var recordBar: some View {
        VStack(spacing: 10) {
            NewNoteRecordButton {
                createNote()
            }
            if app.showHelpTips {
                Text("Spreek een nieuwe notitie in")
                    .font(ThemeFont.ui(13))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.border)
                .frame(height: Theme.Metrics.hairline)
        }
    }

    @ViewBuilder
    private var listBody: some View {
        let notes = fetchNotes()
        if notes.isEmpty {
            emptyState
        } else {
            List {
                ForEach(notes, id: \.id) { note in
                    ZStack {
                        NavigationLink(value: note.id) { EmptyView() }
                            .opacity(0)
                        NoteRowiOS(note: note, preview: preview(for: note.id))
                    }
                    .listRowBackground(Theme.window)
                    .listRowSeparatorTint(Theme.border)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            // Veeg-verwijdering met undo-venster: de rij verdwijnt
                            // direct, de echte verwijdering volgt pas na een paar
                            // seconden (zie requestDelete). Entries blijven als
                            // losse Geschiedenis-items behouden (veilige standaard).
                            requestDelete(note.id)
                        } label: {
                            Label("Verwijder", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "note.text")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textTertiary)
            Text("Nog geen notities")
                .font(ThemeFont.ui(17, weight: .semibold))
                .foregroundStyle(Theme.text)
            if app.showHelpTips {
                Text("Tik op de knop hieronder om een notitie in te spreken — en voeg er later gewoon meer aan toe.")
                    .font(ThemeFont.ui(14))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Data

    private func fetchNotes() -> [Note] {
        _ = app.history?.revision
        let notes = (try? app.history?.notes()) ?? []
        // De notitie in het undo-venster is visueel al weg, maar staat nog in de
        // database tot commitPendingDelete().
        return notes.filter { $0.id != pendingDeleteNoteId }
    }

    // MARK: - Verwijderen met undo-venster

    /// Hoe lang de undo-toast zichtbaar blijft voordat de verwijdering echt
    /// wordt uitgevoerd.
    private static let undoWindowSeconds: Double = 5

    private func requestDelete(_ id: String) {
        // Maximaal één pending tegelijk: een nieuwe veeg rondt de vorige eerst af.
        commitPendingDelete()
        pendingDeleteNoteId = id
        pendingDeleteTask = Task {
            try? await Task.sleep(for: .seconds(Self.undoWindowSeconds))
            guard !Task.isCancelled else { return }
            commitPendingDelete()
        }
    }

    /// Voert de uitgestelde verwijdering definitief uit (no-op zonder pending).
    private func commitPendingDelete() {
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        guard let id = pendingDeleteNoteId else { return }
        pendingDeleteNoteId = nil
        do {
            try app.history?.deleteNote(id: id, deleteEntries: false)
        } catch {
            app.presentDataChangeError(error)
        }
    }

    /// Undo binnen het venster: er is nog niets echt verwijderd, dus alleen de
    /// verborgen rij weer tonen.
    private func undoDelete() {
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        pendingDeleteNoteId = nil
    }

    private func noteByID(_ id: String) -> Note? {
        try? app.history?.note(id: id)
    }

    /// Een kort staartje van de samengevoegde notitie-tekst voor de rij-preview.
    private func preview(for noteId: String) -> String {
        let entries = (try? app.history?.noteEntries(noteId: noteId)) ?? []
        let joined = entries
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined
    }

    private func createNote() {
        let locale = app.interfaceLanguage.locale
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        let title = String(
            format: L10n.string( "Notitie %@", locale: locale),
            locale: locale,
            formatter.string(from: Date())
        )
        do {
            guard let note = try app.history?.createNote(title: title) else { return }
            autoStartNoteId = note.id
            path.append(note.id)
        } catch {
            app.presentDataChangeError(error)
        }
    }

}

// MARK: - Grote spreek-knop (rustlook van de Opnemen-knop)

/// De centrale actieknop onder de Notities-lijst: gele ring met afgeronde gele
/// kern, exact de rustlook van `RecordButton` uit RecordView en van het
/// app-icoon — overal hetzelfde beeld, zonder extra glyph.
private struct NewNoteRecordButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Theme.accent, lineWidth: 6)
                    .frame(width: 112, height: 112)

                // Afgeronde gele kern (~42% van de ring, als de app-icoon).
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.accent)
                    .frame(width: 48, height: 48)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Nieuwe notitie (start direct met opnemen)")
    }
}

// MARK: - Row

struct NoteRowiOS: View {
    @EnvironmentObject private var app: AppModel
    let note: Note
    let preview: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "note.text")
                .font(.system(size: 16))
                .foregroundStyle(Theme.accentText)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(ThemeFont.ui(16, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if !preview.isEmpty {
                    Text(preview)
                        .font(ThemeFont.ui(13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Text(relativeDate)
                    .font(ThemeFont.ui(12))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var title: String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? L10n.string( "Naamloze notitie", locale: app.interfaceLanguage.locale)
            : trimmed
    }

    private var relativeDate: String {
        guard let date = note.modifiedDate else { return note.modifiedAt }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = app.interfaceLanguage.locale
        formatter.unitsStyle = .full
        return String(
            format: L10n.string( "Gewijzigd %@", locale: app.interfaceLanguage.locale),
            locale: app.interfaceLanguage.locale,
            formatter.localizedString(for: date, relativeTo: Date())
        )
    }
}
