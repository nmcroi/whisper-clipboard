from __future__ import annotations

import signal
import subprocess
from typing import TYPE_CHECKING

import objc
from AppKit import (
    NSApplication,
    NSApplicationActivationPolicyAccessory,
    NSApplicationActivationPolicyRegular,
    NSApp,
    NSColor,
    NSImage,
    NSImageSymbolConfiguration,
    NSMenu,
    NSMenuItem,
    NSStatusBar,
    NSVariableStatusItemLength,
)
from Foundation import NSObject
from PyObjCTools import AppHelper

from .history_window import HistoryWindowController, make_history_menu_item
from .hotkey import GlobalHotKey, display_hotkey
from .notify import notify
from .status import AppState, Status

if TYPE_CHECKING:
    from .__main__ import WhisperClipboardApp


STATE_SYMBOLS = {
    AppState.STARTING: "mic",
    AppState.LOADING_MODEL: "arrow.triangle.2.circlepath",
    AppState.READY: "mic",
    AppState.RECORDING: "record.circle.fill",
    AppState.TRANSCRIBING: "waveform",
    AppState.ERROR: "exclamationmark.triangle",
}


class MenuBarController(NSObject):
    def initWithApp_showStatusItem_(  # noqa: N802
        self, app: WhisperClipboardApp, show_status_item: bool
    ):
        self = objc.super(MenuBarController, self).init()
        if self is None:
            return None

        self.app = app
        self.show_status_item = show_status_item
        self.status_item = (
            NSStatusBar.systemStatusBar().statusItemWithLength_(
                NSVariableStatusItemLength
            )
            if show_status_item
            else None
        )
        self.menu = NSMenu.alloc().init()

        self.status_menu_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Whisper Clipboard start...", None, ""
        )
        self.status_menu_item.setEnabled_(False)
        self.menu.addItem_(self.status_menu_item)
        self.menu.addItem_(NSMenuItem.separatorItem())

        self.toggle_menu_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Start opname", "toggleRecording:", ""
        )
        self.toggle_menu_item.setTarget_(self)
        self.menu.addItem_(self.toggle_menu_item)

        self.import_menu_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Transcribeer audio of video...", "importMedia:", ""
        )
        self.import_menu_item.setTarget_(self)
        self.menu.addItem_(self.import_menu_item)

        self.history_menu_item = make_history_menu_item(self)
        self.menu.addItem_(self.history_menu_item)
        self.history_window = HistoryWindowController.alloc().initWithApp_(app)

        microphone_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Microfooninstellingen", "openMicrophone:", ""
        )
        microphone_item.setTarget_(self)
        self.menu.addItem_(microphone_item)

        self.menu.addItem_(NSMenuItem.separatorItem())
        quit_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Stop Whisper Clipboard", "quitApp:", "q"
        )
        quit_item.setTarget_(self)
        self.menu.addItem_(quit_item)

        if self.status_item is not None:
            self.status_item.setMenu_(self.menu)
        self.app.set_status_callback(self.on_status)
        self.app.set_history_callback(self.on_history_changed)
        self.on_status(self.app.status)
        self.on_history_changed(self.app.history_entries)
        return self

    def toggleRecording_(self, _sender) -> None:  # noqa: N802, ANN001
        self.app.toggle_recording()

    def openHistory_(self, _sender) -> None:  # noqa: N802, ANN001
        self.history_window.show()

    def importMedia_(self, sender) -> None:  # noqa: N802, ANN001
        self.history_window.importMedia_(sender)

    def openMicrophone_(self, _sender) -> None:  # noqa: N802, ANN001
        url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        subprocess.run(["open", url], check=False)

    def quitApp_(self, _sender) -> None:  # noqa: N802, ANN001
        NSApp.terminate_(self)

    def on_status(self, status: Status) -> None:
        AppHelper.callAfter(self._apply_status, status)

    def on_history_changed(self, entries) -> None:  # noqa: ANN001
        AppHelper.callAfter(self._apply_history, entries)

    def _apply_history(self, entries) -> None:  # noqa: ANN001
        self.history_menu_item.setTitle_("Open Whisper Clipboard")
        self.history_window.refresh(entries)

    def _apply_status(self, status: Status) -> None:
        message = status.message
        if len(message) > 80:
            message = message[:77] + "..."
        self.status_menu_item.setTitle_(message)
        self.toggle_menu_item.setTitle_(
            "Stop opname" if status.state == AppState.RECORDING else "Start opname"
        )
        self.toggle_menu_item.setEnabled_(
            status.state not in {AppState.LOADING_MODEL, AppState.TRANSCRIBING}
        )
        self.import_menu_item.setEnabled_(
            status.state
            not in {AppState.LOADING_MODEL, AppState.RECORDING, AppState.TRANSCRIBING}
        )
        self.history_window.apply_status(status)

        if self.status_item is None:
            return

        symbol_name = STATE_SYMBOLS[status.state]
        image = NSImage.imageWithSystemSymbolName_accessibilityDescription_(
            symbol_name, "Whisper Clipboard"
        )
        if image is not None:
            if status.state == AppState.RECORDING:
                configuration = (
                    NSImageSymbolConfiguration.configurationWithHierarchicalColor_(
                        NSColor.systemRedColor()
                    )
                )
                image = image.imageWithSymbolConfiguration_(configuration)
                image.setTemplate_(False)
            else:
                image.setTemplate_(True)
            self.status_item.button().setImage_(image)
            self.status_item.button().setTitle_("")
        else:
            self.status_item.button().setTitle_("WC")


class ApplicationDelegate(NSObject):
    def initWithApp_showWindow_(  # noqa: N802
        self, app: WhisperClipboardApp, show_window: bool
    ):
        self = objc.super(ApplicationDelegate, self).init()
        if self is None:
            return None
        self.app = app
        self.show_window = show_window
        self.controller = None
        self.hotkey = None
        return self

    def applicationDidFinishLaunching_(self, _notification) -> None:  # noqa: N802, ANN001
        self.controller = MenuBarController.alloc().initWithApp_showStatusItem_(
            self.app, True
        )
        self.app._menu_bar_controller = self.controller
        self.hotkey = GlobalHotKey(self.app.config.hotkey, self.app.toggle_recording)
        try:
            self.hotkey.register()
            print(f"Global hotkey registered: {self.app.config.hotkey}", flush=True)
            shortcut = display_hotkey(self.app.config.hotkey)
            self.controller.history_window.set_hotkey_status(
                f"Sneltoets actief: {shortcut}", True
            )
        except Exception as exc:
            message = f"Sneltoets kon niet starten: {exc}"
            print(message, flush=True)
            notify(message)
            self.controller.history_window.set_hotkey_status(
                "Sneltoets niet beschikbaar", False
            )
        if self.show_window:
            self.controller.history_window.show()

    def applicationShouldHandleReopen_hasVisibleWindows_(  # noqa: N802, ANN001
        self, _application, _has_visible_windows
    ) -> bool:
        if self.controller is not None:
            self.controller.history_window.show()
        return True

    def applicationDidBecomeActive_(self, _notification) -> None:  # noqa: N802, ANN001
        if not self.show_window or self.controller is None:
            return
        if not self.controller.history_window.window.isVisible():
            self.controller.history_window.show()

    def applicationShouldTerminateAfterLastWindowClosed_(  # noqa: N802, ANN001
        self, _application
    ) -> bool:
        return False

    def applicationWillTerminate_(self, _notification) -> None:  # noqa: N802, ANN001
        if self.hotkey is not None:
            self.hotkey.unregister()
        self.app.stop()


def run_menu_bar(app: WhisperClipboardApp, show_window: bool = False) -> None:
    mac_app = NSApplication.sharedApplication()
    policy = (
        NSApplicationActivationPolicyRegular
        if show_window
        else NSApplicationActivationPolicyAccessory
    )
    mac_app.setActivationPolicy_(policy)
    delegate = ApplicationDelegate.alloc().initWithApp_showWindow_(app, show_window)
    mac_app.setDelegate_(delegate)
    app._mac_app_delegate = delegate

    def stop(_signum, _frame) -> None:  # noqa: ANN001
        app.stop()
        AppHelper.callAfter(mac_app.terminate_, None)

    previous_sigint = signal.signal(signal.SIGINT, stop)
    previous_sigterm = signal.signal(signal.SIGTERM, stop)
    try:
        mac_app.run()
    finally:
        app.stop()
        signal.signal(signal.SIGINT, previous_sigint)
        signal.signal(signal.SIGTERM, previous_sigterm)
