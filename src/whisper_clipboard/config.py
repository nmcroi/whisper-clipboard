from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG_PATH = PROJECT_ROOT / "config.toml"


@dataclass(frozen=True)
class AppConfig:
    hotkey: str = "<ctrl>+<space>"
    language: str | None = "nl"
    engine: str = "faster_whisper"
    model: str = "small"
    models_dir: str = "models"
    preload_model: bool = True
    device: str = "cpu"
    compute_type: str = "int8"
    sample_rate: int = 16000
    vad_filter: bool = True
    beam_size: int = 5
    task: str = "transcribe"
    initial_prompt: str = ""
    clean_output: bool = True
    replacements: tuple[tuple[str, str], ...] = ()
    paste_after_copy: bool = False
    save_recordings: bool = False
    recordings_dir: str = "recordings"
    save_transcripts: bool = False
    transcripts_dir: str = "transcripts"
    history_limit: int = 20
    whisper_cpp_binary: str = "whisper-cli"
    whisper_cpp_model_path: str = ""
    mlx_model_path: str = "models/mlx/whisper-medium"

    @property
    def recordings_path(self) -> Path:
        path = Path(self.recordings_dir)
        return path if path.is_absolute() else PROJECT_ROOT / path

    @property
    def transcripts_path(self) -> Path:
        path = Path(self.transcripts_dir)
        return path if path.is_absolute() else PROJECT_ROOT / path

    @property
    def models_path(self) -> Path:
        path = Path(self.models_dir)
        return path if path.is_absolute() else PROJECT_ROOT / path

    @property
    def history_path(self) -> Path:
        return (
            Path.home()
            / "Library"
            / "Application Support"
            / "Whisper Clipboard"
            / "history.json"
        )

    @property
    def whisper_cpp_model(self) -> Path | None:
        if not self.whisper_cpp_model_path.strip():
            return None

        path = Path(os.path.expanduser(self.whisper_cpp_model_path))
        return path if path.is_absolute() else PROJECT_ROOT / path

    @property
    def mlx_model(self) -> Path | None:
        if not self.mlx_model_path.strip():
            return None

        path = Path(os.path.expanduser(self.mlx_model_path))
        return path if path.is_absolute() else PROJECT_ROOT / path


def _parse_replacements(raw: object) -> tuple[tuple[str, str], ...]:
    pairs: list[tuple[str, str]] = []
    if isinstance(raw, list):
        for item in raw:
            if isinstance(item, dict):
                find = str(item.get("from", "")).strip()
                replace = str(item.get("to", ""))
            elif isinstance(item, (list, tuple)) and len(item) >= 2:
                find = str(item[0]).strip()
                replace = str(item[1])
            else:
                continue
            if find:
                pairs.append((find, replace))
    return tuple(pairs)


def load_config() -> AppConfig:
    config_path = Path(os.environ.get("WHISPER_CLIPBOARD_CONFIG", DEFAULT_CONFIG_PATH))
    if not config_path.exists():
        return AppConfig()

    data = tomllib.loads(config_path.read_text(encoding="utf-8"))
    language = data.get("language", "nl")
    task = "translate" if str(data.get("task", "")).strip().lower() == "translate" else "transcribe"

    return AppConfig(
        hotkey=str(data.get("hotkey", AppConfig.hotkey)),
        language=str(language).strip() or None,
        engine=str(data.get("engine", AppConfig.engine)),
        model=str(data.get("model", AppConfig.model)),
        models_dir=str(data.get("models_dir", AppConfig.models_dir)),
        preload_model=bool(data.get("preload_model", AppConfig.preload_model)),
        device=str(data.get("device", AppConfig.device)),
        compute_type=str(data.get("compute_type", AppConfig.compute_type)),
        sample_rate=int(data.get("sample_rate", AppConfig.sample_rate)),
        vad_filter=bool(data.get("vad_filter", AppConfig.vad_filter)),
        beam_size=max(1, int(data.get("beam_size", AppConfig.beam_size))),
        task=task,
        initial_prompt=str(data.get("initial_prompt", AppConfig.initial_prompt)),
        clean_output=bool(data.get("clean_output", AppConfig.clean_output)),
        replacements=_parse_replacements(data.get("replacements", [])),
        paste_after_copy=bool(data.get("paste_after_copy", AppConfig.paste_after_copy)),
        save_recordings=bool(data.get("save_recordings", AppConfig.save_recordings)),
        recordings_dir=str(data.get("recordings_dir", AppConfig.recordings_dir)),
        save_transcripts=bool(data.get("save_transcripts", AppConfig.save_transcripts)),
        transcripts_dir=str(data.get("transcripts_dir", AppConfig.transcripts_dir)),
        history_limit=max(1, int(data.get("history_limit", AppConfig.history_limit))),
        whisper_cpp_binary=str(data.get("whisper_cpp_binary", AppConfig.whisper_cpp_binary)),
        whisper_cpp_model_path=str(
            data.get("whisper_cpp_model_path", AppConfig.whisper_cpp_model_path)
        ),
        mlx_model_path=str(data.get("mlx_model_path", AppConfig.mlx_model_path)),
    )
