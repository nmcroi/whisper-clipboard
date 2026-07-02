from __future__ import annotations

import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from whisper_clipboard.__main__ import WhisperClipboardApp
from whisper_clipboard.config import AppConfig
from whisper_clipboard.history import HistoryStore
from whisper_clipboard.status import AppState


class FakeRecorder:
    def __init__(self) -> None:
        self.started = False

    def start(self) -> None:
        self.started = True

    def stop_to_wav(self, output_path: Path) -> float:
        self.started = False
        output_path.write_bytes(b"test audio")
        return 1.25

    def cancel(self) -> None:
        self.started = False


class FakeTranscriber:
    def __init__(self, text: str) -> None:
        self.text = text
        self.paths: list[Path] = []

    def prepare(self) -> None:
        pass

    def transcribe(self, wav_path: Path) -> str:
        self.paths.append(wav_path)
        return self.text


class WorkflowTest(unittest.TestCase):
    def test_record_transcribe_copy_and_store(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            history = HistoryStore(Path(directory) / "history.json")
            recorder = FakeRecorder()
            app = WhisperClipboardApp(
                AppConfig(preload_model=False),
                recorder=recorder,
                transcriber=FakeTranscriber("Dit is de transcriptie."),
                history=history,
            )

            with (
                patch("whisper_clipboard.__main__.notify"),
                patch("whisper_clipboard.__main__.copy_to_clipboard") as copy,
            ):
                app.toggle_recording()
                self.assertEqual(app.status.state, AppState.RECORDING)
                self.assertTrue(recorder.started)

                app.toggle_recording()
                self._wait_until_ready(app)

            copy.assert_called_once_with("Dit is de transcriptie.")
            self.assertEqual(
                [entry.text for entry in history.entries],
                ["Dit is de transcriptie."],
            )

    def test_no_speech_does_not_change_history_or_clipboard(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            history = HistoryStore(Path(directory) / "history.json")
            app = WhisperClipboardApp(
                AppConfig(preload_model=False),
                recorder=FakeRecorder(),
                transcriber=FakeTranscriber(""),
                history=history,
            )

            with (
                patch("whisper_clipboard.__main__.notify"),
                patch("whisper_clipboard.__main__.copy_to_clipboard") as copy,
            ):
                app.toggle_recording()
                app.toggle_recording()
                self._wait_until_ready(app)

            copy.assert_not_called()
            self.assertEqual(history.entries, [])

    def test_active_recording_can_stop_even_with_stale_processing_flag(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = WhisperClipboardApp(
                AppConfig(preload_model=False),
                recorder=FakeRecorder(),
                transcriber=FakeTranscriber("Hersteld."),
                history=HistoryStore(Path(directory) / "history.json"),
            )
            app._recording = True
            app._processing = True

            with (
                patch("whisper_clipboard.__main__.notify"),
                patch("whisper_clipboard.__main__.copy_to_clipboard"),
            ):
                app.toggle_recording()
                self.assertEqual(app.status.state, AppState.TRANSCRIBING)
                self._wait_until_ready(app)

    def test_imported_media_is_transcribed_copied_and_stored(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            media_path = Path(directory) / "gesprek.MP4"
            media_path.write_bytes(b"fake video")
            history = HistoryStore(Path(directory) / "history.json")
            transcriber = FakeTranscriber("Transcriptie uit de video.")
            app = WhisperClipboardApp(
                AppConfig(preload_model=False),
                recorder=FakeRecorder(),
                transcriber=transcriber,
                history=history,
            )

            with (
                patch("whisper_clipboard.__main__.notify"),
                patch("whisper_clipboard.__main__.copy_to_clipboard") as copy,
            ):
                self.assertTrue(app.import_media(media_path))
                self._wait_until_ready(app)

            self.assertEqual(transcriber.paths, [media_path])
            copy.assert_called_once_with("Transcriptie uit de video.")
            self.assertEqual(history.entries[0].text, "Transcriptie uit de video.")

    def test_export_history_entry_writes_selected_transcript(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            history = HistoryStore(Path(directory) / "history.json")
            entry = history.add("Bewaar deze tekst.")
            app = WhisperClipboardApp(
                AppConfig(preload_model=False),
                recorder=FakeRecorder(),
                transcriber=FakeTranscriber(""),
                history=history,
            )

            with patch("whisper_clipboard.__main__.notify"):
                saved_path = app.export_history_entry(
                    entry.id,
                    Path(directory) / "mijn-transcriptie",
                )

            self.assertIsNotNone(saved_path)
            self.assertEqual(
                saved_path.read_text(encoding="utf-8"),
                "Bewaar deze tekst.\n",
            )

    def _wait_until_ready(self, app: WhisperClipboardApp) -> None:
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if app.status.state == AppState.READY:
                return
            time.sleep(0.01)
        self.fail(f"App did not become ready; status={app.status}")


if __name__ == "__main__":
    unittest.main()
