import Foundation

/// Maps a transcript's `source` string to an SF Symbol and a Dutch label for the
/// history UI. Centralizes the mic / file / captions / plaud distinction.
public enum TranscriptSourceStyle {
    public static func icon(for source: String) -> String {
        switch baseSource(source) {
        case "file": return "doc.text"
        case "captions": return "captions.bubble"
        case "plaud": return "recordingtape"
        case "meeting": return "person.2.wave.2"
        default:
            // De iPhone schrijft "mic.ios", de Mac "mic". Dat onderscheid stond
            // al in de gegevens maar was niet te zien in de lijst
            // (wens Niels, 2026-08-02).
            return source.hasSuffix(".ios") ? "iphone" : "laptopcomputer"
        }
    }

    public static func label(for source: String) -> String {
        switch baseSource(source) {
        case "file": return "Bestand"
        case "captions": return "Ondertitels"
        case "plaud": return "PLAUD"
        case "meeting": return "Notulen"
        default: return "Microfoon"
        }
    }

    public static func device(for source: String) -> String? {
        if source.hasSuffix(".mac") { return "Mac" }
        if source.hasSuffix(".ios") { return "iPhone" }
        return nil
    }

    private static func baseSource(_ source: String) -> String {
        String(source.split(separator: ".").first ?? Substring(source))
    }
}
