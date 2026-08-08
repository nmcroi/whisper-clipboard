import AppKit
import Core
import Foundation
import SwiftUI
import WhisperShared

/// Full detail for one transcript: editable title, metadata, and a **readable,
/// grouped** transcript body (speaker turns for diarized entries, sentence
/// paragraphs otherwise) with copy / export / delete, inline body editing,
/// per-speaker renaming, and sentence/turn trimming.
///
/// Parakeet returns *word-level* segments; this view never shows one word per
/// row. It coalesces them into sentences / speaker turns via the pure
/// `Core.SegmentGrouping` helpers (display/derivation only — the word-level data
/// stays stored so timecodes and timed export keep working).
///
/// ## Edited-text vs segments policy
/// Inline body edits persist the plain `text` via `HistoryStore.updateText` and
/// leave the stored word-level `segments` untouched. Once the stored `text`
/// diverges from what the segments would rebuild (i.e. the user hand-edited the
/// body), the view renders that edited plain text and hides timecodes (they'd no
/// longer line up), while copy/export use the edited text. **Trimming** instead
/// goes through `updateSegments`, which rebuilds `text` from the kept words so
/// text and segments stay in sync and timecodes remain meaningful.
struct TranscriptDetailView: View {
    let entry: TranscriptEntry
    @ObservedObject var store: HistoryStore
    var modes: ModesService
    var onDeleted: () -> Void
    /// Opens the Settings window (AI tab) so the user can add their API key.
    var onOpenSettings: () -> Void = { TranscriptDetailView.openSettings() }

    @State private var titleDraft = ""
    @State private var copied = false
    @State private var confirmingDelete = false
    @State private var showTimecodes = false
    @FocusState private var titleFocused: Bool

    // Inline body editing.
    @State private var isEditingBody = false
    @State private var bodyDraft = ""
    @State private var aiExpanded = false

    // Speaker renaming: the raw label currently being edited (e.g. "Spreker 1").
    @State private var editingSpeaker: String?
    @State private var speakerNameDraft = ""

    // Trimming confirmation: the group (turn or sentence) pending deletion.
    @State private var pendingTrim: TrimTarget?
    @State private var trimError: String?

    /// Melding van een mislukte schrijfactie naar de store. Bevinding
    /// 2026-08-03: alle mutaties hieronder liepen via `try?`, dus een mislukte
    /// opslag was onzichtbaar en de UI toonde de wijziging alsof hij bewaard was.
    @State private var dataError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                titleField
                metadataLine
                actionBar
                Divider().overlay(Theme.border)
                aiDisclosure
                Divider().overlay(Theme.border)
                if hasSpeakers && !isEditingBody { speakerLegend }
                bodySection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.window)
        .onAppear {
            titleDraft = entry.name.localizedCaseInsensitiveCompare("PLAUD-opname") == .orderedSame
                ? ""
                : entry.name
        }
        // Bevinding 2026-08-03: bij het sluiten van dit paneel bestaat er geen view
        // meer die een alert kan tonen, dus escaleert een mislukte hernoeming hier.
        .onDisappear { commitTitle(escalating: true) }
        .confirmationDialog(
            "Verwijder deze transcriptie?",
            isPresented: $confirmingDelete
        ) {
            Button("Verwijder", role: .destructive) {
                // Bevinding 2026-08-03: `onDeleted()` werd onvoorwaardelijk
                // aangeroepen, dus het detailpaneel sloot en de selectie schoof
                // door ook wanneer het verwijderen was mislukt — de transcriptie
                // stond er nog, maar leek weg.
                let deleted = DataChange.perform(
                    "Het verwijderen van de transcriptie",
                    reporting: $dataError
                ) {
                    try store.delete(id: entry.id)
                }
                guard deleted else { return }
                onDeleted()
            }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text("Dit kan niet ongedaan worden gemaakt.")
        }
        .confirmationDialog(
            trimDialogTitle,
            isPresented: Binding(get: { pendingTrim != nil }, set: { if !$0 { pendingTrim = nil } }),
            presenting: pendingTrim
        ) { target in
            Button("Verwijder tekst", role: .destructive) { performTrim(target, alsoAudio: false) }
            if hasAudio {
                Button("Verwijder tekst én audio", role: .destructive) { performTrim(target, alsoAudio: true) }
            }
            Button("Annuleer", role: .cancel) { pendingTrim = nil }
        } message: { _ in
            Text(hasAudio
                 ? "Dit verwijdert dit fragment uit de transcriptie. Je kunt ook de bijbehorende audio bijsnijden."
                 : "Dit verwijdert dit fragment uit de transcriptie.")
        }
        .alert("Audio bijsnijden", isPresented: Binding(get: { trimError != nil }, set: { if !$0 { trimError = nil } })) {
            Button("Oké", role: .cancel) { trimError = nil }
        } message: {
            Text(trimError ?? "")
        }
        .dataChangeAlert($dataError)
    }

    // MARK: - Title

    private var titleField: some View {
        TextField(
            "",
            text: $titleDraft,
            prompt: Text(TranscriptFormatting.title(for: entry)).foregroundStyle(Theme.text)
        )
            .textFieldStyle(.plain)
            .font(ThemeFont.ui(22, weight: .bold))
            .foregroundStyle(Theme.text)
            .focused($titleFocused)
            .onSubmit { commitTitle() }
            .onChange(of: titleFocused) { _, focused in
                if !focused { commitTitle() }
            }
    }

    // MARK: - Metadata

    private var metadataLine: some View {
        HStack(spacing: 10) {
            metaItem(icon: TranscriptSourceStyle.icon(for: entry.source),
                     text: TranscriptSourceStyle.label(for: entry.source))
            metaItem(icon: "calendar", text: TranscriptFormatting.fullDate(for: entry))
            if entry.duration >= 1 {
                metaItem(icon: "clock", text: TranscriptFormatting.duration(entry.duration))
            }
            if !entry.language.isEmpty {
                metaItem(icon: "globe", text: entry.language.uppercased())
            }
            if entry.pinned {
                metaItem(icon: "pin.fill", text: "Vastgezet", tint: Theme.accentText)
            }
            if speakerCount > 0 {
                metaItem(icon: "person.2.fill",
                         text: speakerCount == 1 ? "1 spreker" : "\(speakerCount) sprekers")
            }
            if hasAudio {
                metaItem(icon: "waveform", text: "Audio")
            }
            Spacer(minLength: 0)
        }
        .font(ThemeFont.ui(11, weight: .medium))
    }

    private func metaItem(icon: String, text: String, tint: Color = Theme.textSecondary) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text)
        }
        .foregroundStyle(tint)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                Clipboard.copy(entry.text)
                flashCopied()
            } label: {
                Label(copied ? "Gekopieerd ✓" : "Kopieer", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(AccentButtonStyle())

            // Inline editing toggle.
            Button {
                if isEditingBody { saveBodyEdit() } else { beginBodyEdit() }
            } label: {
                Label(isEditingBody ? "Bewaar" : "Bewerk",
                      systemImage: isEditingBody ? "checkmark.circle" : "pencil")
                    .font(ThemeFont.ui(13, weight: .medium))
                    .foregroundStyle(isEditingBody ? Theme.onAccent : Theme.text)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isEditingBody ? Theme.accent : Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))

            if isEditingBody {
                Button("Annuleer") { cancelBodyEdit() }
                    .buttonStyle(.plain)
                    .font(ThemeFont.ui(13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .secondaryChrome()
            }

            Spacer()

            Menu {
                Menu("Exporteer") {
                    ForEach(ExportFormat.allCases, id: \.self) { format in
                        Button(format.fileExtension.uppercased()) { export(as: format) }
                    }
                }
                Button(entry.pinned ? "Losmaken" : "Vastzetten") {
                    DataChange.perform(
                        entry.pinned
                            ? "Het losmaken van de transcriptie"
                            : "Het vastzetten van de transcriptie",
                        reporting: $dataError
                    ) {
                        try store.setPinned(id: entry.id, !entry.pinned)
                    }
                }
                if canGroup && !isEditingBody {
                    Toggle("Toon tijdcodes", isOn: $showTimecodes)
                }
                Divider()
                Button("Verwijder", role: .destructive) { confirmingDelete = true }
            } label: {
                Label("Meer", systemImage: "ellipsis.circle")
                    .font(ThemeFont.ui(13, weight: .medium))
                    .foregroundStyle(Theme.text)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .secondaryChrome()
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var bodySection: some View {
        if isEditingBody {
            bodyEditor
        } else if canGroup, hasSpeakers {
            speakerTurnsView
        } else if canGroup {
            sentencesView
        } else {
            plainBody
        }
    }

    /// The raw flat text (used when body was hand-edited or has no segments).
    private var plainBody: some View {
        Text(entry.text)
            .font(ThemeFont.ui(14))
            .foregroundStyle(Theme.text)
            .textSelection(.enabled)
            .lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bodyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bewerk de transcriptie. Tijdcodes en sprekers gaan verloren voor de bewerkte tekst.")
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textTertiary)
            TextEditor(text: $bodyDraft)
                .font(ThemeFont.ui(14))
                .foregroundStyle(Theme.text)
                .scrollContentBackground(.hidden)
                .lineSpacing(5)
                .frame(minHeight: 220)
                .padding(10)
                .background(Theme.surfaceHover)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                    .strokeBorder(Theme.borderStrong, lineWidth: 1))
        }
    }

    // MARK: - Speaker legend + rename

    /// A compact "Sprekers" editor: one chip per distinct speaker; click to rename.
    private var speakerLegend: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sprekers")
                    .font(ThemeFont.ui(12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if speakerCount > 2 {
                    Button {
                        DataChange.perform(
                            "Het samenvoegen tot twee sprekers",
                            reporting: $dataError
                        ) {
                            try store.limitSpeakers(id: entry.id, maximum: 2)
                        }
                    } label: {
                        Label("Beperk tot 2 sprekers", systemImage: "person.2")
                            .font(ThemeFont.ui(11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .secondaryChrome()
                    .help("Voeg foutief herkende extra sprekers samen tot twee")
                }
            }
            FlowRow(spacing: 8) {
                ForEach(distinctSpeakers, id: \.self) { raw in
                    speakerLegendChip(raw)
                }
            }
        }
    }

    // MARK: - AI

    private var aiDisclosure: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { aiExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accentText)
                    Text.accentDotted("AI")
                        .font(ThemeFont.ui(15, weight: .semibold))
                    Text("Samenvatten, notulen en meer")
                        .font(ThemeFont.ui(11))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Image(systemName: aiExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if aiExpanded {
                TranscriptAISection(
                    entry: entry,
                    modes: modes,
                    onOpenSettings: onOpenSettings,
                    showsHeader: false
                )
            }
        }
    }

    @ViewBuilder
    private func speakerLegendChip(_ raw: String) -> some View {
        if editingSpeaker == raw {
            HStack(spacing: 6) {
                Circle().fill(Self.speakerColor(for: raw)).frame(width: 9, height: 9)
                TextField(raw, text: $speakerNameDraft)
                    .textFieldStyle(.plain)
                    .font(ThemeFont.ui(12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .frame(width: 120)
                    .onSubmit { commitSpeakerName(raw) }
                Button {
                    commitSpeakerName(raw)
                } label: {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accentText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.surfaceHover)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Theme.borderStrong, lineWidth: 1))
        } else {
            Button {
                editingSpeaker = raw
                speakerNameDraft = entry.speakerNames[raw] ?? ""
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(Self.speakerColor(for: raw)).frame(width: 9, height: 9)
                    Text(entry.displayName(forSpeaker: raw))
                        .font(ThemeFont.ui(12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Image(systemName: "pencil")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Theme.surface)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Hernoem \(raw)")
        }
    }

    // MARK: - Grouped renderings

    private var speakerTurnsView: some View {
        // Materialise the grouping once. Referencing the computed `speakerTurns`
        // from every row used to regroup 11,000+ words hundreds of times for a
        // long PLAUD recording, which saturated the main thread on selection.
        let turns = speakerTurns
        return LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                TranscriptTurnRow(
                    displayName: turn.speaker.map { entry.displayName(forSpeaker: $0) } ?? "Spreker ?",
                    color: turn.speaker.map { Self.speakerColor(for: $0) } ?? Theme.textSecondary,
                    text: turn.text,
                    timecode: showTimecodes ? TranscriptFormatting.timecode(turn.start) : nil,
                    onDelete: turns.count > 1
                        ? { pendingTrim = .turn(index) }
                        : nil
                )
            }
        }
    }

    private var sentencesView: some View {
        let groupedSentences = sentences
        return LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(Array(groupedSentences.enumerated()), id: \.offset) { index, sentence in
                TranscriptSentenceRow(
                    text: sentence.text,
                    timecode: showTimecodes ? TranscriptFormatting.timecode(sentence.start) : nil,
                    onDelete: groupedSentences.count > 1
                        ? { pendingTrim = .sentence(index) }
                        : nil
                )
            }
        }
    }

    // MARK: - Derived data

    /// The word-level segments that carry text (the raw stored data).
    private var resolvedSegments: [TranscriptSegment] {
        entry.segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Whether we can render a grouped view: the entry still has word-level
    /// segments. A manual body edit clears the segments (see
    /// `HistoryStore.updateText`), so an edited entry falls back to the plain
    /// body with no timecodes — exactly the desired behavior.
    private var canGroup: Bool {
        !resolvedSegments.isEmpty
    }

    private var hasSpeakers: Bool {
        resolvedSegments.contains { ($0.speaker?.isEmpty == false) }
    }

    private var sentences: [TranscriptSegment] {
        SegmentGrouping.sentences(from: resolvedSegments)
    }

    private var speakerTurns: [SpeakerTurn2] {
        SegmentGrouping.speakerTurns(from: resolvedSegments)
    }

    /// Distinct raw speaker labels in first-appearance order.
    private var distinctSpeakers: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for seg in resolvedSegments {
            guard let s = seg.speaker, !s.isEmpty, !seen.contains(s) else { continue }
            seen.insert(s)
            ordered.append(s)
        }
        return ordered
    }

    private var speakerCount: Int { distinctSpeakers.count }

    private var hasAudio: Bool { TranscriptAudioStore.hasAudio(for: entry) }

    // MARK: - Title / copy helpers

    /// Bewaart de titel. Met `escalating` gaat een fout niet naar de alert van
    /// dit paneel maar naar de kritieke melding: bij `onDisappear` is er geen
    /// view meer die een alert kán tonen (bevinding 2026-08-03).
    private func commitTitle(escalating: Bool = false) {
        guard titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            != entry.name.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        DataChange.perform(
            "Het hernoemen van de transcriptie",
            report: { message in
                if escalating {
                    Notifications.postCritical(message, title: "Transcriptie hernoemen")
                } else {
                    dataError = message
                }
            }
        ) {
            try store.rename(id: entry.id, name: titleDraft)
        }
    }

    private func flashCopied() {
        copied = true
        Task {
            try? await Task.sleep(for: .milliseconds(1400))
            copied = false
        }
    }

    // MARK: - Body editing

    private func beginBodyEdit() {
        bodyDraft = entry.text
        isEditingBody = true
    }

    private func cancelBodyEdit() {
        isEditingBody = false
        bodyDraft = ""
    }

    private func saveBodyEdit() {
        let trimmed = bodyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != entry.text.trimmingCharacters(in: .whitespacesAndNewlines) {
            // Bevinding 2026-08-03: de editor sloot en `bodyDraft` werd gewist
            // ook als het opslaan mislukte — de bewerkte tekst was dan weg. Blijf
            // in bewerkmodus staan zodat de gebruiker zijn tekst nog heeft.
            let saved = DataChange.perform(
                "Het bewaren van de bewerkte tekst",
                reporting: $dataError
            ) {
                try store.updateText(id: entry.id, text: trimmed)
            }
            guard saved else { return }
        }
        isEditingBody = false
        bodyDraft = ""
    }

    // MARK: - Speaker naming

    private func commitSpeakerName(_ raw: String) {
        // Bevinding 2026-08-03: het chipje klapte dicht alsof de naam bewaard was,
        // ook bij een mislukte schrijfactie. Blijf bij een fout in bewerkmodus.
        let saved = DataChange.perform(
            "Het hernoemen van de spreker",
            reporting: $dataError
        ) {
            try store.setSpeakerName(transcriptId: entry.id, rawSpeaker: raw, name: speakerNameDraft)
        }
        guard saved else { return }
        editingSpeaker = nil
        speakerNameDraft = ""
    }

    // MARK: - Trimming

    private var trimDialogTitle: String {
        switch pendingTrim {
        case .turn: return "Spreekbeurt verwijderen?"
        case .sentence: return "Zin verwijderen?"
        case .none: return ""
        }
    }

    /// The time range covered by the pending trim target, in seconds.
    private func timeRange(for target: TrimTarget) -> ClosedRange<Double>? {
        switch target {
        case .turn(let i):
            guard speakerTurns.indices.contains(i) else { return nil }
            let t = speakerTurns[i]
            return t.start...max(t.start, t.end)
        case .sentence(let i):
            guard sentences.indices.contains(i) else { return nil }
            let s = sentences[i]
            return s.start...max(s.start, s.end)
        }
    }

    /// Removes the target group's words from the stored segments (rebuilding the
    /// text), and optionally trims the saved audio to the kept ranges.
    private func performTrim(_ target: TrimTarget, alsoAudio: Bool) {
        guard let removeRange = timeRange(for: target) else { pendingTrim = nil; return }

        // Keep every stored word whose midpoint falls outside the removed range.
        let kept = entry.segments.filter { seg in
            let mid = (seg.start + seg.end) / 2
            return !(mid >= removeRange.lowerBound && mid <= removeRange.upperBound)
        }
        // Bevinding 2026-08-03: dit is de zwaarste van de zeven `try?`-mutaties.
        // `updateSegments` bouwt de `text` van de transcriptie opnieuw op uit de
        // overgebleven woorden en overschrijft daarmee onherstelbaar de
        // nabewerkte of met de hand geredigeerde tekst. Mislukte dat, dan zag de
        // gebruiker niets — en lukte het, dan was de oude tekst weg. De fout moet
        // dus zichtbaar zijn, en bij een fout snijden we ook de audio niet bij
        // (anders raken tekst en audio uit elkaar).
        let saved = DataChange.perform(
            "Het verwijderen van dit fragment uit de transcriptie",
            reporting: $dataError
        ) {
            try store.updateSegments(id: entry.id, segments: kept)
        }
        guard saved else {
            pendingTrim = nil
            return
        }

        if alsoAudio, hasAudio {
            let keptRanges = contiguousRanges(from: kept)
            let entryForTrim = entry
            Task {
                do {
                    try await TranscriptAudioStore.trimAudio(for: entryForTrim, keeping: keptRanges)
                } catch {
                    await MainActor.run {
                        trimError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
            }
        }
        pendingTrim = nil
    }

    /// Collapses kept word segments into a few contiguous time ranges (merging
    /// words separated by only small gaps), for splicing the audio.
    private func contiguousRanges(from segments: [TranscriptSegment]) -> [ClosedRange<Double>] {
        let sorted = segments.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return [] }
        var ranges: [ClosedRange<Double>] = []
        var lo = sorted[0].start
        var hi = sorted[0].end
        for seg in sorted.dropFirst() {
            if seg.start - hi <= 0.6 {  // bridge small inter-word gaps
                hi = max(hi, seg.end)
            } else {
                ranges.append(lo...hi)
                lo = seg.start
                hi = seg.end
            }
        }
        ranges.append(lo...hi)
        return ranges
    }

    // MARK: - Export / settings

    static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    private func export(as format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Exporter.suggestedExportName(for: entry, extension: format.fileExtension)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Exporter.exportEntry(entry, to: url)
            } catch {
                NSLog("Export failed: %@", String(describing: error))
            }
        }
    }

    // MARK: - Speaker colors

    /// Deterministic warm color per speaker label (yellows / oranges / warm
    /// grays / terracotta — deliberately no blue).
    private static let speakerPalette: [Color] = [
        Color(red: 0.98, green: 0.78, blue: 0.20),  // amber-yellow (accent-ish)
        Color(red: 0.92, green: 0.52, blue: 0.18),  // warm orange
        Color(red: 0.85, green: 0.68, blue: 0.42),  // tan
        Color(red: 0.95, green: 0.62, blue: 0.35),  // apricot
        Color(red: 0.72, green: 0.64, blue: 0.52),  // warm gray
        Color(red: 0.90, green: 0.72, blue: 0.30),  // gold
        Color(red: 0.80, green: 0.42, blue: 0.30),  // terracotta
    ]

    static func speakerColor(for speaker: String) -> Color {
        if let n = Int(speaker.split(separator: " ").last ?? "") {
            return speakerPalette[(n - 1 + speakerPalette.count) % speakerPalette.count]
        }
        let idx = abs(speaker.hashValue) % speakerPalette.count
        return speakerPalette[idx]
    }
}

// MARK: - Trim target

/// Identifies which grouped unit a pending trim will remove.
private enum TrimTarget: Equatable {
    case turn(Int)
    case sentence(Int)
}

// MARK: - Turn row

/// One speaker turn: a colored name chip once, then the paragraph. A delete
/// button reveals on hover (transcript trimming).
private struct TranscriptTurnRow: View {
    let displayName: String
    let color: Color
    let text: String
    let timecode: String?
    let onDelete: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(displayName)
                    .font(ThemeFont.ui(11, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(color)
                    .clipShape(Capsule())
                if let timecode {
                    Text(timecode)
                        .font(ThemeFont.ui(10, weight: .medium).monospaced())
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                if hovering, let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(.plain)
                    .help("Verwijder deze spreekbeurt")
                }
            }
            Text(text)
                .font(ThemeFont.ui(14))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(hovering ? Theme.surface : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Sentence row

/// One sentence paragraph (no-speaker transcripts). Optional leading timecode;
/// hover reveals a delete button for trimming.
private struct TranscriptSentenceRow: View {
    let text: String
    let timecode: String?
    let onDelete: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let timecode {
                Text(timecode)
                    .font(ThemeFont.ui(11, weight: .medium).monospaced())
                    .foregroundStyle(Theme.accentText)
                    .frame(width: 46, alignment: .leading)
                    .padding(.top, 1)
            }
            Text(text)
                .font(ThemeFont.ui(14))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hovering, let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                }
                .buttonStyle(.plain)
                .help("Verwijder deze zin")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(hovering ? Theme.surface : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Small chrome helper

private extension View {
    /// The app's standard "secondary button" chrome: surface fill, 1px border,
    /// rounded corners, standard padding.
    func secondaryChrome() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))
    }
}

// MARK: - Flow layout

/// A simple wrapping horizontal layout (chips flow to the next line when they
/// run out of width). Used for the speaker legend.
private struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var x: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, !(rows.last?.isEmpty ?? true) {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(size)
            x += size.width + spacing
        }
        let width = maxWidth == .infinity ? (rows.first?.reduce(0) { $0 + $1.width + spacing } ?? 0) : maxWidth
        var height: CGFloat = 0
        for row in rows {
            height += (row.map(\.height).max() ?? 0) + spacing
        }
        return CGSize(width: width, height: max(0, height - spacing))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
