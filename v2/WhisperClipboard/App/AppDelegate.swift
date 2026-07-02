import AppKit
import Combine
import SwiftUI

/// Owns the menu bar status item and drives the app's activation policy so the
/// Dock icon only appears while a window is open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment = AppEnvironment()

    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var recordMenuItem: NSMenuItem?
    private var downloadMenuItem: NSMenuItem?
    private var openWindowCount = 0
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar utility: no Dock icon until a window opens.
        NSApp.setActivationPolicy(.accessory)

        setUpStatusItem()
        observeState()
        observeDictation()
        observeWindows()

        environment.bootstrap()
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()

        let statusLine = NSMenuItem(title: environment.appState.statusText, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        statusMenuItem = statusLine

        menu.addItem(.separator())

        let record = makeItem(title: "Start opname", action: #selector(toggleRecording), key: "r")
        menu.addItem(record)
        recordMenuItem = record

        let download = makeItem(title: "Nederlands model downloaden…", action: #selector(downloadModel), key: "")
        download.isHidden = true
        menu.addItem(download)
        downloadMenuItem = download

        menu.addItem(
            makeItem(title: "Open Whisper Clipboard", action: #selector(openHome), key: "o")
        )

        menu.addItem(.separator())

        menu.addItem(
            makeItem(title: "Instellingen…", action: #selector(openSettings), key: ",")
        )
        menu.addItem(
            makeItem(title: "Stop Whisper Clipboard", action: #selector(quit), key: "q")
        )

        item.menu = menu
        statusItem = item
        updateStatusIcon(for: environment.appState)
        updateMenuItems()
    }

    /// Reflects model availability + recording phase in the menu item titles.
    private func updateMenuItems() {
        let status = environment.modelManager.status
        let ready = status.isReady
        let unsupported = status == .unsupported
        // Offer the download only when the model is installable (not when ready
        // and not when the language is unsupported on this OS).
        downloadMenuItem?.isHidden = ready || unsupported
        recordMenuItem?.isHidden = !ready

        switch environment.dictation.phase {
        case .recording:
            recordMenuItem?.title = "Stop opname"
            recordMenuItem?.isEnabled = true
        case .transcribing:
            recordMenuItem?.title = "Transcriberen…"
            recordMenuItem?.isEnabled = false
        case .idle, .finished:
            recordMenuItem?.title = "Start opname"
            recordMenuItem?.isEnabled = true
        }
    }

    private func makeItem(title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func updateStatusIcon(for state: AppState) {
        guard let button = statusItem?.button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(
            systemSymbolName: state.symbolName,
            accessibilityDescription: state.statusText
        )?.withSymbolConfiguration(config)

        if state.isRecording {
            image?.isTemplate = false
            button.image = image?.tinted(with: NSColor(NightStory.terra))
        } else {
            image?.isTemplate = true
            button.image = image
        }
    }

    // MARK: - Observation

    private func observeState() {
        environment.$appState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.statusMenuItem?.title = state.statusText
                self?.updateStatusIcon(for: state)
                self?.updateMenuItems()
            }
            .store(in: &cancellables)
    }

    private func observeDictation() {
        environment.dictation.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMenuItems() }
            .store(in: &cancellables)

        environment.modelManager.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMenuItems() }
            .store(in: &cancellables)
    }

    private func observeWindows() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    // MARK: - Activation policy

    private var trackedWindows = Set<ObjectIdentifier>()

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isAppWindow(window) else { return }
        let id = ObjectIdentifier(window)
        guard !trackedWindows.contains(id) else { return }
        trackedWindows.insert(id)
        openWindowCount += 1
        NSApp.setActivationPolicy(.regular)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isAppWindow(window) else { return }
        let id = ObjectIdentifier(window)
        guard trackedWindows.contains(id) else { return }
        trackedWindows.remove(id)
        openWindowCount = max(0, openWindowCount - 1)
        if openWindowCount == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Ignore panels and the status-bar window; only track real content windows.
    private func isAppWindow(_ window: NSWindow) -> Bool {
        window.canBecomeMain && !(window is NSPanel)
    }

    // MARK: - Actions

    @objc private func toggleRecording() {
        environment.dictation.toggle()
    }

    @objc private func downloadModel() {
        environment.downloadModel()
    }

    @objc private func openHome() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where isAppWindow(window) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // No window yet: ask SwiftUI to open the "main" scene.
        openMainWindowViaMenu()
    }

    private func openMainWindowViaMenu() {
        // In a menu-bar-only launch there may be no window; the SwiftUI Window
        // scene provides a default "New Window" menu action we can invoke.
        if let action = NSSelectorFromString("newWindowForTab:") as Selector?,
           NSApp.sendAction(action, to: nil, from: nil) {
            return
        }
        NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Helpers

private extension NSImage {
    /// Returns a copy of the image tinted with `color` (for the recording state).
    func tinted(with color: NSColor) -> NSImage {
        let image = copy() as! NSImage
        image.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: image.size)
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
