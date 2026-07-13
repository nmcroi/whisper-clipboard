import Foundation

/// Maps a transcript's `source` string to an SF Symbol and a Dutch label for the
/// history UI. Centralizes the mic / file / captions / plaud distinction.
public enum TranscriptSourceStyle {
    public static func icon(for source: String) -> String {
        switch source {
        case "file": return "doc.text"
        case "captions": return "captions.bubble"
        case "plaud": return "recordingtape"
        case "meeting": return "person.2.wave.2"
        default: return "mic"
        }
    }

    public static func label(for source: String) -> String {
        switch source {
        case "file": return "Bestand"
        case "captions": return "Ondertitels"
        case "plaud": return "PLAUD"
        case "meeting": return "Notulen"
        default: return "Microfoon"
        }
    }
}
