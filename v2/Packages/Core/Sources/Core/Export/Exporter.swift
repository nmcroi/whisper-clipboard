import Foundation

/// Faithful Swift port of `whisper_clipboard/exporter.py`.
public enum Exporter {

    // MARK: - Naming

    /// Mirrors Python's `suggested_export_name`: strip everything but
    /// word characters, hyphens and spaces from the entry name, trim, and
    /// turn spaces into dashes. Falls back to a timestamp-based name when
    /// the result is empty.
    public static func suggestedExportName(for entry: TranscriptEntry, extension ext: String = "txt") -> String {
        let slug = slugify(entry.name)
        let base: String
        if slug.isEmpty {
            base = "transcriptie-\(timestampSlug(for: entry))"
        } else {
            base = slug
        }
        var cleanExt = ext
        while cleanExt.hasPrefix(".") {
            cleanExt.removeFirst()
        }
        return "\(base).\(cleanExt)"
    }

    private static func slugify(_ name: String) -> String {
        // Python: re.sub(r"[^\w\- ]", "", name).strip().replace(" ", "-")
        // \w in Python's default (Unicode) mode matches [a-zA-Z0-9_] plus
        // Unicode word characters (letters, digits, underscore).
        let filtered = name.unicodeScalars.filter { scalar in
            isWordCharacter(scalar) || scalar == "-" || scalar == " "
        }
        let stripped = String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespaces)
        return stripped.replacingOccurrences(of: " ", with: "-")
    }

    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" { return true }
        let props = scalar.properties
        return props.isAlphabetic || (scalar.value >= 48 && scalar.value <= 57) // 0-9
    }

    private static func timestampSlug(for entry: TranscriptEntry) -> String {
        guard let date = entry.timestamp else {
            // Extremely defensive fallback; Python would raise on an
            // unparsable created_at, but we prefer not to crash.
            return "0000-00-00-0000"
        }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        // Use the same offset-aware components the Python
        // `datetime.fromisoformat(...).strftime(...)` would produce: format
        // in the timestamp's own zone/offset, not UTC or local.
        let components = entryDateComponents(from: entry.createdAt) ?? fallbackComponents(from: date)
        return String(
            format: "%04d-%02d-%02d-%02d%02d",
            components.year, components.month, components.day, components.hour, components.minute
        )
    }

    private struct RawDateComponents {
        var year: Int
        var month: Int
        var day: Int
        var hour: Int
        var minute: Int
    }

    /// Parses the ISO-8601 `created_at` string directly for its calendar
    /// fields, preserving whatever UTC offset was embedded in the string
    /// (matching Python's naive-offset-aware `strftime`, which never
    /// converts to another zone).
    private static func entryDateComponents(from isoString: String) -> RawDateComponents? {
        // Expected shape: YYYY-MM-DDTHH:MM:SS[.ffffff][+HH:MM|Z]
        let scalars = Array(isoString)
        guard scalars.count >= 16 else { return nil }
        func intAt(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= scalars.count else { return nil }
            return Int(String(scalars[range]))
        }
        guard
            let year = intAt(0..<4),
            let month = intAt(5..<7),
            let day = intAt(8..<10),
            let hour = intAt(11..<13),
            let minute = intAt(14..<16)
        else {
            return nil
        }
        return RawDateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    }

    private static func fallbackComponents(from date: Date) -> RawDateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return RawDateComponents(
            year: comps.year ?? 0,
            month: comps.month ?? 0,
            day: comps.day ?? 0,
            hour: comps.hour ?? 0,
            minute: comps.minute ?? 0
        )
    }

    /// Mirrors `export_all`'s `f"{index:02d}-{stem}.{extension}"` naming.
    public static func exportAllFileName(index: Int, entry: TranscriptEntry, extension ext: String) -> String {
        let suggested = suggestedExportName(for: entry, extension: "txt")
        let stem = (suggested as NSString).deletingPathExtension
        var cleanExt = ext
        while cleanExt.hasPrefix(".") {
            cleanExt.removeFirst()
        }
        if cleanExt.isEmpty { cleanExt = "md" }
        return String(format: "%02d-%@.%@", index, stem, cleanExt)
    }

    // MARK: - Segment resolution

    /// Mirrors `_segments`: resolves the effective list of (start, end,
    /// text) triples to render, falling back to a single synthetic segment
    /// spanning the whole entry when no real segments carry text.
    static func resolvedSegments(for entry: TranscriptEntry) -> [(start: Double, end: Double, text: String)] {
        resolvedSpeakerSegments(for: entry).map { ($0.start, $0.end, $0.text) }
    }

    /// Speaker-aware variant of ``resolvedSegments(for:)``: the same effective
    /// segment list, but preserving each segment's optional `speaker` label.
    /// The synthetic full-range fallback (no real segments) carries no speaker.
    static func resolvedSpeakerSegments(
        for entry: TranscriptEntry
    ) -> [(start: Double, end: Double, text: String, speaker: String?)] {
        var result: [(start: Double, end: Double, text: String, speaker: String?)] = []
        for segment in entry.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                result.append((segment.start, segment.end, text, segment.speaker))
            }
        }
        if result.isEmpty {
            let trimmedText = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                result.append((0.0, max(entry.duration, 1.0), trimmedText, nil))
            }
        }
        return result
    }

    /// True when any resolved segment carries a speaker label. Speaker-aware
    /// renderers only alter their output when this holds; otherwise output
    /// stays byte-identical to the pre-diarization format.
    static func hasSpeakers(_ entry: TranscriptEntry) -> Bool {
        entry.segments.contains { segment in
            guard let speaker = segment.speaker, !speaker.isEmpty else { return false }
            return !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Mirrors `_timecode`.
    static func timecode(_ seconds: Double, separator: String) -> String {
        var millis = Int((seconds * 1000).rounded(.toNearestOrEven))
        millis = max(0, millis)
        let hours = millis / 3_600_000
        millis %= 3_600_000
        let minutes = millis / 60_000
        millis %= 60_000
        let secs = millis / 1000
        millis %= 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, separator, millis)
    }

    // MARK: - Renderers

    /// Mirrors `to_txt`. When the entry carries speaker labels, the body is
    /// rendered as speaker-grouped turns ("Spreker 1: …") instead of the raw
    /// flat text; without speakers the output is byte-identical to before.
    /// Renamed speakers use their display name (e.g. "Autoverkoper: …").
    public static func toText(_ entry: TranscriptEntry) -> String {
        guard hasSpeakers(entry) else {
            return rstrip(entry.text) + "\n"
        }
        let body = speakerTurns(for: entry)
            .map { "\($0.displayName): \($0.text)" }
            .joined(separator: "\n\n")
        return rstrip(body) + "\n"
    }

    /// Mirrors `to_markdown`. With speaker labels the body becomes bold
    /// speaker-turn paragraphs ("**Spreker 1:** …"); without them the output
    /// is byte-identical to the pre-diarization format.
    public static func toMarkdown(_ entry: TranscriptEntry) -> String {
        let moment = markdownTimestamp(for: entry)
        let trimmedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedName.isEmpty ? moment : trimmedName
        let body: String
        if hasSpeakers(entry) {
            body = speakerTurns(for: entry)
                .map { "**\($0.displayName):** \($0.text)" }
                .joined(separator: "\n\n")
        } else {
            body = entry.text
        }
        return "# \(title)\n\n_\(moment)_\n\n\(rstrip(body))\n"
    }

    /// Groups resolved segments into consecutive same-speaker turns, joining a
    /// turn's segment texts with a single space. Only called when the entry has
    /// speakers; segments with no speaker fall under a "Spreker ?" turn so no
    /// text is dropped (should not occur once merge assigns a label to overlaps).
    /// `displayName` applies the entry's per-transcript rename map, falling back
    /// to the raw label when the speaker was not renamed.
    private static func speakerTurns(
        for entry: TranscriptEntry
    ) -> [(speaker: String, displayName: String, text: String)] {
        var turns: [(speaker: String, displayName: String, text: String)] = []
        for segment in resolvedSpeakerSegments(for: entry) {
            let speaker = segment.speaker ?? "Spreker ?"
            if var last = turns.last, last.speaker == speaker {
                last.text += " " + segment.text
                turns[turns.count - 1] = last
            } else {
                turns.append((speaker, entry.displayName(forSpeaker: speaker), segment.text))
            }
        }
        return turns
    }

    private static func markdownTimestamp(for entry: TranscriptEntry) -> String {
        // Mirrors entry.timestamp.strftime("%d-%m-%Y %H:%M"), formatted in
        // the timestamp's own embedded offset (strftime on an
        // offset-aware datetime never converts zones).
        guard let comps = entryDateComponents(from: entry.createdAt) else {
            return entry.createdAt
        }
        return String(format: "%02d-%02d-%04d %02d:%02d", comps.day, comps.month, comps.year, comps.hour, comps.minute)
    }

    /// Mirrors `to_json`. Hand-rolled to match Python's
    /// `json.dumps(payload, ensure_ascii=False, indent=2)` byte-for-byte,
    /// including key order and float formatting (integral floats render
    /// as "X.0", matching Python's `repr(float)`).
    public static func toJSON(_ entry: TranscriptEntry) -> String {
        var lines: [String] = []
        lines.append("{")
        lines.append("  \"name\": \(jsonString(entry.name)),")
        lines.append("  \"created_at\": \(jsonString(entry.createdAt)),")
        lines.append("  \"language\": \(jsonString(entry.language)),")
        lines.append("  \"model\": \(jsonString(entry.model)),")
        lines.append("  \"duration\": \(jsonNumber(entry.duration)),")
        lines.append("  \"text\": \(jsonString(entry.text)),")
        if entry.segments.isEmpty {
            lines.append("  \"segments\": []")
        } else {
            lines.append("  \"segments\": [")
            for (index, segment) in entry.segments.enumerated() {
                let isLast = index == entry.segments.count - 1
                lines.append("    {")
                lines.append("      \"start\": \(jsonNumber(segment.start)),")
                lines.append("      \"end\": \(jsonNumber(segment.end)),")
                // The `speaker` field is only emitted when present, so segments
                // without a speaker stay byte-identical to the pre-diarization JSON.
                if let speaker = segment.speaker {
                    lines.append("      \"text\": \(jsonString(segment.text)),")
                    lines.append("      \"speaker\": \(jsonString(speaker))")
                } else {
                    lines.append("      \"text\": \(jsonString(segment.text))")
                }
                lines.append(isLast ? "    }" : "    },")
            }
            lines.append("  ]")
        }
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Mirrors `to_srt`. When a segment carries a speaker, the cue text is
    /// prefixed "Spreker 1: tekst"; speaker-less cues are unchanged.
    public static func toSRT(_ entry: TranscriptEntry) -> String {
        var blocks: [String] = []
        for (index, segment) in resolvedSpeakerSegments(for: entry).enumerated() {
            let start = timecode(segment.start, separator: ",")
            let end = timecode(max(segment.end, segment.start), separator: ",")
            let cue = cueText(text: segment.text, speaker: segment.speaker, entry: entry)
            blocks.append("\(index + 1)\n\(start) --> \(end)\n\(cue)\n")
        }
        return blocks.joined(separator: "\n")
    }

    /// Mirrors `to_vtt`. When a segment carries a speaker, the cue text is
    /// prefixed "Spreker 1: tekst"; speaker-less cues are unchanged.
    public static func toVTT(_ entry: TranscriptEntry) -> String {
        var blocks: [String] = ["WEBVTT\n"]
        for segment in resolvedSpeakerSegments(for: entry) {
            let start = timecode(segment.start, separator: ".")
            let end = timecode(max(segment.end, segment.start), separator: ".")
            let cue = cueText(text: segment.text, speaker: segment.speaker, entry: entry)
            blocks.append("\(start) --> \(end)\n\(cue)\n")
        }
        return blocks.joined(separator: "\n")
    }

    /// Prefixes cue text with the speaker label when present ("Spreker 1: …"),
    /// otherwise returns the text unchanged (byte-parity for speaker-less cues).
    /// The label is the entry's display name for the speaker (rename map applied).
    private static func cueText(text: String, speaker: String?, entry: TranscriptEntry) -> String {
        guard let speaker, !speaker.isEmpty else { return text }
        return "\(entry.displayName(forSpeaker: speaker)): \(text)"
    }

    /// Renders `entry` in the given format. This is the Swift equivalent
    /// of dispatching through Python's `_WRITERS` table.
    public static func render(_ entry: TranscriptEntry, as format: ExportFormat) -> String {
        switch format {
        case .txt: return toText(entry)
        case .markdown: return toMarkdown(entry)
        case .json: return toJSON(entry)
        case .srt: return toSRT(entry)
        case .vtt: return toVTT(entry)
        }
    }

    // MARK: - File I/O

    /// Mirrors `export_entry`: picks a writer by the URL's extension,
    /// falling back to `.txt` when unrecognized, creates parent
    /// directories, and writes UTF-8 text. Returns the (possibly
    /// extension-corrected) URL actually written.
    @discardableResult
    public static func exportEntry(_ entry: TranscriptEntry, to url: URL) throws -> URL {
        var finalURL = url
        let format: ExportFormat
        if let resolved = ExportFormat(suffix: url.pathExtension) {
            format = resolved
        } else {
            format = .txt
            finalURL = url.deletingPathExtension().appendingPathExtension("txt")
        }
        let directory = finalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = render(entry, as: format)
        try content.write(to: finalURL, atomically: true, encoding: .utf8)
        return finalURL
    }

    /// Mirrors `export_all`: writes one file per entry into `directory`,
    /// named `"NN-<stem>.<ext>"` with a 2-digit 1-based index.
    @discardableResult
    public static func exportAll(_ entries: [TranscriptEntry], to directory: URL, extension ext: String = "md") throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var cleanExt = ext
        while cleanExt.hasPrefix(".") {
            cleanExt.removeFirst()
        }
        if cleanExt.isEmpty { cleanExt = "md" }

        var results: [URL] = []
        for (offset, entry) in entries.enumerated() {
            let fileName = exportAllFileName(index: offset + 1, entry: entry, extension: cleanExt)
            let url = directory.appendingPathComponent(fileName)
            results.append(try exportEntry(entry, to: url))
        }
        return results
    }

    /// Mirrors `export_text`: writes raw text (not an entry) to a `.txt`
    /// file, correcting the extension if needed.
    @discardableResult
    public static func exportText(_ text: String, to url: URL) throws -> URL {
        let finalURL: URL
        if url.pathExtension.lowercased() == "txt" {
            finalURL = url
        } else {
            finalURL = url.deletingPathExtension().appendingPathExtension("txt")
        }
        let directory = finalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (rstrip(text) + "\n").write(to: finalURL, atomically: true, encoding: .utf8)
        return finalURL
    }

    // MARK: - String helpers

    private static func rstrip(_ text: String) -> String {
        var view = Substring(text)
        while let last = view.last, last.isWhitespace {
            view.removeLast()
        }
        return String(view)
    }

    // MARK: - JSON primitives (hand-rolled to match Python's json.dumps)

    private static func jsonString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        result += "\""
        return result
    }

    /// Formats a Double the way Python's `json.dumps`/`repr(float)` does:
    /// shortest round-tripping decimal representation, always with a
    /// fractional part (e.g. `3.0`, not `3`). Swift's `Double.description`
    /// already follows the same "shortest round-trip, always a decimal
    /// point" convention for the value ranges this app deals with
    /// (durations and segment timestamps in seconds).
    private static func jsonNumber(_ value: Double) -> String {
        value.description
    }
}
