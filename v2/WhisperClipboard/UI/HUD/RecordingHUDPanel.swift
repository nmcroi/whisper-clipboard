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

    init(controller: DictationController) {
        self.controller = controller
        observePhase()
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
        case .recording, .transcribing, .finished:
            showPanel()
        case .idle:
            hidePanel()
        }
    }

    // MARK: - Panel

    private func showPanel() {
        if panel == nil {
            panel = makePanel()
        }
        guard let panel else { return }
        positionAtBottomCenter(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
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
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.contentViewController = hosting
        panel.setContentSize(hosting.view.fittingSize)
        return panel
    }

    private func positionAtBottomCenter(_ panel: NSPanel) {
        let screen = Self.activeScreen()
        let visible = screen.visibleFrame
        panel.layoutIfNeeded()
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 80
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Screen containing the mouse, falling back to the main screen.
    private static func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

/// An `NSPanel` that never becomes key or main so it stays a passive overlay.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
