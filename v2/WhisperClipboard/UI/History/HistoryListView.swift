import Core
import Combine
import Foundation
import SwiftUI
import WhisperShared

/// The full history browser: a searchable, filterable list on the left and the
/// selected transcript's detail on the right.
struct HistoryListView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var navigation: AppNavigation
    var modes: ModesService

    @State private var rawQuery = ""
    @State private var debouncedQuery = ""
    @State private var filter: HistoryFilter = .all
    @State private var durationFilter: DurationFilter = .any
    @State private var deviceFilter: DeviceFilter = .any
    @State private var speakerFilter: SpeakerFilter = .any
    @State private var titleFilter: TitleFilter = .any
    @State private var sortOrder: SortOrder = .newest
    @State private var selectedID: String?
    @State private var renamingID: String?
    @State private var renameText = ""
    @State private var deletingEntry: TranscriptEntry?

    /// De zichtbare lijst, één keer opgehaald per echte wijziging.
    ///
    /// Bevinding 2026-08-04: dit was een computed property die bij ELKE
    /// body-pass een blokkerende `dbQueue.read` van 500 rijen deed, inclusief
    /// JSON-decode van alle segmenten — en `listPane`, `listContent`,
    /// `detailPane` en `selectedEntry` lazen hem allemaal, dus drie à vier van
    /// die queries per pass, synchroon op de main thread. Dat is de merkbare
    /// vertraging bij elke klik.
    @State private var entries: [TranscriptEntry] = []

    /// Of de eerste query al gedraaid heeft. Zonder deze vlag zou de lege staat
    /// ("Nog geen transcripties") één frame flitsen voordat `onAppear` de cache
    /// vult. Bevinding 2026-08-04.
    @State private var hasLoaded = false

    /// Melding van een mislukte schrijfactie naar de store. Bevinding
    /// 2026-08-03: verwijderen, vastzetten en hernoemen liepen via `try?`, dus
    /// een mislukte opslag was onzichtbaar en de lijst deed alsof het gelukt was.
    @State private var dataError: String?

    @State private var searchDebounce = PassthroughSubject<String, Never>()

    var body: some View {
        // A plain HSplitView inside the single NavigationSplitView's detail column
        // (never a nested NavigationSplitView). Minimums are chosen so the pair
        // fits the window's minimum content width alongside the 180pt sidebar.
        HSplitView {
            listPane
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            detailPane
                .frame(minWidth: 460, maxWidth: .infinity)
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
                // Bevinding 2026-08-03: de selectie schoof onvoorwaardelijk door,
                // ook wanneer het verwijderen mislukte — de rij stond er nog maar
                // de gebruiker zag hem niet meer.
                let deleted = DataChange.perform(
                    "Het verwijderen van de transcriptie",
                    reporting: $dataError
                ) {
                    try store.delete(id: entry.id)
                }
                deletingEntry = nil
                guard deleted else { return }
                // Eerst verversen, dan pas de selectie doorschuiven: de cache
                // bevat anders nog de zojuist verwijderde rij (bevinding
                // 2026-08-04).
                refreshEntries()
                if selectedID == entry.id { selectedID = entries.first?.id }
            }
            Button("Annuleer", role: .cancel) { deletingEntry = nil }
        } message: { _ in
            Text("Dit kan niet ongedaan worden gemaakt.")
        }
        .dataChangeAlert($dataError)
        // DispatchQueue.main delivers across run-loop modes, so the debounce
        // still fires while the user is scrolling or dragging the divider.
        .onReceive(searchDebounce.debounce(for: .milliseconds(220), scheduler: DispatchQueue.main)) { value in
            debouncedQuery = value
        }
        .onChange(of: navigation.pendingTranscriptID) { _, id in
            if let id { selectedID = id; navigation.pendingTranscriptID = nil }
        }
        // Eén query per echte wijziging: zoektekst, filters of sortering
        // (samengebald in `criteria`), of een mutatie in de store.
        .onChange(of: criteria) { _, _ in refreshEntries() }
        // `revision` bumpt na élke mutatie van de store — lokaal (verwijderen,
        // hernoemen, vastzetten, import) én bij binnenkomende iCloud-sync.
        .onChange(of: store.revision) { _, _ in refreshEntries() }
        .onAppear {
            refreshEntries()
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
            HStack {
                Text("Geschiedenis")
                    .font(ThemeFont.ui(20, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("\(entries.count)")
                    .font(ThemeFont.ui(12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 2)
            searchField
            filterChips
            advancedControls
            Divider().overlay(Theme.border)
            listContent
        }
        .background(Theme.window)
    }

    private var advancedControls: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Apparaat", selection: $deviceFilter) {
                    ForEach(DeviceFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Divider()
                Picker("Lengte", selection: $durationFilter) {
                    ForEach(DurationFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Divider()
                Picker("Sprekers", selection: $speakerFilter) {
                    ForEach(SpeakerFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Divider()
                Picker("Titel", selection: $titleFilter) {
                    ForEach(TitleFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if hasAdvancedFilters {
                    Divider()
                    Button("Wis extra filters") {
                        deviceFilter = .any
                        durationFilter = .any
                        speakerFilter = .any
                        titleFilter = .any
                    }
                }
            } label: {
                Label(hasAdvancedFilters ? "Filter actief" : "Filter", systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))

            Menu {
                Picker("Sortering", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } label: {
                Label(sortOrder.label, systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))
            Spacer()
        }
        .font(ThemeFont.ui(11, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var hasAdvancedFilters: Bool {
        deviceFilter != .any || durationFilter != .any || speakerFilter != .any || titleFilter != .any
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
        case .plaud: return "PLAUD"
        }
    }

    @ViewBuilder
    private var listContent: some View {
        let items = entries
        if !hasLoaded {
            Color.clear
        } else if items.isEmpty {
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
                .foregroundStyle(Theme.accentText)
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
                // Ook hier eerst verversen: de cache bevat de zojuist in het
                // detailpaneel verwijderde rij nog (bevinding 2026-08-04).
                onDeleted: {
                    refreshEntries()
                    selectedID = entries.first?.id
                }
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

    /// Alles wat de zichtbare lijst bepaalt, in één waarde. Zo volstaat één
    /// `onChange` en kan er geen filter vergeten worden bij het verversen.
    private struct ListCriteria: Equatable {
        var query: String
        var filter: HistoryFilter
        var device: DeviceFilter
        var duration: DurationFilter
        var speaker: SpeakerFilter
        var title: TitleFilter
        var sort: SortOrder
    }

    private var criteria: ListCriteria {
        ListCriteria(
            query: debouncedQuery,
            filter: filter,
            device: deviceFilter,
            duration: durationFilter,
            speaker: speakerFilter,
            title: titleFilter,
            sort: sortOrder
        )
    }

    /// De enige plek die de database bevraagt. Volgorde, filters, de limiet van
    /// 500 en het zoekgedrag zijn ongewijzigd; alleen het moment waarop dit
    /// draait is veranderd (bevinding 2026-08-04).
    private func refreshEntries() {
        let fetched = (try? store.entries(query: debouncedQuery, filter: filter, limit: 500)) ?? []
        entries = fetched
            .filter { deviceFilter.matches($0) }
            .filter { durationFilter.matches($0.duration) }
            .filter { speakerFilter.matches(speakerCount(of: $0)) }
            .filter { titleFilter.matches($0) }
            .sorted(by: sortOrder.areInIncreasingOrder)
        hasLoaded = true
    }

    private func speakerCount(of entry: TranscriptEntry) -> Int {
        Set(entry.segments.compactMap(\.speaker).filter { !$0.isEmpty }).count
    }

    /// The selected entry, resolved only within the currently visible list. If
    /// the selection was filtered/searched out (or deleted), the detail pane
    /// clears rather than showing a row that isn't in the list.
    ///
    /// Bevinding 2026-08-04: dit deed de volledige query nóg een keer over.
    /// Leest nu uit de al opgehaalde lijst.
    private var selectedEntry: TranscriptEntry? {
        guard let selectedID else { return nil }
        return entries.first { $0.id == selectedID }
    }

    // MARK: - Actions

    private func togglePin(_ entry: TranscriptEntry) {
        DataChange.perform(
            entry.pinned ? "Het losmaken van de transcriptie" : "Het vastzetten van de transcriptie",
            reporting: $dataError
        ) {
            try store.setPinned(id: entry.id, !entry.pinned)
        }
    }

    private func commitRename(_ entry: TranscriptEntry) {
        // Bevinding 2026-08-03: het naamveld klapte dicht alsof de naam bewaard
        // was. Blijf bij een fout in bewerkmodus zodat de ingetypte naam blijft.
        let saved = DataChange.perform(
            "Het hernoemen van de transcriptie",
            reporting: $dataError
        ) {
            try store.rename(id: entry.id, name: renameText)
        }
        guard saved else { return }
        renamingID = nil
    }
}

private enum DeviceFilter: CaseIterable {
    case any, mac, iphone, unknown
    var label: String {
        switch self { case .any: "Alle apparaten"; case .mac: "Mac"; case .iphone: "iPhone"; case .unknown: "Ouder/onbekend" }
    }
    func matches(_ entry: TranscriptEntry) -> Bool {
        let device = TranscriptSourceStyle.device(for: entry.source)
        switch self { case .any: return true; case .mac: return device == "Mac"; case .iphone: return device == "iPhone"; case .unknown: return device == nil }
    }
}

private enum DurationFilter: CaseIterable {
    case any, under1, oneTo5, fiveTo10, tenTo20, twentyTo60, over60
    var label: String {
        switch self { case .any: "Alle lengtes"; case .under1: "Korter dan 1 minuut"; case .oneTo5: "1–5 minuten"; case .fiveTo10: "5–10 minuten"; case .tenTo20: "10–20 minuten"; case .twentyTo60: "20–60 minuten"; case .over60: "Langer dan 1 uur" }
    }
    func matches(_ seconds: Double) -> Bool {
        switch self { case .any: return true; case .under1: return seconds < 60; case .oneTo5: return seconds >= 60 && seconds < 300; case .fiveTo10: return seconds >= 300 && seconds < 600; case .tenTo20: return seconds >= 600 && seconds < 1200; case .twentyTo60: return seconds >= 1200 && seconds < 3600; case .over60: return seconds >= 3600 }
    }
}

private enum SpeakerFilter: CaseIterable {
    case any, one, two, threePlus
    var label: String { switch self { case .any: "Alle aantallen sprekers"; case .one: "1 spreker"; case .two: "2 sprekers"; case .threePlus: "3 of meer sprekers" } }
    func matches(_ count: Int) -> Bool { switch self { case .any: return true; case .one: return count <= 1; case .two: return count == 2; case .threePlus: return count >= 3 } }
}

private enum TitleFilter: CaseIterable {
    case any, titled, untitled
    var label: String { switch self { case .any: "Met en zonder titel"; case .titled: "Titel ingevuld"; case .untitled: "Geen titel ingevuld" } }
    func matches(_ entry: TranscriptEntry) -> Bool {
        let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTitle = !name.isEmpty && name.localizedCaseInsensitiveCompare("PLAUD-opname") != .orderedSame
        switch self { case .any: return true; case .titled: return hasTitle; case .untitled: return !hasTitle }
    }
}

private enum SortOrder: CaseIterable {
    case newest, oldest, nameAZ, nameZA, longest, shortest
    var label: String { switch self { case .newest: "Nieuwste"; case .oldest: "Oudste"; case .nameAZ: "Naam A–Z"; case .nameZA: "Naam Z–A"; case .longest: "Langste"; case .shortest: "Kortste" } }
    func areInIncreasingOrder(_ lhs: TranscriptEntry, _ rhs: TranscriptEntry) -> Bool {
        switch self {
        case .newest: return (lhs.timestamp ?? .distantPast) > (rhs.timestamp ?? .distantPast)
        case .oldest: return (lhs.timestamp ?? .distantPast) < (rhs.timestamp ?? .distantPast)
        case .nameAZ: return displayName(lhs).localizedCaseInsensitiveCompare(displayName(rhs)) == .orderedAscending
        case .nameZA: return displayName(lhs).localizedCaseInsensitiveCompare(displayName(rhs)) == .orderedDescending
        case .longest: return lhs.duration > rhs.duration
        case .shortest: return lhs.duration < rhs.duration
        }
    }
    private func displayName(_ entry: TranscriptEntry) -> String {
        let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.localizedCaseInsensitiveCompare("PLAUD-opname") == .orderedSame
            ? entry.text
            : name
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
