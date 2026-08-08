import Core
import Foundation
import SwiftUI
import WhisperShared

/// A single history row: title (name or first words), relative Dutch date,
/// duration, source glyph, and (in full mode) a pin toggle. Used both in the
/// Home "recent" list and the full history list.
struct TranscriptRow: View {
    let entry: TranscriptEntry
    var compact = false
    var onTogglePin: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: TranscriptSourceStyle.icon(for: entry.source))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(TranscriptFormatting.title(for: entry))
                    .font(ThemeFont.ui(13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(TranscriptFormatting.relativeDate(for: entry))
                    if entry.duration >= 1 {
                        Text("·")
                        Text(TranscriptFormatting.duration(entry.duration))
                    }
                }
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 8)

            if entry.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accentText)
            }

            if !compact, let onTogglePin {
                Button(action: onTogglePin) {
                    Image(systemName: entry.pinned ? "pin.slash" : "pin")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(entry.pinned ? "Losmaken" : "Vastzetten")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Formatting helpers

enum TranscriptFormatting {
    /// The row title: the entry name, else the first ~8 words of the text.
    static func title(for entry: TranscriptEntry) -> String {
        let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && name.localizedCaseInsensitiveCompare("PLAUD-opname") != .orderedSame { return name }
        let words = entry.text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .prefix(8)
        let joined = words.joined(separator: " ")
        if joined.isEmpty { return "Zonder titel" }
        return entry.text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count > 8
            ? joined + "…"
            : joined
    }

    /// Relative Dutch date: "vandaag 14:32", "gisteren 09:10", else "dd-MM".
    static func relativeDate(for entry: TranscriptEntry) -> String {
        guard let date = entry.timestamp else { return entry.createdAt }
        let calendar = Calendar.current
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "nl_NL")
        timeFormatter.dateFormat = "HH:mm"

        if calendar.isDateInToday(date) {
            return "vandaag \(timeFormatter.string(from: date))"
        }
        if calendar.isDateInYesterday(date) {
            return "gisteren \(timeFormatter.string(from: date))"
        }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "nl_NL")
        dayFormatter.dateFormat = "dd-MM"
        return dayFormatter.string(from: date)
    }

    /// A longer date line for the detail view: "21-06-2026 10:27".
    static func fullDate(for entry: TranscriptEntry) -> String {
        guard let date = entry.timestamp else { return entry.createdAt }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "nl_NL")
        formatter.dateFormat = "dd-MM-yyyy HH:mm"
        return formatter.string(from: date)
    }

    /// Duration as "m:ss" (or "0:07").
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// A "m:ss" timecode for segment lists.
    static func timecode(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
