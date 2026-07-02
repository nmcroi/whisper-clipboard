from __future__ import annotations

import subprocess


def copy_to_clipboard(text: str) -> None:
    try:
        import pyperclip

        pyperclip.copy(text)
    except Exception:
        subprocess.run(["pbcopy"], input=text, text=True, check=True)


def paste_at_cursor() -> None:
    script = 'tell application "System Events" to keystroke "v" using command down'
    subprocess.run(["osascript", "-e", script], check=False, capture_output=True, text=True)
