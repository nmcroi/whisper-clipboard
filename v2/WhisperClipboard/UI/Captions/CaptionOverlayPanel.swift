import AppKit
import Combine
import SwiftUI

/// Hosts the ``CaptionOverlayView`` in a non-activating floating panel at the
/// bottom-centre of the active screen, shown while a caption session runs.
///
/// Reuses the ``RecordingHUDPanel`` pattern: borderless `.nonactivatingPanel`,
/// `.statusBar` level, joins all Spaces + full-screen aux, never becomes key.
/// Unlike the HUD it is wide (~70% of the screen, max 900pt) and draggable by
/// its background (`isMovableByWindowBackground`).
@MainActor
final class CaptionOverlayController {
    private let service: CaptionsService
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    init(service: CaptionsService) {
        self.service = service
        observeRunning()
    }

    private func observeRunning() {
        service.$isRunning
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] running in
                if running { self?.showPanel() } else { self?.hidePanel() }
            }
            .store(in: &cancellables)
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
            context.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let root = CaptionOverlayView(service: service) { [weak self] in
            self?.service.stop()
        }
        let hosting = NSHostingController(rootView: root)

        let panel = NonKeyCaptionPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: Self.panelWidth(), height: 120)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.contentViewController = hosting
        panel.setContentSize(NSSize(width: Self.panelWidth(), height: hosting.view.fittingSize.height))
        return panel
    }

    /// ~70% of the active screen width, capped at 900pt.
    private static func panelWidth() -> CGFloat {
        let screenWidth = activeScreen().visibleFrame.width
        return min(900, screenWidth * 0.7)
    }

    private func positionAtBottomCenter(_ panel: NSPanel) {
        let width = Self.panelWidth()
        panel.setContentSize(NSSize(width: width, height: panel.frame.height))
        let visible = Self.activeScreen().visibleFrame
        panel.layoutIfNeeded()
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 100
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private static func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

/// An `NSPanel` that never becomes key or main (passive overlay).
private final class NonKeyCaptionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
