from __future__ import annotations

import tempfile
import time
import unittest
from pathlib import Path

from whisper_clipboard.audio import AudioRecorder


class FakeStream:
    def __init__(self) -> None:
        self.aborted = False
        self.closed = False

    def abort(self) -> None:
        self.aborted = True

    def close(self) -> None:
        self.closed = True


class AudioRecorderTest(unittest.TestCase):
    def test_stop_aborts_stream_without_waiting_for_graceful_stop(self) -> None:
        recorder = AudioRecorder(16000)
        stream = FakeStream()
        recorder._stream = stream
        recorder._frames = [b"\x00\x00" * 160]
        recorder.started_at = time.monotonic() - 0.1

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "recording.wav"
            duration = recorder.stop_to_wav(output)

        self.assertTrue(stream.aborted)
        self.assertTrue(stream.closed)
        self.assertGreater(duration, 0)


if __name__ == "__main__":
    unittest.main()
