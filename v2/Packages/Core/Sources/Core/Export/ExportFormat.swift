import Foundation

/// The set of export formats supported by `exporter.py`'s `_WRITERS` table.
public enum ExportFormat: String, CaseIterable, Sendable {
    case txt
    case markdown = "md"
    case json
    case srt
    case vtt

    /// The canonical file extension (without a leading dot) used when
    /// naming exported files.
    public var fileExtension: String {
        rawValue
    }

    /// Resolve a format from a file extension or suffix, case-insensitively.
    /// Accepts both a bare extension ("md") and a dotted suffix (".md"),
    /// and treats ".markdown" as an alias for `.markdown`, mirroring the
    /// Python `_WRITERS` dict which maps both ".md" and ".markdown" to
    /// `to_markdown`. Returns `nil` for anything unrecognized (callers
    /// should fall back to `.txt`, matching `export_entry`'s behavior).
    public init?(suffix: String) {
        var normalized = suffix.lowercased()
        if normalized.hasPrefix(".") {
            normalized.removeFirst()
        }
        switch normalized {
        case "txt":
            self = .txt
        case "md", "markdown":
            self = .markdown
        case "json":
            self = .json
        case "srt":
            self = .srt
        case "vtt":
            self = .vtt
        default:
            return nil
        }
    }
}
