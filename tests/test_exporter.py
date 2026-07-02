from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from whisper_clipboard.exporter import (
    export_all,
    export_entry,
    export_text,
    suggested_export_name,
    to_json,
    to_markdown,
    to_srt,
    to_vtt,
)
from whisper_clipboard.history import HistoryEntry


def _entry_with_segments() -> HistoryEntry:
    return HistoryEntry(
        id="1",
        text="Hallo wereld",
        created_at="2026-06-20T22:42:00+02:00",
        name="Klantgesprek",
        segments=(
            {"start": 0.0, "end": 1.5, "text": "Hallo"},
            {"start": 1.5, "end": 3.0, "text": "wereld"},
        ),
    )


class ExporterTest(unittest.TestCase):
    def test_exports_utf8_text_and_adds_txt_suffix(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = export_text("Een Nederlandse transcriptie.", Path(directory) / "uitvoer")

            self.assertEqual(path.suffix, ".txt")
            self.assertEqual(path.read_text(encoding="utf-8"), "Een Nederlandse transcriptie.\n")

    def test_suggested_name_uses_transcription_timestamp(self) -> None:
        entry = HistoryEntry(
            id="1",
            text="Tekst",
            created_at="2026-06-20T22:42:00+02:00",
        )

        self.assertEqual(
            suggested_export_name(entry),
            "transcriptie-2026-06-20-2242.txt",
        )

    def test_suggested_name_uses_name_and_extension(self) -> None:
        entry = _entry_with_segments()
        self.assertEqual(suggested_export_name(entry, "srt"), "Klantgesprek.srt")

    def test_srt_export_has_numbered_cues_and_timecodes(self) -> None:
        srt = to_srt(_entry_with_segments())
        self.assertIn("00:00:00,000 --> 00:00:01,500", srt)
        self.assertIn("Hallo", srt)
        self.assertTrue(srt.startswith("1\n"))

    def test_vtt_export_starts_with_header(self) -> None:
        vtt = to_vtt(_entry_with_segments())
        self.assertTrue(vtt.startswith("WEBVTT"))
        self.assertIn("00:00:01.500 --> 00:00:03.000", vtt)

    def test_markdown_and_json_export(self) -> None:
        entry = _entry_with_segments()
        self.assertIn("# Klantgesprek", to_markdown(entry))
        self.assertIn('"text": "Hallo wereld"', to_json(entry))

    def test_export_entry_picks_writer_by_suffix(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = export_entry(_entry_with_segments(), Path(directory) / "out.srt")
            self.assertEqual(path.suffix, ".srt")
            self.assertIn("-->", path.read_text(encoding="utf-8"))

    def test_export_all_writes_one_file_per_entry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            entries = [_entry_with_segments(), _entry_with_segments()]
            paths = export_all(entries, Path(directory) / "bundel", "md")
            self.assertEqual(len(paths), 2)
            self.assertTrue(all(p.exists() and p.suffix == ".md" for p in paths))


if __name__ == "__main__":
    unittest.main()
