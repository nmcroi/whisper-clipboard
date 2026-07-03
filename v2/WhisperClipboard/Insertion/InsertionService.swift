import AppKit
import Core

/// Abstracts the actual keystroke synthesis so `InsertionService`'s decision and
/// pasteboard logic can be unit-tested with a mock (a real `CGEvent` paste can't
/// be exercised in a headless test — it needs AX permission and a foreground app).
@MainActor
protocol KeystrokeSynthesizer {
    /// Synthesizes Cmd+V. Returns `false` if the events couldn't be created/posted.
    @discardableResult
    func sendPaste() -> Bool
}

/// Real synthesizer: posts Cmd+V via `CGEvent` on the session event tap.
struct CGEventKeystrokeSynthesizer: KeystrokeSynthesizer {
    /// Virtual keycode for the 'v' key on a US layout (kVK_ANSI_V). Cmd+V is
    /// layout-independent for paste on macOS, so the ANSI 'v' keycode is correct.
    private static let vKeyCode: CGKeyCode = 9

    @discardableResult
    func sendPaste() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false)
        else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
        return true
    }
}

/// The outcome of an insertion attempt, reported back to the caller so the HUD
/// and metrics can reflect what happened.
enum InsertionOutcome: Equatable {
    /// Text was pasted into the target app.
    case inserted
    /// Text was left on the clipboard only (insertion skipped or failed).
    case clipboardOnly(reason: InsertionDecision.ClipboardOnlyReason)
    /// Insertion was attempted but the keystroke couldn't be posted (CGEvent
    /// failure); text remains on the clipboard as a fallback.
    case insertionFailed
}

/// Direct text insertion (Wispr Flow style): writes the text to the pasteboard,
/// synthesizes Cmd+V into the frontmost app, then restores the user's previous
/// clipboard contents — but only if the pasteboard still holds our text.
@MainActor
final class InsertionService {

    /// Delay between issuing the paste and restoring the previous clipboard. Must
    /// be long enough that the target app has consumed the pasteboard (read Cmd+V)
    /// before we overwrite it, but short enough to feel instantaneous. 120 ms is a
    /// comfortable margin across apps in testing.
    static let restoreDelayMs: Int = 120

    private let synthesizer: any KeystrokeSynthesizer
    private let pasteboard: NSPasteboard

    init(
        synthesizer: any KeystrokeSynthesizer = CGEventKeystrokeSynthesizer(),
        pasteboard: NSPasteboard = .general
    ) {
        self.synthesizer = synthesizer
        self.pasteboard = pasteboard
    }

    /// Captures the current frontmost application as the insertion target. Call
    /// at recording start, before the (non-activating) HUD appears.
    static func captureFrontmost() -> InsertionTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return InsertionTarget(bundleId: app.bundleIdentifier, processIdentifier: app.processIdentifier)
    }

    private static func currentFrontmost() -> InsertionTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return InsertionTarget(bundleId: app.bundleIdentifier, processIdentifier: app.processIdentifier)
    }

    /// Attempts to deliver `text` to the target app. The text is assumed to be
    /// already on the clipboard by the caller (dictation copies it first), so a
    /// clipboard-only outcome is a no-op beyond reporting.
    ///
    /// - Parameters:
    ///   - text: the processed transcript.
    ///   - settings: current settings (toggle + deny list).
    ///   - target: the app captured at recording start.
    /// - Returns: what happened, for HUD/metrics/notification.
    @discardableResult
    func insert(
        _ text: String,
        settings: AppSettings,
        target: InsertionTarget?
    ) -> InsertionOutcome {
        let decision = InsertionPolicy.decide(
            directInsertionEnabled: settings.directInsertion,
            accessibilityGranted: AccessibilityPermission.isGranted,
            capturedTarget: target,
            currentFrontmost: Self.currentFrontmost(),
            deniedBundleIds: settings.insertionDeniedBundleIds
        )

        guard decision == .insert else {
            if case .clipboardOnly(let reason) = decision {
                return .clipboardOnly(reason: reason)
            }
            return .clipboardOnly(reason: .disabled)
        }

        // (a) Save the current pasteboard string (best-effort) + change count.
        let previousString = pasteboard.string(forType: .string)

        // (b) Write our text to the pasteboard.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCountAfterWrite = pasteboard.changeCount

        // (c) Synthesize Cmd+V.
        guard synthesizer.sendPaste() else {
            // CGEvent failed: leave our text on the clipboard as the fallback.
            return .insertionFailed
        }

        // (d) After a short delay, restore the previous clipboard — but only if
        //     the pasteboard still holds our text (nothing else wrote since).
        let pb = pasteboard
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Self.restoreDelayMs))
            if PasteboardRestore.shouldRestore(
                changeCountAfterWrite: changeCountAfterWrite,
                currentChangeCount: pb.changeCount
            ) {
                pb.clearContents()
                if let previousString {
                    pb.setString(previousString, forType: .string)
                }
                // If there was no previous string we simply leave it cleared,
                // which is the closest restoration of "nothing meaningful there".
            }
        }

        return .inserted
    }
}
