from __future__ import annotations

from datetime import datetime
from pathlib import Path
from typing import TYPE_CHECKING

import objc
from AppKit import (
    NSAlert,
    NSAlertFirstButtonReturn,
    NSApp,
    NSBackingStoreBuffered,
    NSBezierPath,
    NSBezelStyleRounded,
    NSButton,
    NSColor,
    NSFontAttributeName,
    NSForegroundColorAttributeName,
    NSImage,
    NSImageLeading,
    NSImageSymbolConfiguration,
    NSLineBreakByTruncatingTail,
    NSMakeRect,
    NSMenuItem,
    NSModalResponseOK,
    NSOpenPanel,
    NSProgressIndicator,
    NSProgressIndicatorStyleSpinning,
    NSScrollView,
    NSSavePanel,
    NSSearchField,
    NSSplitView,
    NSSplitViewDividerStyleThin,
    NSTableCellView,
    NSTableColumn,
    NSTableRowView,
    NSTableView,
    NSTextField,
    NSTextView,
    NSView,
    NSViewHeightSizable,
    NSViewMinXMargin,
    NSViewMinYMargin,
    NSViewWidthSizable,
    NSWindow,
    NSWindowStyleMaskClosable,
    NSWindowStyleMaskMiniaturizable,
    NSWindowStyleMaskResizable,
    NSWindowStyleMaskTitled,
)
from Foundation import NSIndexSet, NSMutableAttributedString, NSMakeRange, NSObject

from .exporter import EXPORT_EXTENSIONS, suggested_export_name
from .history import search_entries
from .status import AppState, Status
from .theme import (
    BG,
    CARD,
    LIGHTTERRA,
    MARINE,
    SOFTBLUE,
    TEAL,
    TERRA,
    TERRADARK,
    body_font,
    heading_font,
)

if TYPE_CHECKING:
    from .__main__ import WhisperClipboardApp
    from .history import HistoryEntry


class NightStoryTableRowView(NSTableRowView):
    def drawSelectionInRect_(self, _dirty_rect) -> None:  # noqa: N802, ANN001
        bounds = self.bounds()
        inset = NSMakeRect(
            bounds.origin.x + 8,
            bounds.origin.y + 4,
            bounds.size.width - 16,
            bounds.size.height - 8,
        )
        LIGHTTERRA.setFill()
        NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(inset, 12, 12).fill()


class HistoryWindowController(NSObject):
    def initWithApp_(self, app: WhisperClipboardApp):  # noqa: N802
        self = objc.super(HistoryWindowController, self).init()
        if self is None:
            return None

        self.app = app
        self.entries = app.history_entries
        self.window = self._build_window()
        self.refresh(self.entries)
        self.apply_status(app.status)
        return self

    @objc.python_method
    def _build_window(self) -> NSWindow:
        style = (
            NSWindowStyleMaskTitled
            | NSWindowStyleMaskClosable
            | NSWindowStyleMaskMiniaturizable
            | NSWindowStyleMaskResizable
        )
        window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, 900, 640),
            style,
            NSBackingStoreBuffered,
            False,
        )
        window.setTitle_("Whisper Clipboard")
        window.setMinSize_((760, 520))
        window.setReleasedWhenClosed_(False)
        window.setDelegate_(self)
        window.setBackgroundColor_(BG)
        window.center()

        content = window.contentView()

        title = NSTextField.labelWithString_("")
        title.setFrame_(NSMakeRect(32, 584, 450, 38))
        title.setAttributedStringValue_(self._app_title())
        title.setAutoresizingMask_(NSViewWidthSizable | NSViewMinYMargin)
        content.addSubview_(title)

        self.status_label = NSTextField.labelWithString_("Whisper Clipboard start...")
        self.status_label.setFrame_(NSMakeRect(58, 552, 424, 21))
        self.status_label.setFont_(body_font(13, "medium"))
        self.status_label.setTextColor_(TEAL)
        self.status_label.setAutoresizingMask_(NSViewWidthSizable | NSViewMinYMargin)
        content.addSubview_(self.status_label)

        self.progress = NSProgressIndicator.alloc().initWithFrame_(NSMakeRect(32, 553, 18, 18))
        self.progress.setStyle_(NSProgressIndicatorStyleSpinning)
        self.progress.setDisplayedWhenStopped_(False)
        self.progress.setControlTint_(1)
        self.progress.setAutoresizingMask_(NSViewMinYMargin)
        content.addSubview_(self.progress)

        self.hotkey_status_label = NSTextField.labelWithString_("Sneltoets starten...")
        self.hotkey_status_label.setFrame_(NSMakeRect(32, 526, 450, 18))
        self.hotkey_status_label.setFont_(body_font(12))
        self.hotkey_status_label.setTextColor_(TEAL)
        self.hotkey_status_label.setAutoresizingMask_(
            NSViewWidthSizable | NSViewMinYMargin
        )
        content.addSubview_(self.hotkey_status_label)

        self.import_button = self._button(
            "Importeer bestand",
            "square.and.arrow.down",
            "importMedia:",
            NSMakeRect(512, 562, 172, 42),
        )
        self.import_button.setAutoresizingMask_(NSViewMinXMargin | NSViewMinYMargin)
        content.addSubview_(self.import_button)

        self.record_button = self._button(
            "Start opname",
            "mic.fill",
            "toggleRecording:",
            NSMakeRect(696, 562, 172, 42),
            primary=True,
        )
        self.record_button.setAutoresizingMask_(NSViewMinXMargin | NSViewMinYMargin)
        content.addSubview_(self.record_button)

        self.count_label = NSTextField.labelWithString_("")
        self.count_label.setFrame_(NSMakeRect(32, 493, 360, 20))
        self.count_label.setFont_(body_font(12, "medium"))
        self.count_label.setTextColor_(SOFTBLUE)
        self.count_label.setAutoresizingMask_(NSViewWidthSizable | NSViewMinYMargin)
        content.addSubview_(self.count_label)

        self.search_field = NSSearchField.alloc().initWithFrame_(
            NSMakeRect(596, 488, 272, 28)
        )
        self.search_field.setFont_(body_font(12))
        self.search_field.setPlaceholderString_("Zoek in transcripties...")
        self.search_field.setDelegate_(self)
        self.search_field.setTarget_(self)
        self.search_field.setAction_("searchChanged:")
        self.search_field.setAutoresizingMask_(NSViewMinXMargin | NSViewMinYMargin)
        content.addSubview_(self.search_field)

        split_view = NSSplitView.alloc().initWithFrame_(NSMakeRect(32, 82, 836, 396))
        split_view.setVertical_(True)
        split_view.setDividerStyle_(NSSplitViewDividerStyleThin)
        split_view.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)

        list_container = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, 292, 396))
        detail_container = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, 532, 396))
        split_view.addSubview_(list_container)
        split_view.addSubview_(detail_container)
        content.addSubview_(split_view)

        self.table = NSTableView.alloc().initWithFrame_(list_container.bounds())
        self.table.setHeaderView_(None)
        self.table.setRowHeight_(74)
        self.table.setAllowsEmptySelection_(True)
        self.table.setDelegate_(self)
        self.table.setDataSource_(self)
        self.table.setTarget_(self)
        self.table.setDoubleAction_("copySelected:")
        self.table.setBackgroundColor_(CARD)

        column = NSTableColumn.alloc().initWithIdentifier_("transcript")
        column.setWidth_(292)
        column.setResizingMask_(1)
        self.table.addTableColumn_(column)

        list_scroll = NSScrollView.alloc().initWithFrame_(list_container.bounds())
        list_scroll.setHasVerticalScroller_(True)
        list_scroll.setAutohidesScrollers_(True)
        list_scroll.setBorderType_(0)
        list_scroll.setDocumentView_(self.table)
        list_scroll.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)
        list_container.addSubview_(list_scroll)

        self.name_field = NSTextField.alloc().initWithFrame_(
            NSMakeRect(18, 352, 496, 30)
        )
        self.name_field.setFont_(heading_font(19))
        self.name_field.setTextColor_(MARINE)
        self.name_field.setBezeled_(False)
        self.name_field.setBordered_(False)
        self.name_field.setDrawsBackground_(False)
        self.name_field.setEditable_(True)
        self.name_field.setSelectable_(True)
        self.name_field.setPlaceholderString_("Geef deze transcriptie een naam...")
        self.name_field.setDelegate_(self)
        self.name_field.setTarget_(self)
        self.name_field.setAction_("nameFieldChanged:")
        self.name_field.setEnabled_(False)
        self.name_field.setAutoresizingMask_(NSViewWidthSizable | NSViewMinYMargin)
        detail_container.addSubview_(self.name_field)

        self.detail_timestamp = NSTextField.labelWithString_("")
        self.detail_timestamp.setFrame_(NSMakeRect(20, 330, 496, 18))
        self.detail_timestamp.setFont_(body_font(11, "semibold"))
        self.detail_timestamp.setTextColor_(TERRA)
        self.detail_timestamp.setAutoresizingMask_(NSViewWidthSizable | NSViewMinYMargin)
        detail_container.addSubview_(self.detail_timestamp)

        self.detail = NSTextView.alloc().initWithFrame_(NSMakeRect(0, 0, 532, 322))
        self.detail.setEditable_(False)
        self.detail.setRichText_(False)
        self.detail.setSelectable_(True)
        self.detail.setFont_(body_font(15))
        self.detail.setTextColor_(MARINE)
        self.detail.setBackgroundColor_(CARD)
        self.detail.setTextContainerInset_((18, 16))
        self.detail.setAutoresizingMask_(NSViewWidthSizable)

        detail_scroll = NSScrollView.alloc().initWithFrame_(NSMakeRect(0, 0, 532, 322))
        detail_scroll.setHasVerticalScroller_(True)
        detail_scroll.setAutohidesScrollers_(True)
        detail_scroll.setBorderType_(0)
        detail_scroll.setDocumentView_(self.detail)
        detail_scroll.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)
        detail_container.addSubview_(detail_scroll)

        self.copy_button = self._button(
            "Kopieer", "doc.on.doc", "copySelected:", NSMakeRect(32, 26, 118, 36)
        )
        self.copy_button.setEnabled_(False)
        content.addSubview_(self.copy_button)

        self.export_button = self._button(
            "Exporteer",
            "square.and.arrow.up",
            "exportSelected:",
            NSMakeRect(160, 26, 132, 36),
        )
        self.export_button.setEnabled_(False)
        content.addSubview_(self.export_button)

        self.pin_button = self._button(
            "Vastzetten", "pin", "togglePin:", NSMakeRect(302, 26, 138, 36)
        )
        self.pin_button.setEnabled_(False)
        content.addSubview_(self.pin_button)

        self.delete_button = self._button(
            "Verwijder", "trash", "deleteSelected:", NSMakeRect(450, 26, 138, 36)
        )
        self.delete_button.setContentTintColor_(TERRADARK)
        self._set_button_title(self.delete_button, "Verwijder", TERRADARK)
        self.delete_button.setEnabled_(False)
        content.addSubview_(self.delete_button)

        clear_button = self._button(
            "Wis alles", "trash.slash", "clearHistory:", NSMakeRect(750, 26, 118, 36)
        )
        clear_button.setAutoresizingMask_(NSViewMinXMargin)
        clear_button.setContentTintColor_(TERRADARK)
        self._set_button_title(clear_button, "Wis alles", TERRADARK)
        content.addSubview_(clear_button)
        self.clear_button = clear_button

        return window

    @objc.python_method
    def _button(  # noqa: ANN001
        self,
        title: str,
        symbol: str,
        action: str,
        frame,
        primary: bool = False,
    ) -> NSButton:
        button = NSButton.alloc().initWithFrame_(frame)
        button.setTitle_(title)
        button.setTarget_(self)
        button.setAction_(action)
        button.setBezelStyle_(NSBezelStyleRounded)
        button.setFont_(body_font(13, "semibold"))
        if primary:
            button.setBezelColor_(TERRA)
            button.setContentTintColor_(NSColor.whiteColor())
        else:
            button.setBezelColor_(LIGHTTERRA)
            button.setContentTintColor_(MARINE)
        title_color = NSColor.whiteColor() if primary else MARINE
        self._set_button_title(button, title, title_color)
        image = NSImage.imageWithSystemSymbolName_accessibilityDescription_(symbol, title)
        if image is not None:
            configuration = NSImageSymbolConfiguration.configurationWithHierarchicalColor_(
                title_color
            )
            image = image.imageWithSymbolConfiguration_(configuration)
            image.setTemplate_(False)
            button.setImage_(image)
            button.setImagePosition_(NSImageLeading)
        return button

    @objc.python_method
    def _set_button_title(self, button: NSButton, value: str, text_color: NSColor) -> None:
        title = NSMutableAttributedString.alloc().initWithString_(value)
        title.addAttribute_value_range_(
            NSFontAttributeName, body_font(13, "semibold"), NSMakeRange(0, len(value))
        )
        title.addAttribute_value_range_(
            NSForegroundColorAttributeName, text_color, NSMakeRange(0, len(value))
        )
        button.setAttributedTitle_(title)

    @objc.python_method
    def _app_title(self) -> NSMutableAttributedString:
        value = "Whisper Clipboard."
        title = NSMutableAttributedString.alloc().initWithString_(value)
        title.addAttribute_value_range_(
            NSFontAttributeName, heading_font(25), NSMakeRange(0, len(value))
        )
        title.addAttribute_value_range_(
            NSForegroundColorAttributeName, MARINE, NSMakeRange(0, len(value) - 1)
        )
        title.addAttribute_value_range_(
            NSForegroundColorAttributeName, TERRA, NSMakeRange(len(value) - 1, 1)
        )
        return title

    @objc.python_method
    def show(self) -> None:
        self.refresh(self.app.history_entries)
        self.window.makeKeyAndOrderFront_(None)
        NSApp.activateIgnoringOtherApps_(True)

    def windowShouldClose_(self, _sender) -> bool:  # noqa: N802, ANN001
        self.window.orderOut_(None)
        NSApp.hide_(None)
        return False

    @objc.python_method
    def apply_status(self, status: Status) -> None:
        self.status_label.setStringValue_(status.message)
        is_recording = status.state == AppState.RECORDING
        status_colors = {
            AppState.STARTING: SOFTBLUE,
            AppState.LOADING_MODEL: SOFTBLUE,
            AppState.READY: TEAL,
            AppState.RECORDING: NSColor.systemRedColor(),
            AppState.TRANSCRIBING: TERRA,
            AppState.ERROR: TERRADARK,
        }
        self.status_label.setTextColor_(status_colors[status.state])
        is_busy = status.state in {AppState.LOADING_MODEL, AppState.TRANSCRIBING}
        if is_busy:
            self.progress.startAnimation_(None)
        else:
            self.progress.stopAnimation_(None)
        record_title = "Stop opname" if is_recording else "Start opname"
        self._set_button_title(self.record_button, record_title, NSColor.whiteColor())
        self.record_button.setEnabled_(
            status.state not in {AppState.LOADING_MODEL, AppState.TRANSCRIBING}
        )
        self.import_button.setEnabled_(
            status.state not in {
                AppState.LOADING_MODEL,
                AppState.RECORDING,
                AppState.TRANSCRIBING,
            }
        )
        self.record_button.setBezelColor_(NSColor.systemRedColor() if is_recording else TERRA)

        symbol = "stop.circle.fill" if is_recording else "mic.fill"
        image = NSImage.imageWithSystemSymbolName_accessibilityDescription_(
            symbol, record_title
        )
        if image is not None:
            configuration = NSImageSymbolConfiguration.configurationWithHierarchicalColor_(
                NSColor.whiteColor()
            )
            image = image.imageWithSymbolConfiguration_(configuration)
            image.setTemplate_(False)
            self.record_button.setImage_(image)

    @objc.python_method
    def set_hotkey_status(self, message: str, available: bool) -> None:
        self.hotkey_status_label.setStringValue_(message)
        self.hotkey_status_label.setTextColor_(
            TEAL
            if available
            else TERRADARK
        )

    def toggleRecording_(self, _sender) -> None:  # noqa: N802, ANN001
        self.app.toggle_recording()

    def importMedia_(self, _sender) -> None:  # noqa: N802, ANN001
        panel = NSOpenPanel.openPanel()
        panel.setCanChooseFiles_(True)
        panel.setCanChooseDirectories_(False)
        panel.setAllowsMultipleSelection_(False)
        panel.setAllowedFileTypes_(["mp3", "mp4", "m4a", "wav", "mov"])
        panel.setMessage_("Kies een audio- of videobestand om lokaal te transcriberen.")
        panel.setPrompt_("Transcribeer")
        if panel.runModal() == NSModalResponseOK and panel.URL() is not None:
            self.app.import_media(Path(panel.URL().path()))

    @objc.python_method
    def refresh(self, entries: list[HistoryEntry]) -> None:
        self._all_entries = list(entries)
        self._apply_filter()

    @objc.python_method
    def _apply_filter(self) -> None:
        selected_id = self._selected_entry_id()
        query = self.search_field.stringValue() if hasattr(self, "search_field") else ""
        self.entries = search_entries(self._all_entries, query)
        self.table.reloadData()

        total = len(self._all_entries)
        suffix = "transcriptie" if total == 1 else "transcripties"
        if query.strip():
            self.count_label.setStringValue_(
                f"{len(self.entries)} van {total} {suffix} (gefilterd)"
            )
        else:
            self.count_label.setStringValue_(
                f"{total} van maximaal {self.app.config.history_limit} {suffix}"
            )
        self.clear_button.setEnabled_(bool(self._all_entries))

        selected_index = next(
            (index for index, entry in enumerate(self.entries) if entry.id == selected_id),
            0 if self.entries else -1,
        )
        if selected_index >= 0:
            indexes = NSIndexSet.indexSetWithIndex_(selected_index)
            self.table.selectRowIndexes_byExtendingSelection_(indexes, False)
            self._show_entry(self.entries[selected_index])
        else:
            self._clear_entry()

    def searchChanged_(self, _sender) -> None:  # noqa: N802, ANN001
        self._apply_filter()

    @objc.python_method
    def _selected_entry_id(self) -> str | None:
        if not hasattr(self, "table"):
            return None
        row = self.table.selectedRow()
        if row < 0 or row >= len(self.entries):
            return None
        return self.entries[row].id

    @objc.python_method
    def _show_entry(self, entry: HistoryEntry) -> None:
        self._detail_entry_id = entry.id
        self.name_field.setStringValue_(entry.name)
        self.name_field.setEnabled_(True)
        self.detail_timestamp.setStringValue_(self._meta_line(entry))
        self.detail.setString_(entry.text)
        self.copy_button.setEnabled_(True)
        self.export_button.setEnabled_(True)
        self.delete_button.setEnabled_(True)
        self.pin_button.setEnabled_(True)
        self._set_button_title(
            self.pin_button, "Losmaken" if entry.pinned else "Vastzetten", MARINE
        )

    @objc.python_method
    def _meta_line(self, entry: HistoryEntry) -> str:
        parts = [self._format_timestamp(entry.timestamp)]
        if entry.source == "file":
            parts.append("Geimporteerd bestand")
        if entry.duration:
            parts.append(f"{int(round(entry.duration))}s")
        if entry.pinned:
            parts.append("Vastgezet")
        return "   ·   ".join(parts)

    @objc.python_method
    def _clear_entry(self) -> None:
        self._detail_entry_id = None
        self.name_field.setStringValue_("")
        self.name_field.setEnabled_(False)
        self.detail_timestamp.setStringValue_("")
        self.detail.setString_("Nog geen transcripties.")
        self.copy_button.setEnabled_(False)
        self.export_button.setEnabled_(False)
        self.delete_button.setEnabled_(False)
        self.pin_button.setEnabled_(False)
        self._set_button_title(self.pin_button, "Vastzetten", MARINE)

    @objc.python_method
    def _commit_name(self) -> None:
        entry_id = getattr(self, "_detail_entry_id", None)
        if not entry_id:
            return
        new_name = self.name_field.stringValue().strip()
        entry = next((item for item in self.entries if item.id == entry_id), None)
        if entry is None or entry.name == new_name:
            return
        self.app.rename_history_entry(entry_id, new_name)

    def nameFieldChanged_(self, _sender) -> None:  # noqa: N802, ANN001
        self._commit_name()

    def controlTextDidEndEditing_(self, notification) -> None:  # noqa: N802, ANN001
        if notification.object() == self.name_field:
            self._commit_name()

    def controlTextDidChange_(self, notification) -> None:  # noqa: N802, ANN001
        if notification.object() == self.search_field:
            self._apply_filter()

    def deleteSelected_(self, _sender) -> None:  # noqa: N802, ANN001
        row = self.table.selectedRow()
        if 0 <= row < len(self.entries):
            self.app.delete_history_entry(self.entries[row].id)

    def togglePin_(self, _sender) -> None:  # noqa: N802, ANN001
        row = self.table.selectedRow()
        if 0 <= row < len(self.entries):
            entry = self.entries[row]
            self.app.set_history_entry_pinned(entry.id, not entry.pinned)

    def numberOfRowsInTableView_(self, _table_view) -> int:  # noqa: N802, ANN001
        return len(self.entries)

    def tableView_viewForTableColumn_row_(  # noqa: N802, ANN001
        self, _table_view, table_column, row
    ) -> NSTableCellView:
        width = max(200, table_column.width())
        cell = NSTableCellView.alloc().initWithFrame_(NSMakeRect(0, 0, width, 74))
        entry = self.entries[row]

        prefix = "\U0001F4CC  " if entry.pinned else ""
        timestamp = NSTextField.labelWithString_(prefix + self._format_timestamp(entry.timestamp))
        timestamp.setFrame_(NSMakeRect(16, 48, width - 32, 16))
        timestamp.setFont_(body_font(11, "semibold"))
        timestamp.setTextColor_(TERRA)
        timestamp.setAutoresizingMask_(NSViewWidthSizable)
        cell.addSubview_(timestamp)

        named = bool(entry.name.strip())
        body_value = entry.name.strip() if named else entry.text.replace("\n", " ")
        body = NSTextField.labelWithString_(body_value)
        body.setFrame_(NSMakeRect(16, 10, width - 32, 34))
        body.setFont_(body_font(13, "semibold") if named else body_font(12.5))
        body.setTextColor_(MARINE)
        body.setUsesSingleLineMode_(False)
        body.cell().setLineBreakMode_(NSLineBreakByTruncatingTail)
        body.setAutoresizingMask_(NSViewWidthSizable)
        cell.addSubview_(body)
        return cell

    def tableView_rowViewForRow_(self, _table_view, _row) -> NSTableRowView:  # noqa: N802, ANN001
        return NightStoryTableRowView.alloc().init()

    def tableViewSelectionDidChange_(self, _notification) -> None:  # noqa: N802, ANN001
        self._commit_name()
        row = self.table.selectedRow()
        if row < 0 or row >= len(self.entries):
            self._clear_entry()
            return
        self._show_entry(self.entries[row])

    def copySelected_(self, _sender) -> None:  # noqa: N802, ANN001
        row = self.table.selectedRow()
        if 0 <= row < len(self.entries):
            self.app.copy_history_entry(self.entries[row].id)

    def exportSelected_(self, _sender) -> None:  # noqa: N802, ANN001
        row = self.table.selectedRow()
        if row < 0 or row >= len(self.entries):
            return
        entry = self.entries[row]
        panel = NSSavePanel.savePanel()
        panel.setAllowedFileTypes_(list(EXPORT_EXTENSIONS))
        panel.setCanCreateDirectories_(True)
        panel.setNameFieldStringValue_(suggested_export_name(entry))
        panel.setMessage_("Kies een extensie: txt, md, json, srt of vtt.")
        panel.setPrompt_("Bewaar")
        if panel.runModal() == NSModalResponseOK and panel.URL() is not None:
            saved_path = self.app.export_history_entry(entry.id, Path(panel.URL().path()))
            if saved_path is not None:
                self.status_label.setStringValue_(f"Bewaard: {saved_path.name}")
                self.status_label.setTextColor_(TEAL)

    def clearHistory_(self, _sender) -> None:  # noqa: N802, ANN001
        alert = NSAlert.alloc().init()
        alert.setMessageText_("Geschiedenis wissen?")
        alert.setInformativeText_("De bewaarde transcripties worden definitief verwijderd.")
        alert.addButtonWithTitle_("Wis geschiedenis")
        alert.addButtonWithTitle_("Annuleer")
        if alert.runModal() == NSAlertFirstButtonReturn:
            self.app.clear_history()

    @objc.python_method
    def _format_timestamp(self, timestamp: datetime) -> str:
        now = datetime.now(timestamp.tzinfo)
        if timestamp.date() == now.date():
            return f"Vandaag, {timestamp:%H:%M}"
        return timestamp.strftime("%d-%m-%Y, %H:%M")


def make_history_menu_item(target: NSObject) -> NSMenuItem:
    item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
        "Open Whisper Clipboard", "openHistory:", "g"
    )
    item.setTarget_(target)
    return item
