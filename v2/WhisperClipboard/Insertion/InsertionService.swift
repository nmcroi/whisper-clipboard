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

    /// Momentopname van het klembord zoals het was VÓÓRDAT wij onze transcriptie
    /// erop schrijven. Moet worden gemaakt door de aanroeper (DictationController)
    /// vlak vóór `Clipboard.copy`, anders leest de restore-stap onze eigen tekst
    /// terug als "vorige inhoud" en gaat het echte klembord van de gebruiker
    /// verloren. Bevat de string plus of het een verhulde/geheime waarde was.
    struct PasteboardSnapshot {
        let previousString: String?
        let previousWasConcealed: Bool
    }

    /// Leest het huidige klembord uit als snapshot. Roep dit aan VÓÓR de
    /// transcriptie op het klembord wordt gezet.
    func snapshotPasteboard() -> PasteboardSnapshot {
        let previousString = pasteboard.string(forType: .string)
        let previousTypeNames = (pasteboard.types ?? []).map(\.rawValue)
        let previousWasConcealed = PasteboardRestore.isConcealed(typeNames: previousTypeNames)
        return PasteboardSnapshot(
            previousString: previousString,
            previousWasConcealed: previousWasConcealed
        )
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
    ///   - snapshot: het klembord zoals het was VÓÓR de transcriptie erop kwam.
    ///     De aanroeper maakt deze met `snapshotPasteboard()` vlak vóór
    ///     `Clipboard.copy`, zodat de restore-stap het échte vorige klembord van
    ///     de gebruiker terugzet i.p.v. onze eigen transcriptie. Nil = geen
    ///     snapshot beschikbaar (dan valt de restore terug op leegmaken).
    /// - Returns: what happened, for HUD/metrics/notification.
    @discardableResult
    func insert(
        _ text: String,
        settings: AppSettings,
        target: InsertionTarget?,
        snapshot: PasteboardSnapshot?
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

        // (a) Neem het klembord van VÓÓR onze transcriptie over uit de snapshot
        //     die de aanroeper maakte (zie `snapshotPasteboard()`). We lezen het
        //     hier NIET zelf: op dit punt staat onze eigen transcriptie er al op
        //     (dictation kopieert eerst), dus zelf lezen zou onze tekst als
        //     "vorige inhoud" opslaan en het echte klembord van de gebruiker
        //     wissen. `previousWasConcealed` markeert een verhuld/geheim item
        //     (bv. een wachtwoordmanager-entry): die mag NIET als platte string
        //     worden teruggezet, wat de markers zou strippen en het geheim naar
        //     klembord-historie-tools zou lekken.
        let previousString = snapshot?.previousString
        let previousWasConcealed = snapshot?.previousWasConcealed ?? false

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
                // Only restore a plain string when the previous item was NOT a
                // concealed/transient secret. Re-writing a password as ordinary
                // plain text would strip its ConcealedType/TransientType markers
                // and expose it to clipboard-history managers — so for those we
                // leave the pasteboard cleared instead.
                if let previousString, !previousWasConcealed {
                    pb.setString(previousString, forType: .string)
                }
                // If there was no previous string (or it was concealed) we leave it
                // cleared — the safest approximation of "nothing to expose here".
            }
        }

        return .inserted
    }
}
