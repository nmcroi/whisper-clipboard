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
    /// then optional filler-word removal, then (optionally) cleanup. Mirrors
    /// Python's `process`, extended with the conservative stopword pass.
    ///
    /// Order matters: replacements run against the raw recognizer output first
    /// (so a personal woordenlijst still sees the original tokens), then fillers
    /// are stripped, and finally `cleanText` collapses the whitespace/punctuation
    /// the removals leave behind and re-capitalizes sentence starts.
    public static func process(
        _ text: String,
        replacements: [Replacement] = [],
        clean: Bool = true,
        removeFillers: Bool = false,
        language: String = "nl"
    ) -> String {
        var result = applyReplacements(text, replacements)
        if removeFillers {
            result = self.removeFillers(result, language: language)
        }
        if clean {
            result = cleanText(result)
        }
        return result
    }

    // MARK: - Filler-word removal

    /// The conservative default list of filler words/sounds removed by
    /// ``removeFillers(_:language:)`` when the feature is enabled. Kept
    /// deliberately small and unambiguous: only hesitation sounds and a couple
    /// of clearly-filler discourse markers, so meaningful words are never
    /// dropped.
    ///
    /// - Dutch/shared hesitation sounds: `eh`, `ehm`, `ehh`, `uh`, `uhm`, `uhh`,
    ///   `hm`, `hmm`, `mmm`.
    /// - Dutch discourse fillers (safe, common): `zeg maar`, `weet je wel`.
    /// - Common English hesitation sounds (also heard in Dutch speech): `um`,
    ///   `uhh`, `er`, `err`. `um` is included; the bare English `er`/`err` are
    ///   *only* added for English to avoid clobbering Dutch words.
    ///
    /// Words the list intentionally does NOT contain because they carry meaning
    /// in normal Dutch sentences: `eigenlijk`, `gewoon`, `dus`, `nou`, `ja`,
    /// `weet je` (bare), `nou ja`.
    public static func defaultFillers(language: String) -> [String] {
        // Shared hesitation sounds — safe in any language, never real words.
        var fillers = [
            "eh", "ehm", "ehh", "uh", "uhm", "uhh", "um",
            "hm", "hmm", "mmm",
            // Multi-word Dutch discourse fillers that are unambiguous.
            "zeg maar", "weet je wel",
        ]
        // English-only bare hesitation tokens. `er`/`err` collide with nothing
        // meaningful in English but WOULD be risky in Dutch, so gate them.
        if language.lowercased().hasPrefix("en") {
            fillers.append(contentsOf: ["er", "err", "uhh"])
        }
        return fillers
    }

    /// Removes whole-word, case-insensitive filler tokens from `text` using the
    /// conservative default list for `language`, then repairs the spacing and
    /// punctuation the removals leave behind. Pure and side-effect-free.
    ///
    /// - Multi-word fillers (e.g. "zeg maar") are matched as phrases.
    /// - Only whole-word matches are removed, so "uh" never touches "uhr" or
    ///   words that merely contain the letters.
    /// - After removal, runs of whitespace are collapsed, a space left dangling
    ///   before punctuation is fixed, and stray leading punctuation is dropped,
    ///   so "Dit is eh, een test" → "Dit is een test" and "Dit is eh een test"
    ///   → "Dit is een test". Capitalization/cleanup beyond this is left to
    ///   ``cleanText(_:)`` (called by ``process(_:replacements:clean:removeFillers:language:)``).
    public static func removeFillers(_ text: String, language: String) -> String {
        removeFillers(text, fillers: defaultFillers(language: language))
    }

    /// Filler removal against an explicit list (the testable core). Longer
    /// phrases are removed before shorter ones so multi-word fillers win over a
    /// component word. Returns `text` unchanged when the list is empty.
    public static func removeFillers(_ text: String, fillers: [String]) -> String {
        guard !fillers.isEmpty, !text.isEmpty else { return text }

        var result = text
        // Remove longer (multi-word) fillers first so "weet je wel" is stripped
        // as a unit rather than leaving "wel" behind from a shorter match.
        let ordered = fillers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }

        for filler in ordered {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: filler))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let nsResult = result as NSString
            let range = NSRange(location: 0, length: nsResult.length)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Repair the seams: a filler removed from the middle leaves a double
        // space; one removed before a comma/period leaves " ,". Collapse runs of
        // spaces, drop whitespace before punctuation, and strip any punctuation
        // that a removal orphaned at the very start of the text.
        result = collapseSpaces(result)
        result = replace(pattern: "\\s+([,.!?;:])", in: result, with: "$1")
        // A leading orphaned punctuation mark left by a sentence-initial filler:
        // "eh, dus" → ", dus" → "dus"; "eh. Dit" → ". Dit" → "Dit". Covers the
        // full sentence/clause punctuation set (, ; : . ! ?) so no stray mark
        // survives at the very start of the text.
        result = replace(pattern: "^\\s*[,;:.!?]+\\s*", in: result, with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collapses runs of spaces/tabs to a single space but preserves newlines
    /// (unlike ``collapseWhitespace(_:)``, which flattens everything). Filler
    /// removal must not merge separate lines together.
    private static func collapseSpaces(_ text: String) -> String {
        replace(pattern: "[ \\t]+", in: text, with: " ")
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
