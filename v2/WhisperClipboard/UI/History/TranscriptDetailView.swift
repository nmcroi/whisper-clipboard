import AppKit
import Core
import Foundation
import SwiftUI

/// Full detail for one transcript: editable title, metadata, selectable body
/// text, an optional timed-segment list, and copy / export / delete actions.
struct TranscriptDetailView: View {
    let entry: TranscriptEntry
    @ObservedObject var store: HistoryStore
    var onDeleted: () -> Void

    @State private var titleDraft = ""
    @State private var copied = false
    @State private var confirmingDelete = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                titleField
                metadataLine
                actionBar
                Divider().overlay(Theme.border)
                bodyText
                if !resolvedSegments.isEmpty {
                    segmentList
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.window)
        .onAppear { titleDraft = entry.name }
        // Commit a pending rename when navigating away (the view is recreated
        // per selection via `.id`, so onDisappear fires on entry switch).
        .onDisappear { commitTitle() }
        .confirmationDialog(
            "Verwijder deze transcriptie?",
            isPresented: $confirmingDelete
        ) {
            Button("Verwijder", role: .destructive) {
                try? store.delete(id: entry.id)
                onDeleted()
            }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text("Dit kan niet ongedaan worden gemaakt.")
        }
    }

    // MARK: - Sections

    private var titleField: some View {
        TextField("Titel (optioneel)", text: $titleDraft)
            .textFieldStyle(.plain)
            .font(ThemeFont.ui(22, weight: .bold))
            .foregroundStyle(Theme.text)
            .focused($titleFocused)
            .onSubmit { commitTitle() }
            // Commit when focus leaves the field (tab away / click elsewhere).
            .onChange(of: titleFocused) { _, focused in
                if !focused { commitTitle() }
            }
    }

    private var metadataLine: some View {
        HStack(spacing: 10) {
            metaItem(icon: entry.source == "file" ? "doc.text" : "mic",
                     text: entry.source == "file" ? "Bestand" : "Microfoon")
            metaItem(icon: "calendar", text: TranscriptFormatting.fullDate(for: entry))
            if entry.duration >= 1 {
                metaItem(icon: "clock", text: TranscriptFormatting.duration(entry.duration))
            }
            if !entry.language.isEmpty {
                metaItem(icon: "globe", text: entry.language.uppercased())
            }
            if entry.pinned {
                metaItem(icon: "pin.fill", text: "Vastgezet", tint: Theme.accent)
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

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                Clipboard.copy(entry.text)
                flashCopied()
            } label: {
                Label(copied ? "Gekopieerd ✓" : "Kopieer", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(AccentButtonStyle())

            Menu {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Button(format.fileExtension.uppercased()) { export(as: format) }
                }
            } label: {
                Label("Exporteer", systemImage: "square.and.arrow.up")
                    .font(ThemeFont.ui(13, weight: .medium))
                    .foregroundStyle(Theme.text)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))

            Button {
                try? store.setPinned(id: entry.id, !entry.pinned)
            } label: {
                Label(entry.pinned ? "Losmaken" : "Vastzetten", systemImage: entry.pinned ? "pin.slash" : "pin")
                    .font(ThemeFont.ui(13, weight: .medium))
                    .foregroundStyle(Theme.text)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))

            Spacer()

            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(Theme.danger)
            }
            .buttonStyle(.plain)
            .help("Verwijder")
        }
    }

    private var bodyText: some View {
        Text(entry.text)
            .font(ThemeFont.ui(14))
            .foregroundStyle(Theme.text)
            .textSelection(.enabled)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var segmentList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Segmenten")
                .font(ThemeFont.ui(13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            VStack(spacing: 0) {
                ForEach(Array(resolvedSegments.enumerated()), id: \.offset) { index, seg in
                    HStack(alignment: .top, spacing: 12) {
                        Text(TranscriptFormatting.timecode(seg.start))
                            .font(ThemeFont.ui(11, weight: .medium).monospaced())
                            .foregroundStyle(Theme.accent)
                            .frame(width: 44, alignment: .leading)
                        Text(seg.text)
                            .font(ThemeFont.ui(13))
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    if index < resolvedSegments.count - 1 {
                        Divider().overlay(Theme.border)
                    }
                }
            }
            .themeCard()
        }
    }

    // MARK: - Helpers

    private var resolvedSegments: [TranscriptSegment] {
        entry.segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func commitTitle() {
        // Skip no-op renames (avoids a spurious store revision bump on every
        // focus change / navigation when the title was never edited).
        guard titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            != entry.name.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        try? store.rename(id: entry.id, name: titleDraft)
    }

    private func flashCopied() {
        copied = true
        Task {
            try? await Task.sleep(for: .milliseconds(1400))
            copied = false
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
}
