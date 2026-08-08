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
    @State private var durationFilter = DurationFilter.all
    @State private var deviceFilter = DeviceFilter.all
    @State private var speakerFilter = SpeakerFilter.all
    @State private var titleFilter = TitleFilter.all
    @State private var sortOrder = SortOrder.newest
    /// De opname waarvoor de "Voeg toe aan notitie"-sheet open staat.
    @State private var addToNoteTarget: AddToNoteTarget?

    /// Identifiable-wikkel zodat `sheet(item:)` een losse entry-id kan dragen.
    private struct AddToNoteTarget: Identifiable { let id: String }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.window.ignoresSafeArea()
                VStack(spacing: 0) {
                    MainPageHeader(title: "Geschiedenis")
                    searchField
                    listBody
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Wordmark(size: 20)
                }
            }
            .sheet(item: $addToNoteTarget) { target in
                AddToNoteSheet(entryId: target.id)
                    .environmentObject(app)
                    .preferredColorScheme(app.appearance.preferredColorScheme)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
            TextField("Zoeken", text: $query)
                .font(ThemeFont.ui(17))
                .foregroundStyle(Theme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: Theme.Metrics.hairline)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var listBody: some View {
        let entries = fetch()
        let total = totalCount()
        VStack(spacing: 0) {
            if entries.isEmpty {
                VStack(spacing: 0) {
                    controlsRow(visible: entries.count, total: total)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                    Divider().overlay(Theme.border)
                    emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List {
                    controlsRow(visible: entries.count, total: total)
                        .listRowBackground(Theme.window)
                        .listRowSeparatorTint(Theme.border)

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
                                deleteTranscript(entry.id)
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
    }

    private func deleteTranscript(_ id: String) {
        guard let history = app.history else { return }
        do {
            try history.delete(id: id)
        } catch {
            app.errorMessage = String(
                format: L10n.string(
                    "Het transcript kon niet worden verwijderd: %@",
                    locale: app.interfaceLanguage.locale
                ),
                locale: app.interfaceLanguage.locale,
                error.localizedDescription
            )
        }
    }

    private func controlsRow(visible: Int, total: Int) -> some View {
        HStack(spacing: 14) {
            Text(countLabel(visible: visible, total: total))
                .font(ThemeFont.ui(13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            filterMenu
            sortMenu
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Apparaat", selection: $deviceFilter) {
                ForEach(DeviceFilter.allCases) { Text($0.label(in: app.interfaceLanguage)).tag($0) }
            }
            Picker("Lengte", selection: $durationFilter) {
                ForEach(DurationFilter.allCases) { Text($0.label(in: app.interfaceLanguage)).tag($0) }
            }
            Picker("Sprekers", selection: $speakerFilter) {
                ForEach(SpeakerFilter.allCases) { Text($0.label(in: app.interfaceLanguage)).tag($0) }
            }
            Picker("Titel", selection: $titleFilter) {
                ForEach(TitleFilter.allCases) { Text($0.label(in: app.interfaceLanguage)).tag($0) }
            }
            if filtersAreActive {
                Divider()
                Button("Wis filters", role: .destructive) { resetFilters() }
            }
        } label: {
            Label("Filter", systemImage: filtersAreActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(ThemeFont.ui(13, weight: .semibold))
                .foregroundStyle(Theme.accentText)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sorteren", selection: $sortOrder) {
                ForEach(SortOrder.allCases) { Text($0.label(in: app.interfaceLanguage)).tag($0) }
            }
        } label: {
            Label("Sorteer", systemImage: "arrow.up.arrow.down.circle")
                .font(ThemeFont.ui(13, weight: .semibold))
                .foregroundStyle(Theme.accentText)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textTertiary)
            Text(query.isEmpty && !filtersAreActive
                 ? L10n.string( "Nog geen opnames", locale: app.interfaceLanguage.locale)
                 : L10n.string( "Geen resultaten", locale: app.interfaceLanguage.locale))
                .font(ThemeFont.ui(17, weight: .semibold))
                .foregroundStyle(Theme.text)
            if query.isEmpty && !filtersAreActive && app.showHelpTips {
                Text("Neem iets op via het tabblad Opnemen.")
                    .font(ThemeFont.ui(14))
                    .foregroundStyle(Theme.textSecondary)
            } else if deviceFilter == .iphone {
                Text("Nieuwe iPhone-opnames krijgen automatisch het label iPhone. Bij oudere opnames is het apparaat nog onbekend.")
                    .font(ThemeFont.ui(14))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }

    // Re-fetch on every render; `history.revision` bumps drive the refresh via
    // the observed store.
    private func fetch() -> [TranscriptEntry] {
        _ = app.history?.revision
        let entries = (try? app.history?.entries(query: query.isEmpty ? nil : query, filter: .all, limit: 500)) ?? []
        return entries
            .filter(matchesFilters)
            .sorted(by: isOrdered)
    }

    private var filtersAreActive: Bool {
        durationFilter != .all || deviceFilter != .all || speakerFilter != .all || titleFilter != .all
    }

    private func resetFilters() {
        durationFilter = .all
        deviceFilter = .all
        speakerFilter = .all
        titleFilter = .all
    }

    private func matchesFilters(_ entry: TranscriptEntry) -> Bool {
        durationFilter.matches(entry.duration)
            && deviceFilter.matches(entry.source)
            && speakerFilter.matches(speakerCount(of: entry))
            && titleFilter.matches(entry.name)
    }

    private func speakerCount(of entry: TranscriptEntry) -> Int {
        Set(entry.segments.compactMap(\.speaker).filter { !$0.isEmpty }).count
    }

    private func isOrdered(_ lhs: TranscriptEntry, _ rhs: TranscriptEntry) -> Bool {
        switch sortOrder {
        case .newest: return (lhs.timestamp ?? .distantPast) > (rhs.timestamp ?? .distantPast)
        case .oldest: return (lhs.timestamp ?? .distantPast) < (rhs.timestamp ?? .distantPast)
        case .nameAZ: return displayTitle(lhs).localizedCaseInsensitiveCompare(displayTitle(rhs)) == .orderedAscending
        case .nameZA: return displayTitle(lhs).localizedCaseInsensitiveCompare(displayTitle(rhs)) == .orderedDescending
        case .longest: return lhs.duration > rhs.duration
        case .shortest: return lhs.duration < rhs.duration
        }
    }

    private func displayTitle(_ entry: TranscriptEntry) -> String {
        let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.localizedCaseInsensitiveCompare("PLAUD-opname") == .orderedSame
            ? String(entry.text.prefix(60))
            : name
    }

    private func totalCount() -> Int {
        (try? app.history?.count(query: nil, filter: .all)) ?? 0
    }

    private func countLabel(visible: Int, total: Int) -> String {
        let locale = app.interfaceLanguage.locale
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !filtersAreActive {
            return total == 1
                ? L10n.string( "1 opname", locale: locale)
                : String(format: L10n.string( "%lld opnames", locale: locale), locale: locale, total)
        }
        return String(
            format: L10n.string( "%1$lld van %2$lld opnames", locale: locale),
            locale: locale,
            visible,
            total
        )
    }

    private func entryByID(_ id: String) -> TranscriptEntry? {
        (try? app.history?.entries(query: nil, filter: .all))?.first { $0.id == id }
    }
}

private enum DurationFilter: String, CaseIterable, Identifiable {
    case all, underOne, oneToFive, fiveToTen, tenToTwenty, twentyToSixty, overSixty
    var id: String { rawValue }
    func label(in language: AppLanguage) -> String { switch self {
    case .all: L10n.string( "Alle lengtes", locale: language.locale)
    case .underOne: L10n.string( "Korter dan 1 minuut", locale: language.locale)
    case .oneToFive: L10n.string( "1–5 minuten", locale: language.locale)
    case .fiveToTen: L10n.string( "5–10 minuten", locale: language.locale)
    case .tenToTwenty: L10n.string( "10–20 minuten", locale: language.locale)
    case .twentyToSixty: L10n.string( "20–60 minuten", locale: language.locale)
    case .overSixty: L10n.string( "Langer dan 1 uur", locale: language.locale)
    }}
    func matches(_ seconds: Double) -> Bool { switch self {
    case .all: true; case .underOne: seconds < 60; case .oneToFive: seconds >= 60 && seconds < 300
    case .fiveToTen: seconds >= 300 && seconds < 600; case .tenToTwenty: seconds >= 600 && seconds < 1_200
    case .twentyToSixty: seconds >= 1_200 && seconds < 3_600; case .overSixty: seconds >= 3_600
    }}
}

private enum DeviceFilter: String, CaseIterable, Identifiable {
    case all, mac, iphone, plaud, unknown
    var id: String { rawValue }
    func label(in language: AppLanguage) -> String { switch self {
    case .all: L10n.string( "Alle bronnen", locale: language.locale)
    case .mac: "Mac"; case .iphone: "iPhone"
    case .plaud: "PLAUD"
    case .unknown: L10n.string( "Ouder/onbekend", locale: language.locale)
    } }
    func matches(_ source: String) -> Bool { switch self {
    case .all: true
    case .mac: source.hasSuffix(".mac") && !source.hasPrefix("plaud")
    case .iphone: source.hasSuffix(".ios") && !source.hasPrefix("plaud")
    case .plaud: source == "plaud" || source.hasPrefix("plaud.")
    case .unknown: !source.hasSuffix(".mac") && !source.hasSuffix(".ios")
        && source != "plaud" && !source.hasPrefix("plaud.")
    }}
}

private enum SpeakerFilter: String, CaseIterable, Identifiable {
    case all, one, two, threePlus
    var id: String { rawValue }
    func label(in language: AppLanguage) -> String { switch self {
    case .all: L10n.string( "Elk aantal sprekers", locale: language.locale)
    case .one: L10n.string( "1 spreker", locale: language.locale)
    case .two: L10n.string( "2 sprekers", locale: language.locale)
    case .threePlus: L10n.string( "3 of meer sprekers", locale: language.locale)
    } }
    func matches(_ count: Int) -> Bool { switch self { case .all: true; case .one: count == 1; case .two: count == 2; case .threePlus: count >= 3 } }
}

private enum TitleFilter: String, CaseIterable, Identifiable {
    case all, filled, empty
    var id: String { rawValue }
    func label(in language: AppLanguage) -> String { switch self {
    case .all: L10n.string( "Alle titels", locale: language.locale)
    case .filled: L10n.string( "Titel ingevuld", locale: language.locale)
    case .empty: L10n.string( "Geen titel", locale: language.locale)
    } }
    func matches(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let filled = !trimmed.isEmpty && trimmed.localizedCaseInsensitiveCompare("PLAUD-opname") != .orderedSame
        return switch self { case .all: true; case .filled: filled; case .empty: !filled }
    }
}

private enum SortOrder: String, CaseIterable, Identifiable {
    case newest, oldest, nameAZ, nameZA, longest, shortest
    var id: String { rawValue }
    func label(in language: AppLanguage) -> String { switch self {
    case .newest: L10n.string( "Nieuwste eerst", locale: language.locale)
    case .oldest: L10n.string( "Oudste eerst", locale: language.locale)
    case .nameAZ: L10n.string( "Naam A–Z", locale: language.locale)
    case .nameZA: L10n.string( "Naam Z–A", locale: language.locale)
    case .longest: L10n.string( "Langste eerst", locale: language.locale)
    case .shortest: L10n.string( "Kortste eerst", locale: language.locale)
    } }
}

// MARK: - Row

struct TranscriptRowiOS: View {
    @EnvironmentObject private var app: AppModel
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
        if !trimmedName.isEmpty && trimmedName.localizedCaseInsensitiveCompare("PLAUD-opname") != .orderedSame {
            return trimmedName
        }
        let firstWords = entry.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(60)
        return firstWords.isEmpty
            ? L10n.string( "Naamloze opname", locale: app.interfaceLanguage.locale)
            : String(firstWords)
    }

    /// Een echte datum en tijd, geen "twee weken geleden": Niels zoekt op datum
    /// en moest daarvoor telkens een opname openen (wens 2026-08-02).
    private var relativeDate: String {
        guard let date = entry.timestamp else { return entry.createdAt }
        return date.formatted(
            .dateTime.day().month(.abbreviated).year().hour().minute()
                .locale(app.interfaceLanguage.locale)
        )
    }

    private var durationText: String {
        DurationText.string(seconds: entry.duration, locale: app.interfaceLanguage.locale)
    }
}
