import Foundation

/// Maps a transcript's `source` string to an SF Symbol and a Dutch label for the
/// history UI. Centralizes the mic / file / captions / plaud distinction.
enum TranscriptSourceStyle {
    static func icon(for source: String) -> String {
        switch source {
        case "file": return "doc.text"
        case "captions": return "captions.bubble"
        case "plaud": return "recordingtape"
        default: return "mic"
        }
    }

    static func label(for source: String) -> String {
        switch source {
        case "file": return "Bestand"
        case "captions": return "Ondertitels"
        case "plaud": return "PLAUD"
        default: return "Microfoon"
        }
    }
}
