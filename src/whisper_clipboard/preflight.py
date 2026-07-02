from __future__ import annotations

from dataclasses import dataclass

import sounddevice as sd


@dataclass(frozen=True)
class PreflightReport:
    input_device: str | None

    @property
    def ready(self) -> bool:
        return self.input_device is not None


def run_preflight() -> PreflightReport:
    try:
        device = sd.query_devices(kind="input")
        input_device = str(device.get("name", "Microfoon"))
    except Exception:
        input_device = None

    return PreflightReport(input_device=input_device)
