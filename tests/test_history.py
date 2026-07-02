from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from whisper_clipboard.history import HistoryEntry, HistoryStore, search_entries


class HistoryStoreTest(unittest.TestCase):
    def test_keeps_newest_entries_up_to_limit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "history.json"
            store = HistoryStore(path, limit=3)

            for number in range(5):
                store.add(f"Transcriptie {number}")

            self.assertEqual(
                [entry.text for entry in store.entries],
                ["Transcriptie 4", "Transcriptie 3", "Transcriptie 2"],
            )
            self.assertEqual(
                [entry.text for entry in HistoryStore(path, limit=3).entries],
                ["Transcriptie 4", "Transcriptie 3", "Transcriptie 2"],
            )

    def test_clear_removes_persisted_entries(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "history.json"
            store = HistoryStore(path)
            store.add("Bewaar mij")
            store.clear()

            self.assertEqual(store.entries, [])
            self.assertEqual(json.loads(path.read_text())["entries"], [])

    def test_remove_deletes_only_the_chosen_entry_and_persists(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "history.json"
            store = HistoryStore(path)
            keep = store.add("Bewaar deze")
            drop = store.add("Verwijder deze")

            self.assertTrue(store.remove(drop.id))
            self.assertFalse(store.remove("onbekend-id"))

            self.assertEqual([entry.id for entry in store.entries], [keep.id])
            self.assertEqual(
                [item["id"] for item in json.loads(path.read_text())["entries"]],
                [keep.id],
            )

    def test_rename_sets_name_and_persists_across_reload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "history.json"
            store = HistoryStore(path)
            entry = store.add("Een transcriptie")

            updated = store.rename(entry.id, "  Klantgesprek Vincent  ")
            self.assertIsNotNone(updated)
            self.assertEqual(updated.name, "Klantgesprek Vincent")
            self.assertIsNone(store.rename("onbekend-id", "x"))

            reloaded = HistoryStore(path).entries
            self.assertEqual(reloaded[0].name, "Klantgesprek Vincent")
            self.assertEqual(reloaded[0].text, "Een transcriptie")

    def test_pinned_entry_survives_beyond_limit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "history.json"
            store = HistoryStore(path, limit=2)
            keep = store.add("Pin mij")
            store.set_pinned(keep.id, True)
            for number in range(5):
                store.add(f"Transcriptie {number}")

            ids = [entry.id for entry in store.entries]
            self.assertIn(keep.id, ids)
            unpinned = [entry for entry in store.entries if not entry.pinned]
            self.assertEqual(len(unpinned), 2)

            reloaded = HistoryStore(path, limit=2).entries
            self.assertIn(keep.id, [entry.id for entry in reloaded])

    def test_metadata_and_segments_persist(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "history.json"
            store = HistoryStore(path)
            store.add(
                "Hallo",
                language="nl",
                model="medium",
                source="file",
                duration=2.5,
                segments=[{"start": 0.0, "end": 1.0, "text": "Hallo"}],
            )

            reloaded = HistoryStore(path).entries[0]
            self.assertEqual(reloaded.language, "nl")
            self.assertEqual(reloaded.model, "medium")
            self.assertEqual(reloaded.source, "file")
            self.assertEqual(reloaded.duration, 2.5)
            self.assertEqual(list(reloaded.segments), [{"start": 0.0, "end": 1.0, "text": "Hallo"}])

    def test_search_filters_by_text_and_name(self) -> None:
        first = HistoryEntry(id="1", text="Over de begroting", created_at="2026-06-20T22:00:00+02:00")
        second = HistoryEntry(
            id="2", text="Iets anders", created_at="2026-06-20T22:01:00+02:00", name="Begroting Q3"
        )
        self.assertEqual([e.id for e in search_entries([first, second], "begroting")], ["1", "2"])
        self.assertEqual(search_entries([first, second], "  "), [first, second])


if __name__ == "__main__":
    unittest.main()
