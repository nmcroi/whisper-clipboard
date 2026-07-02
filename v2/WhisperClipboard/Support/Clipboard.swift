import AppKit

/// Thin wrapper over `NSPasteboard` for writing transcription text.
enum Clipboard {
    /// Replaces the general pasteboard contents with `text`.
    @discardableResult
    static func copy(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
