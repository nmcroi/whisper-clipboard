from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class AppState(str, Enum):
    STARTING = "starting"
    LOADING_MODEL = "loading_model"
    READY = "ready"
    RECORDING = "recording"
    TRANSCRIBING = "transcribing"
    ERROR = "error"


@dataclass(frozen=True)
class Status:
    state: AppState
    message: str
