from __future__ import annotations

import unittest

from AppKit import NSApplication

from whisper_clipboard.hotkey import (
    COMMAND_KEY,
    CONTROL_KEY,
    SHIFT_KEY,
    GlobalHotKey,
    display_hotkey,
    parse_hotkey,
)


class HotKeyTest(unittest.TestCase):
    def test_parses_default_shortcut(self) -> None:
        parsed = parse_hotkey("<ctrl>+<space>")
        self.assertEqual(parsed.key_code, 49)
        self.assertEqual(parsed.modifiers, CONTROL_KEY)
        self.assertEqual(display_hotkey("<ctrl>+<space>"), "Control + spatie")

    def test_combines_multiple_modifiers(self) -> None:
        parsed = parse_hotkey("<cmd>+<shift>+r")
        self.assertEqual(parsed.key_code, 15)
        self.assertEqual(parsed.modifiers, COMMAND_KEY | SHIFT_KEY)

    def test_rejects_unsupported_key(self) -> None:
        with self.assertRaisesRegex(ValueError, "Unsupported hotkey key"):
            parse_hotkey("<ctrl>+f20")

    def test_registers_without_accessibility_permission(self) -> None:
        NSApplication.sharedApplication()
        hotkey = GlobalHotKey("<ctrl>+<option>+<shift>+9", lambda: None)
        try:
            hotkey.register()
            self.assertTrue(hotkey.registered)
        finally:
            hotkey.unregister()
        self.assertFalse(hotkey.registered)


if __name__ == "__main__":
    unittest.main()
