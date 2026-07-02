from __future__ import annotations

import json
import threading
import uuid
from dataclasses import asdict, dataclass, replace
from datetime import datetime
from pathlib import Path


@dataclass(frozen=True)
class HistoryEntry:
    id: str
    text: str
    created_at: str
    name: str = ""
    pinned: bool = False
    language: str = ""
    model: str = ""
    source: str = "mic"
    duration: float = 0.0
    segments: tuple = ()

    @property
    def timestamp(self) -> datetime:
        return datetime.fromisoformat(self.created_at)


def search_entries(entries: list[HistoryEntry], query: str) -> list[HistoryEntry]:
    needle = query.strip().lower()
    if not needle:
        return list(entries)
    return [
        entry
        for entry in entries
        if needle in entry.text.lower() or needle in entry.name.lower()
    ]


class HistoryStore:
    def __init__(self, path: Path, limit: int = 20) -> None:
        self.path = path
        self.limit = max(1, limit)
        self._lock = threading.RLock()
        self._entries = self._load()

    @property
    def entries(self) -> list[HistoryEntry]:
        with self._lock:
            return list(self._entries)

    def add(
        self,
        text: str,
        *,
        name: str = "",
        language: str = "",
        model: str = "",
        source: str = "mic",
        duration: float = 0.0,
        segments: object = None,
    ) -> HistoryEntry:
        entry = HistoryEntry(
            id=str(uuid.uuid4()),
            text=text.strip(),
            created_at=datetime.now().astimezone().isoformat(timespec="seconds"),
            name=name,
            language=language,
            model=model,
            source=source,
            duration=float(duration),
            segments=tuple(segments or ()),
        )
        with self._lock:
            self._entries.insert(0, entry)
            self._entries = self._trim(self._entries)
            self._write()
        return entry

    def set_pinned(self, entry_id: str, pinned: bool) -> HistoryEntry | None:
        with self._lock:
            for index, entry in enumerate(self._entries):
                if entry.id == entry_id:
                    if entry.pinned == pinned:
                        return entry
                    updated = replace(entry, pinned=pinned)
                    self._entries[index] = updated
                    self._entries = self._trim(self._entries)
                    self._write()
                    return updated
        return None

    def _trim(self, entries: list[HistoryEntry]) -> list[HistoryEntry]:
        kept: list[HistoryEntry] = []
        unpinned = 0
        for entry in entries:
            if entry.pinned:
                kept.append(entry)
            elif unpinned < self.limit:
                kept.append(entry)
                unpinned += 1
        return kept

    def remove(self, entry_id: str) -> bool:
        with self._lock:
            remaining = [entry for entry in self._entries if entry.id != entry_id]
            if len(remaining) == len(self._entries):
                return False
            self._entries = remaining
            self._write()
        return True

    def rename(self, entry_id: str, name: str) -> HistoryEntry | None:
        clean = name.strip()
        with self._lock:
            for index, entry in enumerate(self._entries):
                if entry.id == entry_id:
                    if entry.name == clean:
                        return entry
                    updated = replace(entry, name=clean)
                    self._entries[index] = updated
                    self._write()
                    return updated
        return None

    def clear(self) -> None:
        with self._lock:
            self._entries = []
            self._write()

    def _load(self) -> list[HistoryEntry]:
        if not self.path.exists():
            return []

        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            raw_entries = data.get("entries", [])
            entries = [HistoryEntry(**item) for item in raw_entries]
            return self._trim(entries)
        except (OSError, ValueError, TypeError, KeyError):
            return []

    def _write(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temp_path = self.path.with_suffix(".tmp")
        payload = {
            "version": 3,
            "entries": [asdict(entry) for entry in self._entries],
        }
        temp_path.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        temp_path.replace(self.path)
