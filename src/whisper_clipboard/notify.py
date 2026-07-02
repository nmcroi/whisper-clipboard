from __future__ import annotations

import subprocess


APP_TITLE = "Whisper Clipboard"


def notify(message: str) -> None:
    escaped = message.replace("\\", "\\\\").replace('"', '\\"')
    script = f'display notification "{escaped}" with title "{APP_TITLE}"'
    subprocess.run(["osascript", "-e", script], check=False, capture_output=True, text=True)
