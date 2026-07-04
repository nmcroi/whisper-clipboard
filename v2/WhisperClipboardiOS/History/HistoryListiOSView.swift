import Core
import Foundation
import SwiftUI
import WhisperShared

/// The "Geschiedenis" tab: a searchable list of saved transcriptions, newest
/// first. Search hits the shared `HistoryStore` FTS5 index. Rows show a title,
/// relative Dutch date, duration and source glyph; swipe to delete; tap for the
/// detail view.
struct HistoryListiOSView: View {
    @EnvironmentObject private var app: AppModel
    @State private var query = ""
    /// De opname waarvoor de "Voeg toe aan notitie"-sheet open staat.
    @State private var addToNoteTarget: AddToNoteTarget?

    /// Identifiable-wikkel zodat `sheet(item:)` een losse entry-id kan dragen.
    private struct AddToNoteTarget: Identifiable { let id: String }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.window.ignoresSafeArea()
                listBody
            }
            .navigationTitle("Geschiedenis")
            .searchable(text: $query, prompt: "Zoeken")
            .sheet(item: $addToNoteTarget) { target in
                AddToNoteSheet(entryId: target.id)
                    .environmentObject(app)
                    .preferredColorScheme(app.appearance.preferredColorScheme)
            }
        }
    }

    @ViewBuilder
    private var listBody: some View {
        let entries = fetch()
        if entries.isEmpty {
            emptyState
        } else {
            List {
                ForEach(entries, id: \.id) { entry in
                    ZStack {
                        NavigationLink(value: entry.id) {
                            EmptyView()
                        }
                        .opacity(0)
                        TranscriptRowiOS(entry: entry)
                    }
                    .listRowBackground(Theme.window)
                    .listRowSeparatorTint(Theme.border)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            try? app.history?.delete(id: entry.id)
                        } label: {
                            Label("Verwijder", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            addToNoteTarget = AddToNoteTarget(id: entry.id)
                        } label: {
                            Label("Naar notitie", systemImage: "note.text.badge.plus")
                        }
                        .tint(Theme.accentText)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationDestination(for: String.self) { id in
                if let entry = entryByID(id) {
                    HistoryDetailiOSView(entry: entry)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textTertiary)
            Text(query.isEmpty ? "Nog geen opnames" : "Geen resultaten")
                .font(ThemeFont.ui(17, weight: .semibold))
                .foregroundStyle(Theme.text)
            if query.isEmpty {
                Text("Neem iets op via het tabblad Opnemen.")
                    .font(ThemeFont.ui(14))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding()
    }

    // Re-fetch on every render; `history.revision` bumps drive the refresh via
    // the observed store.
    private func fetch() -> [TranscriptEntry] {
        _ = app.history?.revision
        return (try? app.history?.entries(query: query.isEmpty ? nil : query, filter: .all)) ?? []
    }

    private func entryByID(_ id: String) -> TranscriptEntry? {
        (try? app.history?.entries(query: nil, filter: .all))?.first { $0.id == id }
    }
}

// MARK: - Row

struct TranscriptRowiOS: View {
    let entry: TranscriptEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: TranscriptSourceStyle.icon(for: entry.source))
                .font(.system(size: 16))
                .foregroundStyle(Theme.accentText)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(ThemeFont.ui(16, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(relativeDate)
                    if entry.duration > 0 {
                        Text("·")
                        Text(durationText)
                    }
                }
                .font(ThemeFont.ui(13))
                .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if entry.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accentText)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var title: String {
        let trimmedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { return trimmedName }
        let firstWords = entry.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(60)
        return firstWords.isEmpty ? "Naamloze opname" : String(firstWords)
    }

    private var relativeDate: String {
        guard let date = entry.timestamp else { return entry.createdAt }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "nl_NL")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var durationText: String {
        let total = Int(entry.duration.rounded())
        if total < 60 { return "\(total) s" }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
