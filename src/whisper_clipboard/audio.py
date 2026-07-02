from __future__ import annotations

import threading
import time
import wave
from pathlib import Path

import sounddevice as sd


class AudioRecorder:
    def __init__(self, sample_rate: int) -> None:
        self.sample_rate = sample_rate
        self._frames: list[bytes] = []
        self._lock = threading.Lock()
        self._stream: sd.InputStream | None = None
        self.started_at = 0.0

    def start(self) -> None:
        with self._lock:
            self._frames = []
            self.started_at = time.monotonic()

        self._stream = sd.InputStream(
            samplerate=self.sample_rate,
            channels=1,
            dtype="int16",
            callback=self._on_audio,
        )
        self._stream.start()

    def stop_to_wav(self, output_path: Path) -> float:
        if self._stream is None:
            raise RuntimeError("Recorder was not started.")

        stream = self._stream
        self._stream = None
        try:
            stream.abort()
        finally:
            stream.close()

        with self._lock:
            frames = list(self._frames)
            duration = time.monotonic() - self.started_at

        if not frames:
            raise RuntimeError("No audio was recorded.")

        output_path.parent.mkdir(parents=True, exist_ok=True)
        with wave.open(str(output_path), "wb") as wav_file:
            wav_file.setnchannels(1)
            wav_file.setsampwidth(2)
            wav_file.setframerate(self.sample_rate)
            wav_file.writeframes(b"".join(frames))

        return duration

    def cancel(self) -> None:
        if self._stream is None:
            return

        stream = self._stream
        self._stream = None
        try:
            stream.abort()
        finally:
            stream.close()
        with self._lock:
            self._frames = []

    def _on_audio(self, indata, frames, time_info, status) -> None:  # noqa: ANN001
        if status:
            print(f"Audio warning: {status}", flush=True)

        with self._lock:
            self._frames.append(indata.copy().tobytes())
