import Core
import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global dictation toggle. Default ⌃Space.
    static let toggleDictation = Self(
        "toggleDictation",
        default: .init(.space, modifiers: [.control])
    )
}

/// Binds the global dictation hotkey to the controller, honoring the current
/// ``AppSettings/hotkeyMode``. In toggle mode a key-down toggles; in
/// push-to-talk mode key-down starts and key-up stops. Debounce lives in the
/// controller.
@MainActor
final class HotkeyManager {
    private let controller: DictationController
    private let modeProvider: () -> AppSettings.HotkeyMode

    init(controller: DictationController, modeProvider: @escaping () -> AppSettings.HotkeyMode) {
        self.controller = controller
        self.modeProvider = modeProvider
        installHandlers()
    }

    private func installHandlers() {
        KeyboardShortcuts.onKeyDown(for: .toggleDictation) { [weak self] in
            guard let self else { return }
            switch self.modeProvider() {
            case .toggle:
                self.controller.toggle()
            case .pushToTalk:
                self.controller.pushToTalkDown()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .toggleDictation) { [weak self] in
            guard let self else { return }
            if self.modeProvider() == .pushToTalk {
                self.controller.pushToTalkUp()
            }
        }
    }

    /// Human-readable current shortcut (e.g. "⌃Space") for display in the UI.
    var shortcutDescription: String {
        KeyboardShortcuts.getShortcut(for: .toggleDictation)?.description ?? "⌃Space"
    }
}
