import Core
import Combine
import Foundation
import SwiftUI

/// The full history browser: a searchable, filterable list on the left and the
/// selected transcript's detail on the right.
struct HistoryListView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var navigation: AppNavigation
    var modes: ModesService

    @State private var rawQuery = ""
    @State private var debouncedQuery = ""
    @State private var filter: HistoryFilter = .all
    @State private var selectedID: String?
    @State private var renamingID: String?
    @State private var renameText = ""
    @State private var deletingEntry: TranscriptEntry?

    @State private var searchDebounce = PassthroughSubject<String, Never>()

    var body: some View {
        // A plain HSplitView inside the single NavigationSplitView's detail column
        // (never a nested NavigationSplitView). Minimums are chosen so the pair
        // fits the window's minimum content width alongside the 180pt sidebar.
        HSplitView {
            listPane
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 460)
            detailPane
                .frame(minWidth: 380, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
        .confirmationDialog(
            "Verwijder deze transcriptie?",
            isPresented: Binding(
                get: { deletingEntry != nil },
                set: { if !$0 { deletingEntry = nil } }
            ),
            presenting: deletingEntry
        ) { entry in
            Button("Verwijder", role: .destructive) {
                try? store.delete(id: entry.id)
                if selectedID == entry.id { selectedID = entries.first?.id }
                deletingEntry = nil
            }
            Button("Annuleer", role: .cancel) { deletingEntry = nil }
        } message: { _ in
            Text("Dit kan niet ongedaan worden gemaakt.")
        }
        // DispatchQueue.main delivers across run-loop modes, so the debounce
        // still fires while the user is scrolling or dragging the divider.
        .onReceive(searchDebounce.debounce(for: .milliseconds(220), scheduler: DispatchQueue.main)) { value in
            debouncedQuery = value
        }
        .onChange(of: navigation.pendingTranscriptID) { _, id in
            if let id { selectedID = id; navigation.pendingTranscriptID = nil }
        }
        .onAppear {
            if let id = navigation.pendingTranscriptID {
                selectedID = id
                navigation.pendingTranscriptID = nil
            } else if selectedID == nil {
                selectedID = entries.first?.id
            }
        }
    }

    // MARK: - List pane

    private var listPane: some View {
        VStack(spacing: 0) {
            searchField
            filterChips
            Divider().overlay(Theme.border)
            listContent
        }
        .background(Theme.window)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            TextField("Zoek in transcripties", text: $rawQuery)
                .textFieldStyle(.plain)
                .font(ThemeFont.ui(13))
                .foregroundStyle(Theme.text)
                .onChange(of: rawQuery) { _, value in searchDebounce.send(value) }
            if !rawQuery.isEmpty {
                // Also push "" through the debounce so a still-pending emission
                // from a rapid type-then-clear can't re-apply the old query.
                Button { rawQuery = ""; debouncedQuery = ""; searchDebounce.send("") } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))
        .padding(12)
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach(HistoryFilter.allCases, id: \.self) { option in
                FilterChip(
                    label: label(for: option),
                    selected: filter == option
                ) { filter = option }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func label(for filter: HistoryFilter) -> String {
        switch filter {
        case .all: return "Alles"
        case .mic: return "Microfoon"
        case .file: return "Bestanden"
        }
    }

    @ViewBuilder
    private var listContent: some View {
        let items = entries
        if items.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items, id: \.id) { entry in
                        row(for: entry)
                        Divider().overlay(Theme.border)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for entry: TranscriptEntry) -> some View {
        Group {
            if renamingID == entry.id {
                renameRow(for: entry)
            } else {
                Button { selectedID = entry.id } label: {
                    TranscriptRow(
                        entry: entry,
                        onTogglePin: { togglePin(entry) }
                    )
                    .background(selectedID == entry.id ? Theme.surfaceHover : Color.clear)
                }
                .buttonStyle(.plain)
                .contextMenu { rowMenu(for: entry) }
            }
        }
    }

    private func renameRow(for entry: TranscriptEntry) -> some View {
        HStack(spacing: 8) {
            TextField("Naam", text: $renameText)
                .textFieldStyle(.plain)
                .font(ThemeFont.ui(13, weight: .medium))
                .foregroundStyle(Theme.text)
                .onSubmit { commitRename(entry) }
            Button("Bewaar") { commitRename(entry) }
                .buttonStyle(.plain)
                .font(ThemeFont.ui(11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Button("Annuleer") { renamingID = nil }
                .buttonStyle(.plain)
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.surfaceHover)
    }

    @ViewBuilder
    private func rowMenu(for entry: TranscriptEntry) -> some View {
        Button("Kopieer") { Clipboard.copy(entry.text) }
        Button("Hernoem") {
            renameText = entry.name
            renamingID = entry.id
        }
        Button(entry.pinned ? "Losmaken" : "Vastzetten") { togglePin(entry) }
        Divider()
        Button("Verwijder", role: .destructive) { deletingEntry = entry }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: debouncedQuery.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(Theme.textTertiary)
            Text(debouncedQuery.isEmpty ? "Nog geen transcripties" : "Geen resultaten")
                .font(ThemeFont.ui(13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            if debouncedQuery.isEmpty {
                Text("Start een opname om je eerste transcriptie te maken.")
                    .font(ThemeFont.ui(12))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let entry = selectedEntry {
            TranscriptDetailView(
                entry: entry,
                store: store,
                modes: modes,
                onDeleted: { selectedID = entries.first?.id }
            )
            .id(entry.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.textTertiary)
                Text("Kies een transcriptie")
                    .font(ThemeFont.ui(13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.window)
        }
    }

    // MARK: - Data

    /// Recomputed whenever the store bumps `revision`, the query, or the filter.
    private var entries: [TranscriptEntry] {
        _ = store.revision
        return (try? store.entries(query: debouncedQuery, filter: filter, limit: 500)) ?? []
    }

    /// The selected entry, resolved only within the currently visible list. If
    /// the selection was filtered/searched out (or deleted), the detail pane
    /// clears rather than showing a row that isn't in the list.
    private var selectedEntry: TranscriptEntry? {
        guard let selectedID else { return nil }
        _ = store.revision
        return entries.first { $0.id == selectedID }
    }

    // MARK: - Actions

    private func togglePin(_ entry: TranscriptEntry) {
        try? store.setPinned(id: entry.id, !entry.pinned)
    }

    private func commitRename(_ entry: TranscriptEntry) {
        try? store.rename(id: entry.id, name: renameText)
        renamingID = nil
    }
}

// MARK: - Filter chip

private struct FilterChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(ThemeFont.ui(12, weight: .medium))
                .foregroundStyle(selected ? Theme.onAccent : Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(selected ? Theme.accent : Theme.surface)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
