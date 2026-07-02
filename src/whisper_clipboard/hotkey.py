from __future__ import annotations

import ctypes
from collections.abc import Callable
from dataclasses import dataclass


HITOOLBOX_PATH = (
    "/System/Library/Frameworks/Carbon.framework/Frameworks/"
    "HIToolbox.framework/HIToolbox"
)

COMMAND_KEY = 1 << 8
SHIFT_KEY = 1 << 9
OPTION_KEY = 1 << 11
CONTROL_KEY = 1 << 12
HOT_KEY_RELEASED = 6
EVENT_HANDLER_CALLBACK = ctypes.CFUNCTYPE(
    ctypes.c_int32,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_void_p,
)

MODIFIERS = {
    "cmd": COMMAND_KEY,
    "command": COMMAND_KEY,
    "shift": SHIFT_KEY,
    "alt": OPTION_KEY,
    "option": OPTION_KEY,
    "ctrl": CONTROL_KEY,
    "control": CONTROL_KEY,
}

KEY_CODES = {
    "a": 0,
    "s": 1,
    "d": 2,
    "f": 3,
    "h": 4,
    "g": 5,
    "z": 6,
    "x": 7,
    "c": 8,
    "v": 9,
    "b": 11,
    "q": 12,
    "w": 13,
    "e": 14,
    "r": 15,
    "y": 16,
    "t": 17,
    "1": 18,
    "2": 19,
    "3": 20,
    "4": 21,
    "6": 22,
    "5": 23,
    "9": 25,
    "7": 26,
    "8": 28,
    "0": 29,
    "o": 31,
    "u": 32,
    "i": 34,
    "p": 35,
    "return": 36,
    "enter": 36,
    "l": 37,
    "j": 38,
    "k": 40,
    "n": 45,
    "m": 46,
    "tab": 48,
    "space": 49,
    "spatie": 49,
    "escape": 53,
    "esc": 53,
}


class EventTypeSpec(ctypes.Structure):
    _fields_ = [("event_class", ctypes.c_uint32), ("event_kind", ctypes.c_uint32)]


class EventHotKeyID(ctypes.Structure):
    _fields_ = [("signature", ctypes.c_uint32), ("identifier", ctypes.c_uint32)]


@dataclass(frozen=True)
class ParsedHotKey:
    key_code: int
    modifiers: int


def display_hotkey(value: str) -> str:
    labels = {
        "cmd": "Command",
        "command": "Command",
        "shift": "Shift",
        "alt": "Option",
        "option": "Option",
        "ctrl": "Control",
        "control": "Control",
        "space": "spatie",
        "spatie": "spatie",
    }
    parts = [part.strip().lower().strip("<>") for part in value.split("+")]
    return " + ".join(labels.get(part, part.upper()) for part in parts if part)


def parse_hotkey(value: str) -> ParsedHotKey:
    parts = [part.strip().lower().strip("<>") for part in value.split("+")]
    parts = [part for part in parts if part]
    if len(parts) < 2:
        raise ValueError("A hotkey needs at least one modifier and one key.")

    key_name = parts[-1]
    if key_name not in KEY_CODES:
        raise ValueError(f"Unsupported hotkey key: {key_name}")

    modifiers = 0
    for name in parts[:-1]:
        if name not in MODIFIERS:
            raise ValueError(f"Unsupported hotkey modifier: {name}")
        modifiers |= MODIFIERS[name]

    return ParsedHotKey(key_code=KEY_CODES[key_name], modifiers=modifiers)


class GlobalHotKey:
    def __init__(self, shortcut: str, callback: Callable[[], None]) -> None:
        self.shortcut = shortcut
        self.callback = callback
        self._library = ctypes.CDLL(HITOOLBOX_PATH)
        self._hotkey_ref = ctypes.c_void_p()
        self._handler_ref = ctypes.c_void_p()
        self._callback_ref = None
        self._configure_api()

    @property
    def registered(self) -> bool:
        return bool(self._hotkey_ref.value)

    def register(self) -> None:
        if self.registered:
            return

        parsed = parse_hotkey(self.shortcut)
        def on_hotkey(_next_handler, _event, _user_data) -> int:  # noqa: ANN001
            self.callback()
            return 0

        self._callback_ref = EVENT_HANDLER_CALLBACK(on_hotkey)
        event_type = EventTypeSpec(
            event_class=int.from_bytes(b"keyb", "big"),
            event_kind=HOT_KEY_RELEASED,
        )
        target = self._library.GetApplicationEventTarget()
        status = self._library.InstallEventHandler(
            target,
            self._callback_ref,
            1,
            ctypes.byref(event_type),
            None,
            ctypes.byref(self._handler_ref),
        )
        if status != 0:
            self._callback_ref = None
            raise RuntimeError(f"Could not install hotkey handler (OSStatus {status}).")

        hotkey_id = EventHotKeyID(
            signature=int.from_bytes(b"WCPB", "big"),
            identifier=1,
        )
        status = self._library.RegisterEventHotKey(
            parsed.key_code,
            parsed.modifiers,
            hotkey_id,
            target,
            0,
            ctypes.byref(self._hotkey_ref),
        )
        if status != 0:
            self._library.RemoveEventHandler(self._handler_ref)
            self._handler_ref = ctypes.c_void_p()
            self._callback_ref = None
            raise RuntimeError(f"Could not register hotkey (OSStatus {status}).")

    def unregister(self) -> None:
        if self._hotkey_ref.value:
            self._library.UnregisterEventHotKey(self._hotkey_ref)
            self._hotkey_ref = ctypes.c_void_p()
        if self._handler_ref.value:
            self._library.RemoveEventHandler(self._handler_ref)
            self._handler_ref = ctypes.c_void_p()
        self._callback_ref = None

    def _configure_api(self) -> None:
        self._library.GetApplicationEventTarget.restype = ctypes.c_void_p
        self._library.InstallEventHandler.argtypes = [
            ctypes.c_void_p,
            EVENT_HANDLER_CALLBACK,
            ctypes.c_uint32,
            ctypes.POINTER(EventTypeSpec),
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_void_p),
        ]
        self._library.InstallEventHandler.restype = ctypes.c_int32
        self._library.RegisterEventHotKey.argtypes = [
            ctypes.c_uint32,
            ctypes.c_uint32,
            EventHotKeyID,
            ctypes.c_void_p,
            ctypes.c_uint32,
            ctypes.POINTER(ctypes.c_void_p),
        ]
        self._library.RegisterEventHotKey.restype = ctypes.c_int32
        self._library.UnregisterEventHotKey.argtypes = [ctypes.c_void_p]
        self._library.UnregisterEventHotKey.restype = ctypes.c_int32
        self._library.RemoveEventHandler.argtypes = [ctypes.c_void_p]
        self._library.RemoveEventHandler.restype = ctypes.c_int32
