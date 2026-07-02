from __future__ import annotations

import argparse
import signal
import tempfile
import threading
from datetime import datetime
from pathlib import Path

from .audio import AudioRecorder
from .clipboard import copy_to_clipboard, paste_at_cursor
from .config import AppConfig, load_config
from .exporter import export_all, export_entry
from .history import HistoryEntry, HistoryStore
from .instance import InstanceLock
from .notify import notify
from .preflight import run_preflight
from .status import AppState, Status
from .textproc import process as process_text
from .transcriber import Transcriber


SUPPORTED_MEDIA_SUFFIXES = frozenset({".mp3", ".mp4", ".m4a", ".wav", ".mov"})


class WhisperClipboardApp:
    def __init__(
        self,
        config: AppConfig,
        recorder: AudioRecorder | None = None,
        transcriber: Transcriber | None = None,
        history: HistoryStore | None = None,
    ) -> None:
        self.config = config
        self.recorder = recorder or AudioRecorder(config.sample_rate)
        self.transcriber = transcriber or Transcriber(config)
        self.history = history or HistoryStore(config.history_path, config.history_limit)
        self._lock = threading.Lock()
        self._recording = False
        self._processing = False
        self._stopped = False
        self._status = Status(AppState.STARTING, "Whisper Clipboard start...")
        self._status_callback = None
        self._history_callback = None
        self._preflight = None

    @property
    def status(self) -> Status:
        return self._status

    @property
    def stopped(self) -> bool:
        with self._lock:
            return self._stopped

    def set_status_callback(self, callback) -> None:  # noqa: ANN001
        self._status_callback = callback

    def set_history_callback(self, callback) -> None:  # noqa: ANN001
        self._history_callback = callback

    @property
    def history_entries(self) -> list[HistoryEntry]:
        return self.history.entries

    def copy_history_entry(self, entry_id: str) -> bool:
        entry = self._history_entry(entry_id)
        if entry is None:
            return False
        copy_to_clipboard(entry.text)
        notify("Transcriptie opnieuw gekopieerd")
        self._set_status(AppState.READY, "Transcriptie staat op klembord")
        return True

    def export_history_entry(self, entry_id: str, output_path: Path) -> Path | None:
        entry = self._history_entry(entry_id)
        if entry is None:
            return None
        saved_path = export_entry(entry, output_path)
        notify("Transcriptie bewaard")
        return saved_path

    def export_all_history(self, directory: Path, extension: str = "md") -> list[Path]:
        saved = export_all(self.history.entries, directory, extension)
        if saved:
            notify(f"{len(saved)} transcripties geexporteerd")
        return saved

    def import_media(self, media_path: Path) -> bool:
        path = Path(media_path).expanduser()
        if not path.is_file():
            self._handle_error("Het gekozen audio- of videobestand bestaat niet meer.")
            return False
        if path.suffix.lower() not in SUPPORTED_MEDIA_SUFFIXES:
            self._handle_error("Kies een mp3-, mp4-, m4a-, wav- of mov-bestand.")
            return False

        with self._lock:
            if self._stopped or self._recording or self._processing:
                notify("Wacht tot de huidige opname of transcriptie klaar is")
                return False
            if self._status.state == AppState.LOADING_MODEL:
                notify("Whisper-model wordt nog geladen")
                return False
            self._processing = True

        self._set_status(AppState.TRANSCRIBING, f"Bestand transcriberen: {path.name}")
        threading.Thread(
            target=self._transcribe_media,
            args=(path,),
            daemon=True,
        ).start()
        return True

    def rename_history_entry(self, entry_id: str, name: str) -> bool:
        if self.history.rename(entry_id, name) is None:
            return False
        self._notify_history_changed()
        return True

    def delete_history_entry(self, entry_id: str) -> bool:
        if not self.history.remove(entry_id):
            return False
        self._notify_history_changed()
        return True

    def set_history_entry_pinned(self, entry_id: str, pinned: bool) -> bool:
        if self.history.set_pinned(entry_id, pinned) is None:
            return False
        self._notify_history_changed()
        return True

    def clear_history(self) -> None:
        self.history.clear()
        self._notify_history_changed()

    def start(self) -> None:
        report = run_preflight()
        self._preflight = report
        if report.input_device is None:
            print("No microphone is visible yet. Starting a recording may trigger permission.", flush=True)

        if self.config.preload_model:
            self._set_status(AppState.LOADING_MODEL, "Whisper-model laden...")
            threading.Thread(target=self._prepare_model, daemon=True).start()
        else:
            self._set_status(AppState.READY, self._ready_message())

    def toggle_recording(self) -> None:
        should_stop = False
        with self._lock:
            if self._stopped:
                return
            if self._recording:
                self._recording = False
                self._processing = True
                should_stop = True
            elif self._processing:
                print("Still transcribing. Please wait.", flush=True)
                return
            if self._status.state == AppState.LOADING_MODEL:
                print("The Whisper model is still loading.", flush=True)
                notify("Whisper-model wordt nog geladen")
                return
            if not should_stop:
                self._recording = True

        if should_stop:
            self._set_status(AppState.TRANSCRIBING, "Opname stoppen...")
            threading.Thread(target=self._stop_and_transcribe, daemon=True).start()
            return

        try:
            self.recorder.start()
        except Exception as exc:
            with self._lock:
                self._recording = False
            self._handle_error(f"Microfoon kon niet starten: {exc}")
            return

        self._set_status(AppState.RECORDING, "Opname loopt")
        print("Recording started. Press the hotkey again to stop.", flush=True)
        notify("Opname gestart")

    def _stop_and_transcribe(self) -> None:
        wav_path: Path | None = None
        try:
            wav_path = self._next_recording_path()
            duration = self.recorder.stop_to_wav(wav_path)
            self._set_status(AppState.TRANSCRIBING, "Transcriptie maken...")
            print(f"Recording stopped after {duration:.1f}s. Transcribing...", flush=True)
            notify("Opname gestopt, transcriberen")

            text, segments = self._transcribe(wav_path)
            self._complete_transcription(
                text, segments, "Tekst staat op klembord", source="mic", duration=duration
            )
        except Exception as exc:
            self._handle_error(str(exc))
        finally:
            if wav_path and not self.config.save_recordings:
                wav_path.unlink(missing_ok=True)
            with self._lock:
                self._processing = False

    def _transcribe_media(self, media_path: Path) -> None:
        try:
            text, segments = self._transcribe(media_path)
            self._complete_transcription(
                text,
                segments,
                f"{media_path.name} is getranscribeerd en gekopieerd",
                source="file",
            )
        except Exception as exc:
            self._handle_error(f"Bestand kon niet worden getranscribeerd: {exc}")
        finally:
            with self._lock:
                self._processing = False

    def _transcribe(self, path: Path):
        segmenter = getattr(self.transcriber, "transcribe_segments", None)
        if segmenter is not None:
            segments = segmenter(path)
            text = " ".join(" ".join(seg.text.split()) for seg in segments).strip()
            return text, segments
        return self.transcriber.transcribe(path), []

    def _complete_transcription(
        self,
        text: str,
        segments,
        success_message: str,
        *,
        source: str = "mic",
        duration: float = 0.0,
    ) -> bool:
        if not text:
            print("No speech detected.", flush=True)
            notify("Geen spraak herkend")
            self._set_status(AppState.READY, "Geen spraak herkend")
            return False

        cleaned = process_text(text, self.config.replacements, self.config.clean_output)
        segment_dicts = [
            {"start": seg.start, "end": seg.end, "text": seg.text} for seg in segments
        ]
        self.history.add(
            cleaned,
            language=self.config.language or "",
            model=self.config.model,
            source=source,
            duration=duration,
            segments=segment_dicts,
        )
        self._notify_history_changed()
        copy_to_clipboard(cleaned)
        if self.config.save_transcripts:
            self._save_transcript(cleaned)
        if self.config.paste_after_copy:
            paste_at_cursor()
        print(f"Copied to clipboard: {cleaned}", flush=True)
        notify("Tekst staat op je klembord")
        self._set_status(AppState.READY, success_message)
        return True

    def _history_entry(self, entry_id: str) -> HistoryEntry | None:
        return next(
            (item for item in self.history.entries if item.id == entry_id),
            None,
        )

    def _prepare_model(self) -> None:
        try:
            self.transcriber.prepare()
            self._set_status(AppState.READY, self._ready_message())
            print("Whisper model is ready.", flush=True)
        except Exception as exc:
            self._handle_error(f"Model kon niet laden: {exc}")

    def _handle_error(self, message: str) -> None:
        print(f"Error: {message}", flush=True)
        notify(message[:120])
        self._set_status(AppState.ERROR, message)

    def _set_status(self, state: AppState, message: str) -> None:
        status = Status(state, message)
        self._status = status
        if self._status_callback is not None:
            self._status_callback(status)

    def _notify_history_changed(self) -> None:
        if self._history_callback is not None:
            self._history_callback(self.history.entries)

    def stop(self) -> None:
        with self._lock:
            self._stopped = True
            was_recording = self._recording
            self._recording = False
        if was_recording:
            self.recorder.cancel()

    def _ready_message(self) -> str:
        if self._preflight is None:
            return "Klaar voor opname"
        if self._preflight.input_device is None:
            return "Microfoontoegang nodig"
        return f"Klaar - {self._preflight.input_device}"

    def _next_recording_path(self) -> Path:
        if self.config.save_recordings:
            timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
            return self.config.recordings_path / f"recording-{timestamp}.wav"

        temp_file = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
        temp_file.close()
        return Path(temp_file.name)

    def _save_transcript(self, text: str) -> None:
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        self.config.transcripts_path.mkdir(parents=True, exist_ok=True)
        transcript_path = self.config.transcripts_path / f"transcript-{timestamp}.txt"
        transcript_path.write_text(text + "\n", encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Local hotkey transcription to clipboard.")
    parser.add_argument(
        "--prepare-model",
        action="store_true",
        help="Download and load the configured model, then exit.",
    )
    parser.add_argument(
        "--no-menu-bar",
        action="store_true",
        help="Run as a terminal-only process.",
    )
    parser.add_argument(
        "--show-window",
        action="store_true",
        help="Open the main window and show the app in the Dock.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    config = load_config()

    if args.prepare_model:
        print(f"Preparing Whisper model: {config.model}", flush=True)
        Transcriber(config).prepare()
        print("Model is ready.", flush=True)
        return

    instance_lock = InstanceLock(
        Path.home() / "Library" / "Application Support" / "Whisper Clipboard" / "app.lock"
    )
    if not instance_lock.acquire():
        print("Whisper Clipboard is already running.", flush=True)
        return

    app = WhisperClipboardApp(config)
    app._instance_lock = instance_lock

    print("Whisper Clipboard is running.", flush=True)
    print(f"Hotkey: {config.hotkey}", flush=True)
    print(f"Engine: {config.engine}", flush=True)
    print("Press Ctrl+C in this terminal to quit.", flush=True)

    app.start()

    if not args.no_menu_bar:
        from .menubar import run_menu_bar

        run_menu_bar(app, show_window=args.show_window)
        return

    stop_event = threading.Event()

    def stop(_signum, _frame) -> None:  # noqa: ANN001
        app.stop()
        stop_event.set()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    stop_event.wait()
    print("Stopped.", flush=True)


if __name__ == "__main__":
    main()
