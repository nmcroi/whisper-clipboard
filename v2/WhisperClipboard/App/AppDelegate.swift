import AppKit
import Combine
import Core
import Sparkle
import SwiftUI

/// Owns the menu bar status item and drives the app's activation policy so the
/// Dock icon only appears while a window is open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment = AppEnvironment()

    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var recordMenuItem: NSMenuItem?
    private var captionsMenuItem: NSMenuItem?
    private var downloadMenuItem: NSMenuItem?
    private var recentsHeaderItem: NSMenuItem?
    /// The recent-transcript menu items (rebuilt from the history store).
    private var recentItems: [NSMenuItem] = []
    /// The menu index at which recent items are inserted.
    private var recentsInsertionIndex = 0
    private weak var menu: NSMenu?
    private var openWindowCount = 0
    private var cancellables = Set<AnyCancellable>()

    /// Sparkle auto-updater. Non-sandboxed app, so the simple integration:
    /// the standard controller starts the updater at launch (reading SUFeedURL /
    /// SUPublicEDKey from Info.plist) and drives the built-in update UI. It also
    /// serves as the target for the "Controleer op updates…" menu item via its
    /// `checkForUpdates(_:)` action (which auto-enables/disables itself).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar utility: no Dock icon until a window opens.
        NSApp.setActivationPolicy(.accessory)

        setUpStatusItem()
        observeState()
        observeDictation()
        observeWindows()

        // Re-skin the status-item menu when the user switches the theme (the menu
        // is pure AppKit, outside SwiftUI's colour-scheme environment).
        environment.onAppearanceChange = { [weak self] _ in self?.applyAppearance() }
        applyAppearance()

        environment.bootstrap()
    }

    /// Pins the status item's button and menu to the chosen appearance so the
    /// menu chrome and the recording-state icon tint match the app's theme
    /// (`nil` → follow the system). SwiftUI windows handle themselves.
    private func applyAppearance() {
        let appearance = environment.settings.appearance.nsAppearance
        statusItem?.button?.appearance = appearance
        menu?.appearance = appearance
        // Refresh the icon so a colour tint (recording state) re-resolves.
        updateStatusIcon(for: environment.appState)
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

        let download = makeItem(title: "Parakeet-model downloaden (494 MB)…", action: #selector(downloadModel), key: "")
        download.isHidden = true
        menu.addItem(download)
        downloadMenuItem = download

        let captions = makeItem(title: "Live ondertitels starten", action: #selector(toggleCaptions), key: "l")
        menu.addItem(captions)
        captionsMenuItem = captions

        menu.addItem(
            makeItem(title: "Bestand importeren…", action: #selector(importFile), key: "i")
        )

        menu.addItem(
            makeItem(title: "Open Whisper Clipboard", action: #selector(openHome), key: "o")
        )
        menu.addItem(
            makeItem(title: "Geschiedenis", action: #selector(openHistory), key: "")
        )

        // AI-modus op laatste transcript → submenu of the four built-in modes.
        let aiItem = NSMenuItem(title: "AI-modus op laatste transcript", action: nil, keyEquivalent: "")
        let aiSubmenu = NSMenu()
        for mode in AIMode.builtins {
            let item = NSMenuItem(title: mode.name, action: #selector(runAIMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.id
            aiSubmenu.addItem(item)
        }
        aiItem.submenu = aiSubmenu
        menu.addItem(aiItem)

        menu.addItem(.separator())

        // Recent transcripts section (like the old Python menu bar). The header
        // is disabled; the items below it copy their text on click.
        let recentsHeader = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        recentsHeader.isEnabled = false
        menu.addItem(recentsHeader)
        recentsHeaderItem = recentsHeader
        recentsInsertionIndex = menu.index(of: recentsHeader) + 1
        let recentsSeparator = NSMenuItem.separator()
        menu.addItem(recentsSeparator)

        menu.addItem(
            makeItem(title: "Instellingen…", action: #selector(openSettings), key: ",")
        )

        // Sparkle "check for updates" — target the updater controller directly so
        // it validates/enables the item itself (disabled while a check is running).
        let updates = NSMenuItem(
            title: "Controleer op updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updates.target = updaterController
        menu.addItem(updates)

        menu.addItem(
            makeItem(title: "Stop Whisper Clipboard", action: #selector(quit), key: "q")
        )

        item.menu = menu
        self.menu = menu
        statusItem = item
        updateStatusIcon(for: environment.appState)
        updateMenuItems()
        refreshRecents()
    }

    /// Rebuilds the recent-transcript menu items from the history store (top 5).
    private func refreshRecents() {
        guard let menu else { return }
        for item in recentItems { menu.removeItem(item) }
        recentItems.removeAll()

        let entries = (try? environment.history.recent(5)) ?? []
        recentsHeaderItem?.isHidden = entries.isEmpty

        for (offset, entry) in entries.enumerated() {
            let item = NSMenuItem(
                title: Self.recentTitle(for: entry),
                action: #selector(copyRecent(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.text
            item.toolTip = entry.text
            menu.insertItem(item, at: recentsInsertionIndex + offset)
            recentItems.append(item)
        }
    }

    /// A short, single-line menu title for a recent entry (name or first words).
    private static func recentTitle(for entry: Core.TranscriptEntry) -> String {
        let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = name.isEmpty
            ? entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            : name
        let singleLine = base.replacingOccurrences(of: "\n", with: " ")
        if singleLine.count > 48 {
            return String(singleLine.prefix(48)) + "…"
        }
        return singleLine.isEmpty ? "Zonder titel" : singleLine
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

        // Live captions: only offered once the model is ready.
        captionsMenuItem?.isHidden = !ready
        captionsMenuItem?.title = environment.captions.isRunning
            ? "Live ondertitels stoppen"
            : "Live ondertitels starten"

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
            button.image = image?.tinted(with: NSColor(Theme.danger))
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

        // Keep the menu-bar recents in sync with the history store.
        environment.history.$revision
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshRecents() }
            .store(in: &cancellables)

        // Keep the captions menu item's title in sync with the session state.
        environment.captions.$isRunning
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

    @objc private func toggleCaptions() {
        environment.toggleCaptions()
    }

    @objc private func downloadModel() {
        environment.downloadModel()
    }

    @objc private func importFile() {
        // Bring the window forward so the queue panel is visible, then present
        // the open panel and enqueue the chosen files.
        environment.menuNavigationRequest = .home
        showMainWindow()
        MediaOpenPanel.present { [weak self] urls in
            self?.environment.fileImport.importFiles(urls)
        }
    }

    @objc private func openHome() {
        environment.menuNavigationRequest = .home
        showMainWindow()
    }

    @objc private func openHistory() {
        environment.menuNavigationRequest = .history(id: nil)
        showMainWindow()
    }

    /// Copies a recent transcript's text to the clipboard (menu item action).
    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        Clipboard.copy(text)
        Notifications.post("Tekst staat op je klembord")
    }

    /// Runs a built-in AI mode on the most recent transcript, copies the result
    /// to the clipboard, and posts a notification. Errors surface as a
    /// notification (menu-bar flows have no inline UI to show them).
    @objc private func runAIMode(_ sender: NSMenuItem) {
        guard let modeId = sender.representedObject as? String,
              let mode = AIMode.builtins.first(where: { $0.id == modeId })
        else { return }

        guard let entry = (try? environment.history.recent(1))?.first else {
            Notifications.post("Er is nog geen transcriptie om te verwerken")
            return
        }

        Notifications.post("Claude verwerkt je transcriptie met '\(mode.name)'…")
        Task {
            do {
                let result = try await environment.modes.runToCompletion(mode: mode, on: entry)
                Clipboard.copy(result.output)
                Notifications.post("'\(mode.name)' klaar — resultaat staat op je klembord")
            } catch let error as ClaudeError {
                Notifications.post(error.localizedDescription)
            } catch {
                Notifications.post("Er ging iets mis bij het verwerken met Claude")
            }
        }
    }

    /// Activates the app and brings the main window forward, opening it if needed.
    private func showMainWindow() {
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
