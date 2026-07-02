from __future__ import annotations

import tempfile
import unittest
import wave
from pathlib import Path

import numpy as np

from whisper_clipboard.config import AppConfig
from whisper_clipboard.transcriber import (
    FasterWhisperTranscriber,
    MlxWhisperTranscriber,
    Transcriber,
    load_audio_array,
)


class TranscriberDispatchTest(unittest.TestCase):
    def test_mlx_engine_is_selected(self) -> None:
        transcriber = Transcriber(AppConfig(engine="mlx_whisper"))
        self.assertIsInstance(transcriber.backend, MlxWhisperTranscriber)

    def test_engine_name_is_case_and_dash_insensitive(self) -> None:
        transcriber = Transcriber(AppConfig(engine="MLX"))
        self.assertIsInstance(transcriber.backend, MlxWhisperTranscriber)

    def test_faster_whisper_still_available(self) -> None:
        transcriber = Transcriber(AppConfig(engine="faster_whisper"))
        self.assertIsInstance(transcriber.backend, FasterWhisperTranscriber)

    def test_unknown_engine_raises(self) -> None:
        with self.assertRaises(RuntimeError):
            Transcriber(AppConfig(engine="banana"))


class LoadAudioTest(unittest.TestCase):
    def test_reads_16k_mono_wav_as_normalized_float32(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "clip.wav"
            samples = np.array([0, 16384, -16384, 32767], dtype=np.int16)
            with wave.open(str(path), "wb") as wav_file:
                wav_file.setnchannels(1)
                wav_file.setsampwidth(2)
                wav_file.setframerate(16000)
                wav_file.writeframes(samples.tobytes())

            audio = load_audio_array(path, 16000)
            self.assertEqual(audio.dtype, np.float32)
            self.assertEqual(len(audio), 4)
            self.assertAlmostEqual(float(audio[1]), 16384 / 32768.0, places=5)


if __name__ == "__main__":
    unittest.main()
