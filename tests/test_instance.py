from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from whisper_clipboard.instance import InstanceLock


class InstanceLockTest(unittest.TestCase):
    def test_only_one_instance_can_hold_lock(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.lock"
            first = InstanceLock(path)
            second = InstanceLock(path)

            self.assertTrue(first.acquire())
            self.assertFalse(second.acquire())
            first.release()
            self.assertTrue(second.acquire())
            second.release()


if __name__ == "__main__":
    unittest.main()
