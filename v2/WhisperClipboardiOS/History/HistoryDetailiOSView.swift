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
    @State private var showAddToNote = false

    var body: some View {
        ZStack {
            Theme.window.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    bodyText
                }
                .padding(20)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Links geplaatst (naast de terug-chevron): rechtsboven zweeft het
            // globale instellingen-tandwiel van RootView.
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ShareLink(item: entry.text) {
                        Label("Deel", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        showAddToNote = true
                    } label: {
                        Label("Voeg toe aan notitie…", systemImage: "note.text.badge.plus")
                    }
                    Button(role: .destructive) {
                        try? app.history?.delete(id: entry.id)
                        dismiss()
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
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: TranscriptSourceStyle.icon(for: entry.source))
                .foregroundStyle(Theme.accentText)
            Text(TranscriptSourceStyle.label(for: entry.source))
            if entry.duration > 0 {
                Text("·")
                Text(durationText)
            }
        }
        .font(ThemeFont.ui(14))
        .foregroundStyle(Theme.textSecondary)
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

        Button {
            UIPasteboard.general.string = entry.text
            didCopy = true
        } label: {
            Label(didCopy ? "Gekopieerd" : "Kopieer", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                .font(ThemeFont.ui(16, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    private var title: String {
        let trimmedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { return trimmedName }
        return String(entry.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
    }

    private var durationText: String {
        let total = Int(entry.duration.rounded())
        if total < 60 { return "\(total) s" }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
