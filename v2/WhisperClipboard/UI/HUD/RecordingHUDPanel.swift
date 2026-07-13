import AppKit
import Combine
import SwiftUI

/// A non-activating floating panel that hosts the ``RecordingHUDView`` at the
/// bottom-center of the active screen. Shows on record start and fades out
/// shortly after completion.
@MainActor
final class RecordingHUDController {
    private let controller: DictationController
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    /// Monotonic token invalidating a stale hide-fade completion. `showPanel()` and
    /// `hidePanel()` both bump it, so a hide animation that finishes *after* a new
    /// recording re-showed the panel never orders the live HUD off screen.
    private var showHideGeneration = 0

    /// Supplies the `NSAppearance` the panel should adopt so its dynamic `Theme`
    /// colors resolve to the user-chosen palette (`nil` → follow the system).
    /// Set by `AppEnvironment` from `settings.appearance`.
    var appearanceProvider: () -> NSAppearance? = { nil }

    init(controller: DictationController) {
        self.controller = controller
        observePhase()
    }

    /// Re-applies the current appearance to a live panel (called when the user
    /// switches the theme while the HUD may be on screen).
    func applyAppearance() {
        panel?.appearance = appearanceProvider()
    }

    private func observePhase() {
        controller.$phase
            .removeDuplicates()
            .sink { [weak self] phase in
                self?.handle(phase: phase)
            }
            .store(in: &cancellables)
    }

    private func handle(phase: DictationController.Phase) {
        switch phase {
        case .recording, .paused, .transcribing, .finished:
            showPanel()
        case .idle:
            hidePanel()
        }
    }

    /// Vertical drift used on entrance/exit: the panel starts slightly below
    /// (and ends slightly below, on exit) its resting position for a subtle
    /// upward-arrival / downward-departure motion.
    private static let entranceDrift: CGFloat = 8

    // MARK: - Panel

    private func showPanel() {
        // Invalidate any in-flight hide-fade completion so it can't order this
        // (re-shown) panel off screen after we bring it forward.
        showHideGeneration += 1
        let isFreshShow = panel == nil
        if panel == nil {
            panel = makePanel()
        }
        guard let panel else { return }
        // Adopt the chosen palette every show (the theme may have changed since
        // the panel was created).
        panel.appearance = appearanceProvider()

        panel.layoutIfNeeded()

        if isFreshShow {
            // Open at the remembered (or default bottom-center) position, arriving
            // with a subtle upward drift + fade.
            let restingOrigin = restingOrigin(for: panel)
            panel.setFrameOrigin(NSPoint(x: restingOrigin.x, y: restingOrigin.y - Self.entranceDrift))
            panel.alphaValue = 0
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrameOrigin(restingOrigin)
            }
        } else {
            // Already visible (recording → transcribing → finished): leave it
            // exactly where it is — including wherever the user just dragged it —
            // and only ensure it's fully opaque and frontmost.
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    private func hidePanel() {
        guard let panel else { return }
        // Remember where the user left the panel so the next recording reopens
        // there (captured before the exit animation nudges it).
        Self.saveOrigin(panel.frame.origin)
        showHideGeneration += 1
        let myGeneration = showHideGeneration
        let restingOrigin = panel.frame.origin
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
            panel.animator().setFrameOrigin(NSPoint(x: restingOrigin.x, y: restingOrigin.y - Self.entranceDrift))
        } completionHandler: { [weak self] in
            // Skip the orderOut if a newer show/hide happened while we faded — the
            // panel may have been re-shown for a fresh recording.
            guard let self, self.showHideGeneration == myGeneration else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let showLatency = UserDefaults.standard.bool(forKey: "showLatencyHUD")
        let root = RecordingHUDView(
            controller: controller,
            levelMeter: controller.audioEngine.levelMeter,
            showLatency: showLatency
        )
        let hosting = NSHostingController(rootView: root)
        hosting.view.frame.size = hosting.view.fittingSize

        let panel = NonKeyPanel(
            contentRect: NSRect(origin: .zero, size: hosting.view.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        // Draggable by its background; interactive controls (the stop button)
        // still consume their own clicks. Position is remembered across sessions.
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.contentViewController = hosting
        panel.setContentSize(hosting.view.fittingSize)
        return panel
    }

    /// The panel's opening position: the user's remembered spot when it's still
    /// (mostly) on a visible screen, otherwise the default bottom-center.
    private func restingOrigin(for panel: NSPanel) -> NSPoint {
        let size = panel.frame.size
        if let saved = Self.savedOrigin(), Self.isReasonablyVisible(origin: saved, size: size) {
            return saved
        }
        let visible = Self.activeScreen().visibleFrame
        return NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 80)
    }

    /// Screen containing the mouse, falling back to the main screen.
    private static func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    // MARK: - Remembered position

    private static let originXKey = "hudOriginX"
    private static let originYKey = "hudOriginY"

    private static func saveOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set(Double(origin.x), forKey: originXKey)
        UserDefaults.standard.set(Double(origin.y), forKey: originYKey)
    }

    private static func savedOrigin() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: originXKey) != nil,
              defaults.object(forKey: originYKey) != nil else { return nil }
        return NSPoint(x: defaults.double(forKey: originXKey), y: defaults.double(forKey: originYKey))
    }

    /// A saved origin is only reused when a meaningful chunk of the panel would
    /// still land on some screen, so a disconnected monitor can't strand the HUD
    /// off screen (it then falls back to the default position).
    private static func isReasonablyVisible(origin: NSPoint, size: NSSize) -> Bool {
        let rect = NSRect(origin: origin, size: size)
        return NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(rect)
            return overlap.width >= 60 && overlap.height >= 20
        }
    }
}

/// An `NSPanel` that never becomes key or main so it stays a passive overlay.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
