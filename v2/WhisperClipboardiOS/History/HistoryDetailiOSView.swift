import Core
import Foundation
import SwiftUI
import UIKit
import WhisperShared

/// The transcript detail screen: grouped body text (Core `SegmentGrouping` so
/// diarized turns / sentences read naturally), with copy, share and delete.
struct HistoryDetailiOSView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let entry: TranscriptEntry

    @State private var didCopy = false
    @State private var showsAI = false
    @State private var showAddToNote = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Theme.window.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // De titel staat bewust ín de inhoud en niet in de
                    // navigatiebalk: het instellingen-tandwiel van RootView
                    // zweeft daar los overheen, waardoor een lange titel er
                    // dwars doorheen liep (bevinding 2026-08-02).
                    VStack(alignment: .leading, spacing: 8) {
                        header
                        Text(title)
                            .font(ThemeFont.ui(22, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if showsAI, let modes = app.modes {
                        AIRunnerView(
                            entry: entry,
                            modes: modes,
                            onAddToNote: { showAddToNote = true },
                            onOpenSettings: { showSettings = true }
                        )
                        Divider().overlay(Theme.border)
                    }
                    bodyText
                }
                .padding(20)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            actionBar
        }
        .toolbar {
            // Links geplaatst (naast de terug-chevron): rechtsboven zweeft het
            // globale instellingen-tandwiel van RootView.
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        showAddToNote = true
                    } label: {
                        Label("Voeg toe aan notitie…", systemImage: "note.text.badge.plus")
                    }
                    Button(role: .destructive) {
                        deleteTranscript()
                    } label: {
                        Label("Verwijder", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Theme.accentText)
                }
            }
        }
        .sheet(isPresented: $showAddToNote) {
            AddToNoteSheet(entryId: entry.id) {
                // De opname hoort nu bij een notitie en verdwijnt uit de losse
                // Geschiedenis: sluit het detailscherm.
                dismiss()
            }
            .environmentObject(app)
            .preferredColorScheme(app.appearance.preferredColorScheme)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environmentObject(app)
                .preferredColorScheme(app.appearance.preferredColorScheme)
        }
    }

    private func deleteTranscript() {
        guard let history = app.history else { return }
        do {
            try history.delete(id: entry.id)
            dismiss()
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

    /// Twee regels in plaats van één: bron en duur boven, opnamemoment en taal
    /// eronder. Alles op één regel stond te gepropt (bevinding 2026-08-02).
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: TranscriptSourceStyle.icon(for: entry.source))
                    .foregroundStyle(Theme.accentText)
                Text(sourceLabel)
                if entry.duration > 0 {
                    Text("·")
                    Text(durationText)
                }
            }
            HStack(spacing: 8) {
                if let recordedAtText {
                    Text(recordedAtText)
                    Text("·")
                }
                Text(languageLabel)
            }
        }
        .font(ThemeFont.ui(14))
        .foregroundStyle(Theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var bodyText: some View {
        let turns = SegmentGrouping.speakerTurns(from: entry.segments)
        if turns.count > 1 || (turns.first?.speaker != nil) {
            // Diarized / multi-turn: render each turn with its (renamed) speaker.
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                    VStack(alignment: .leading, spacing: 4) {
                        if let raw = turn.speaker {
                            Text(entry.displayName(forSpeaker: raw))
                                .font(ThemeFont.ui(13, weight: .semibold))
                                .foregroundStyle(Theme.accentText)
                        }
                        Text(turn.text)
                            .font(ThemeFont.ui(17))
                            .foregroundStyle(Theme.text)
                    }
                }
            }
            .textSelection(.enabled)
        } else {
            // Plain transcript: use sentence grouping for readable paragraphs.
            let sentences = SegmentGrouping.sentences(from: entry.segments)
            let text = sentences.isEmpty
                ? entry.text
                : sentences.map(\.text).joined(separator: " ")
            Text(text)
                .font(ThemeFont.ui(17))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            compactAction(
                didCopy ? "✓" : L10n.string( "Kopieer", locale: app.interfaceLanguage.locale),
                systemImage: "doc.on.doc",
                prominent: true
            ) {
                UIPasteboard.general.string = entry.text
                didCopy = true
            }

            ShareLink(item: entry.text) {
                compactActionLabel(
                    L10n.string( "Deel", locale: app.interfaceLanguage.locale),
                    systemImage: "square.and.arrow.up",
                    prominent: false
                )
            }
            .buttonStyle(.plain)

            compactAction(
                "AI",
                systemImage: "sparkles",
                prominent: showsAI
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showsAI.toggle()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Theme.window)
        .overlay(alignment: .bottom) {
            Divider().overlay(Theme.border)
        }
    }

    private func compactAction(
        _ title: String,
        systemImage: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            compactActionLabel(title, systemImage: systemImage, prominent: prominent)
        }
        .buttonStyle(.plain)
    }

    private func compactActionLabel(
        _ title: String,
        systemImage: String,
        prominent: Bool
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(ThemeFont.ui(14, weight: .semibold))
            .foregroundStyle(prominent ? Theme.onAccent : Theme.accentText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(prominent ? Theme.accent : Theme.surface)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                    .stroke(Theme.border, lineWidth: prominent ? 0 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
    }

    private var title: String {
        let trimmedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty && trimmedName.localizedCaseInsensitiveCompare("PLAUD-opname") != .orderedSame {
            return trimmedName
        }
        return String(entry.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
    }

    /// De taal waarin deze opname is uitgeschreven. Leest zowel de nieuwe codes
    /// als oudere opgeslagen waarden.
    private var languageLabel: String {
        TranscriptionLanguage(metadataCode: entry.language)
            .whisperClipLabel(in: app.interfaceLanguage)
    }

    private var durationText: String {
        DurationText.string(seconds: entry.duration, locale: app.interfaceLanguage.locale)
    }

    /// Datum en tijdstip van de opname zelf. In de lijst staat "11 uur geleden";
    /// hier hoort de werkelijke datum (wens Niels, 2026-08-02).
    private var recordedAtText: String? {
        guard let date = entry.timestamp else { return nil }
        return date.formatted(
            .dateTime.day().month(.wide).year().hour().minute()
                .locale(app.interfaceLanguage.locale)
        )
    }

    private var sourceLabel: String {
        let base = entry.source.split(separator: ".").first.map(String.init) ?? entry.source
        return switch base {
        case "file": L10n.string( "Bestand", locale: app.interfaceLanguage.locale)
        case "captions": L10n.string( "Ondertitels", locale: app.interfaceLanguage.locale)
        case "plaud": "PLAUD"
        case "meeting": L10n.string( "Notulen", locale: app.interfaceLanguage.locale)
        default: L10n.string( "iPhone-microfoon", locale: app.interfaceLanguage.locale)
        }
    }
}
