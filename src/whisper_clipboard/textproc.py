from __future__ import annotations

import re
from collections.abc import Iterable, Sequence

# A replacement is a (find, replace) pair. Find is matched whole-word,
# case-insensitively, so "vps" does not touch "vpsx" and "Vps" still matches.
Replacement = tuple[str, str]


def apply_replacements(text: str, replacements: Iterable[Replacement]) -> str:
    for find, replace in replacements:
        find = find.strip()
        if not find:
            continue
        pattern = re.compile(rf"\b{re.escape(find)}\b", re.IGNORECASE)
        text = pattern.sub(lambda _match, value=replace: value, text)
    return text


def clean_text(text: str) -> str:
    """Conservative tidy-up: collapse whitespace, fix spacing around
    punctuation, and capitalize sentence starts. Never touches word spelling."""
    text = re.sub(r"\s+", " ", text).strip()
    if not text:
        return text

    # No space before , . ! ? ; : and exactly one space after.
    text = re.sub(r"\s+([,.!?;:])", r"\1", text)
    text = re.sub(r"([,.!?;:])(?=[^\s\d])", r"\1 ", text)

    text = text[0].upper() + text[1:]
    text = re.sub(
        r"([.!?]\s+)([a-zà-öø-ÿ])",
        lambda match: match.group(1) + match.group(2).upper(),
        text,
    )
    return text


def process(
    text: str,
    replacements: Sequence[Replacement] = (),
    clean: bool = True,
) -> str:
    """Run the full post-transcription text pipeline."""
    text = apply_replacements(text, replacements)
    if clean:
        text = clean_text(text)
    return text
