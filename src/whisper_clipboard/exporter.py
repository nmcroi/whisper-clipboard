from __future__ import annotations

import json
import re
from pathlib import Path

from .history import HistoryEntry

EXPORT_EXTENSIONS = ("txt", "md", "json", "srt", "vtt")


def suggested_export_name(entry: HistoryEntry, extension: str = "txt") -> str:
    slug = re.sub(r"[^\w\- ]", "", entry.name).strip().replace(" ", "-")
    if not slug:
        slug = f"transcriptie-{entry.timestamp.strftime('%Y-%m-%d-%H%M')}"
    return f"{slug}.{extension.lstrip('.')}"


def _segments(entry: HistoryEntry) -> list[tuple[float, float, str]]:
    result: list[tuple[float, float, str]] = []
    for segment in entry.segments or ():
        if isinstance(segment, dict):
            text = str(segment.get("text", "")).strip()
            if text:
                result.append(
                    (
                        float(segment.get("start", 0.0)),
                        float(segment.get("end", 0.0)),
                        text,
                    )
                )
    if not result and entry.text.strip():
        result.append((0.0, max(float(entry.duration), 1.0), entry.text.strip()))
    return result


def _timecode(seconds: float, separator: str) -> str:
    millis = max(0, int(round(seconds * 1000)))
    hours, millis = divmod(millis, 3_600_000)
    minutes, millis = divmod(millis, 60_000)
    secs, millis = divmod(millis, 1000)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}{separator}{millis:03d}"


def to_txt(entry: HistoryEntry) -> str:
    return entry.text.rstrip() + "\n"


def to_markdown(entry: HistoryEntry) -> str:
    moment = entry.timestamp.strftime("%d-%m-%Y %H:%M")
    title = entry.name.strip() or moment
    return f"# {title}\n\n_{moment}_\n\n{entry.text.rstrip()}\n"


def to_json(entry: HistoryEntry) -> str:
    payload = {
        "name": entry.name,
        "created_at": entry.created_at,
        "language": entry.language,
        "model": entry.model,
        "duration": entry.duration,
        "text": entry.text,
        "segments": [dict(segment) for segment in (entry.segments or ()) if isinstance(segment, dict)],
    }
    return json.dumps(payload, ensure_ascii=False, indent=2) + "\n"


def to_srt(entry: HistoryEntry) -> str:
    blocks = []
    for index, (start, end, text) in enumerate(_segments(entry), start=1):
        blocks.append(
            f"{index}\n{_timecode(start, ',')} --> {_timecode(max(end, start), ',')}\n{text}\n"
        )
    return "\n".join(blocks)


def to_vtt(entry: HistoryEntry) -> str:
    blocks = ["WEBVTT\n"]
    for start, end, text in _segments(entry):
        blocks.append(
            f"{_timecode(start, '.')} --> {_timecode(max(end, start), '.')}\n{text}\n"
        )
    return "\n".join(blocks)


_WRITERS = {
    ".txt": to_txt,
    ".md": to_markdown,
    ".markdown": to_markdown,
    ".json": to_json,
    ".srt": to_srt,
    ".vtt": to_vtt,
}


def export_entry(entry: HistoryEntry, output_path: Path) -> Path:
    path = Path(output_path)
    writer = _WRITERS.get(path.suffix.lower())
    if writer is None:
        path = path.with_suffix(".txt")
        writer = to_txt
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(writer(entry), encoding="utf-8")
    return path


def export_all(entries: list[HistoryEntry], directory: Path, extension: str = "md") -> list[Path]:
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    extension = extension.lstrip(".") or "md"
    paths = []
    for index, entry in enumerate(entries, start=1):
        stem = Path(suggested_export_name(entry)).stem
        paths.append(export_entry(entry, directory / f"{index:02d}-{stem}.{extension}"))
    return paths


def export_text(text: str, output_path: Path) -> Path:
    path = output_path if output_path.suffix.lower() == ".txt" else output_path.with_suffix(".txt")
    path.write_text(text.rstrip() + "\n", encoding="utf-8")
    return path
