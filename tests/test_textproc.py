from __future__ import annotations

import unittest

from whisper_clipboard.textproc import apply_replacements, clean_text, process


class TextProcTest(unittest.TestCase):
    def test_replacements_are_whole_word_and_case_insensitive(self) -> None:
        text = "Ik gebruik VPS en vps, maar niet vpsx."
        result = apply_replacements(text, [("vps", "server")])
        self.assertEqual(result, "Ik gebruik server en server, maar niet vpsx.")

    def test_replacement_skips_empty_find(self) -> None:
        self.assertEqual(apply_replacements("blijft", [("", "x")]), "blijft")

    def test_clean_collapses_whitespace_and_capitalizes_sentences(self) -> None:
        text = "  hallo   wereld .  dit is  een test.nieuwe zin "
        result = clean_text(text)
        self.assertEqual(result, "Hallo wereld. Dit is een test. Nieuwe zin")

    def test_clean_keeps_empty_empty(self) -> None:
        self.assertEqual(clean_text("    "), "")

    def test_process_applies_replacements_then_cleanup(self) -> None:
        result = process("de klant heet  noornano .", [("noornano", "Noornano")], clean=True)
        self.assertEqual(result, "De klant heet Noornano.")

    def test_process_can_skip_cleanup(self) -> None:
        self.assertEqual(process("rauw   blijft", clean=False), "rauw   blijft")


if __name__ == "__main__":
    unittest.main()
