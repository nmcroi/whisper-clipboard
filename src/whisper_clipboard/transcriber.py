from __future__ import annotations

import subprocess
import tempfile
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

import numpy as np
from faster_whisper import WhisperModel

from .config import AppConfig


@dataclass(frozen=True)
class TranscriptSegment:
    start: float
    end: float
    text: str


def load_audio_array(path: Path, sample_rate: int = 16000) -> np.ndarray:
    """Decode any supported media to mono float32 at ``sample_rate``.

    Microphone recordings are already 16 kHz mono int16 WAV, so they are read
    directly. Everything else is decoded and resampled via PyAV, which means we
    never depend on a system ffmpeg binary."""
    path = Path(path)
    if path.suffix.lower() == ".wav":
        try:
            with wave.open(str(path), "rb") as wav_file:
                if (
                    wav_file.getnchannels() == 1
                    and wav_file.getframerate() == sample_rate
                    and wav_file.getsampwidth() == 2
                ):
                    raw = wav_file.readframes(wav_file.getnframes())
                    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
        except (OSError, wave.Error):
            pass
    return _decode_via_av(path, sample_rate)


def _decode_via_av(path: Path, sample_rate: int) -> np.ndarray:
    import av

    container = av.open(str(path))
    resampler = av.audio.resampler.AudioResampler(
        format="s16", layout="mono", rate=sample_rate
    )
    chunks: list[np.ndarray] = []
    try:
        for frame in container.decode(audio=0):
            for resampled in resampler.resample(frame):
                chunks.append(resampled.to_ndarray().reshape(-1))
        for resampled in resampler.resample(None):
            chunks.append(resampled.to_ndarray().reshape(-1))
    finally:
        container.close()

    if not chunks:
        return np.zeros(0, dtype=np.float32)
    return np.concatenate(chunks).astype(np.float32) / 32768.0


class TranscriptionBackend(Protocol):
    def prepare(self) -> None:
        pass

    def transcribe(self, wav_path: Path) -> str:
        pass


class FasterWhisperTranscriber:
    def __init__(self, config: AppConfig) -> None:
        self.config = config
        self._model: WhisperModel | None = None

    @property
    def model(self) -> WhisperModel:
        if self._model is None:
            print(f"Loading Whisper model: {self.config.model}", flush=True)
            self._model = WhisperModel(
                self.config.model,
                device=self.config.device,
                compute_type=self.config.compute_type,
                download_root=str(self.config.models_path),
            )
        return self._model

    def _run(self, wav_path: Path):
        return self.model.transcribe(
            str(wav_path),
            language=self.config.language,
            task=self.config.task,
            vad_filter=self.config.vad_filter,
            beam_size=self.config.beam_size,
            initial_prompt=self.config.initial_prompt or None,
        )

    def transcribe(self, wav_path: Path) -> str:
        segments, _info = self._run(wav_path)
        text = " ".join(segment.text.strip() for segment in segments)
        return " ".join(text.split())

    def transcribe_segments(self, wav_path: Path) -> list[TranscriptSegment]:
        segments, _info = self._run(wav_path)
        return [
            TranscriptSegment(
                start=float(segment.start),
                end=float(segment.end),
                text=" ".join(segment.text.split()),
            )
            for segment in segments
        ]

    def prepare(self) -> None:
        self.model


class WhisperCppTranscriber:
    def __init__(self, config: AppConfig) -> None:
        self.config = config

    def transcribe(self, wav_path: Path) -> str:
        model_path = self.config.whisper_cpp_model
        if model_path is None:
            raise RuntimeError("whisper_cpp_model_path is required when engine is whisper_cpp.")
        if not model_path.exists():
            raise RuntimeError(f"Whisper.cpp model not found: {model_path}")

        with tempfile.TemporaryDirectory() as temp_dir:
            output_base = Path(temp_dir) / "transcript"
            command = [
                self.config.whisper_cpp_binary,
                "-m",
                str(model_path),
                "-f",
                str(wav_path),
                "-otxt",
                "-of",
                str(output_base),
            ]
            if self.config.language:
                command.extend(["-l", self.config.language])
            if self.config.task == "translate":
                command.append("-tr")
            if self.config.initial_prompt:
                command.extend(["--prompt", self.config.initial_prompt])

            result = subprocess.run(command, capture_output=True, text=True, check=False)
            if result.returncode != 0:
                details = result.stderr.strip() or result.stdout.strip()
                raise RuntimeError(f"whisper.cpp failed: {details}")

            output_path = output_base.with_suffix(".txt")
            text = output_path.read_text(encoding="utf-8") if output_path.exists() else result.stdout
            return " ".join(text.split())

    def prepare(self) -> None:
        model_path = self.config.whisper_cpp_model
        if model_path is None or not model_path.exists():
            raise RuntimeError("Configure a valid whisper_cpp_model_path first.")


class MlxWhisperTranscriber:
    """Apple-Silicon GPU backend via MLX. Same Whisper weights, much faster."""

    def __init__(self, config: AppConfig) -> None:
        self.config = config

    def _model_ref(self) -> str:
        model_path = self.config.mlx_model
        if model_path is None:
            raise RuntimeError("mlx_model_path is required when engine is mlx_whisper.")
        if not model_path.exists():
            raise RuntimeError(f"MLX model not found: {model_path}")
        return str(model_path)

    def _options(self) -> dict:
        options: dict = {"task": self.config.task}
        if self.config.language:
            options["language"] = self.config.language
        if self.config.initial_prompt:
            options["initial_prompt"] = self.config.initial_prompt
        return options

    def _run(self, path: Path) -> dict:
        import mlx_whisper

        audio = load_audio_array(path, self.config.sample_rate)
        if audio.size == 0:
            return {"text": "", "segments": []}
        return mlx_whisper.transcribe(
            audio, path_or_hf_repo=self._model_ref(), **self._options()
        )

    def transcribe(self, wav_path: Path) -> str:
        return " ".join(self._run(wav_path).get("text", "").split())

    def transcribe_segments(self, wav_path: Path) -> list[TranscriptSegment]:
        segments = []
        for raw in self._run(wav_path).get("segments", []):
            text = " ".join(str(raw.get("text", "")).split())
            if text:
                segments.append(
                    TranscriptSegment(
                        start=float(raw.get("start", 0.0)),
                        end=float(raw.get("end", 0.0)),
                        text=text,
                    )
                )
        return segments

    def prepare(self) -> None:
        from mlx_whisper.load_models import load_model

        load_model(self._model_ref())


class Transcriber:
    def __init__(self, config: AppConfig) -> None:
        engine = config.engine.replace("-", "_").lower()
        if engine == "faster_whisper":
            self.backend: TranscriptionBackend = FasterWhisperTranscriber(config)
        elif engine == "whisper_cpp":
            self.backend = WhisperCppTranscriber(config)
        elif engine in ("mlx_whisper", "mlx"):
            self.backend = MlxWhisperTranscriber(config)
        else:
            raise RuntimeError(f"Unknown transcription engine: {config.engine}")

    def transcribe(self, wav_path: Path) -> str:
        return self.backend.transcribe(wav_path)

    def transcribe_segments(self, wav_path: Path) -> list[TranscriptSegment]:
        segmenter = getattr(self.backend, "transcribe_segments", None)
        if segmenter is not None:
            return segmenter(wav_path)
        text = self.backend.transcribe(wav_path)
        return [TranscriptSegment(start=0.0, end=0.0, text=text)] if text else []

    def prepare(self) -> None:
        self.backend.prepare()
