import Foundation

/// Faithful Swift port of `whisper_clipboard/textproc.py`.
///
/// All regex operations below use `NSRegularExpression` against the
/// `NSString` (UTF-16) view of the text, which matches Python `re`'s
/// scalar-oriented semantics closely enough for the ASCII/Latin-1 text this
/// pipeline is designed for (Dutch transcripts with occasional accented
/// characters, all within the Basic Multilingual Plane).
public enum TextProcessor {

    /// Replace every whole-word, case-insensitive occurrence of `find` with
    /// `replace`, in order. Mirrors Python's
    /// `pattern.sub(lambda _match, value=replace: value, text)` — the
    /// replacement string is inserted literally, so characters like `\1` or
    /// `$1` in `replace` are NOT treated as backreferences.
    public static func applyReplacements(_ text: String, _ replacements: [Replacement]) -> String {
        var result = text
        for replacement in replacements {
            let find = replacement.find.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !find.isEmpty else { continue }

            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: find))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            let nsResult = result as NSString
            let range = NSRange(location: 0, length: nsResult.length)
            // NSRegularExpression treats `\1`, `$1`, etc. in the template as
            // backreferences, so escape any characters the template engine
            // would otherwise interpret, keeping the replacement literal.
            let literalReplace = NSRegularExpression.escapedTemplate(for: replacement.replace)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: literalReplace
            )
        }
        return result
    }

    /// Conservative tidy-up: collapse whitespace, fix spacing around
    /// punctuation, and capitalize sentence starts. Never touches word
    /// spelling. Mirrors Python's `clean_text`.
    public static func cleanText(_ input: String) -> String {
        var text = collapseWhitespace(input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        // No space before , . ! ? ; :
        text = replace(pattern: "\\s+([,.!?;:])", in: text, with: "$1")
        // Exactly one space after those characters, but only when followed
        // by a character that is neither whitespace nor a digit (this is
        // what keeps "1.5" intact).
        text = replace(pattern: "([,.!?;:])(?=[^\\s\\d])", in: text, with: "$1 ")

        text = uppercaseFirstCharacter(text)
        text = uppercaseAfterSentenceEnd(text)
        return text
    }

    /// Runs the full post-transcription text pipeline: replacements first,
    /// then (optionally) cleanup. Mirrors Python's `process`.
    public static func process(
        _ text: String,
        replacements: [Replacement] = [],
        clean: Bool = true
    ) -> String {
        var result = applyReplacements(text, replacements)
        if clean {
            result = cleanText(result)
        }
        return result
    }

    // MARK: - Helpers

    private static func collapseWhitespace(_ text: String) -> String {
        replace(pattern: "\\s+", in: text, with: " ")
    }

    private static func replace(pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static func uppercaseFirstCharacter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    /// Uppercases any character in `[a-zà-öø-ÿ]` that immediately follows a
    /// sentence-ending `.`, `!`, or `?` plus one-or-more whitespace
    /// characters. Mirrors Python's:
    /// `re.sub(r"([.!?]\s+)([a-zà-öø-ÿ])", lambda m: m.group(1) + m.group(2).upper(), text)`
    private static func uppercaseAfterSentenceEnd(_ text: String) -> String {
        // [a-zà-öø-ÿ] in Python (scalar range) covers:
        //   a-z            (U+0061-U+007A)
        //   à-ö            (U+00E0-U+00F6)
        //   ø-ÿ            (U+00F8-U+00FF)
        // Note ÷ (U+00F7) is intentionally excluded.
        let pattern = "([.!?]\\s+)([a-zà-öø-ÿ])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else { return text }

        let mutable = NSMutableString(string: text)
        // Apply replacements back-to-front so earlier ranges stay valid.
        for match in matches.reversed() {
            let letterRange = match.range(at: 2)
            let letter = mutable.substring(with: letterRange)
            mutable.replaceCharacters(in: letterRange, with: letter.uppercased())
        }
        return mutable as String
    }
}
