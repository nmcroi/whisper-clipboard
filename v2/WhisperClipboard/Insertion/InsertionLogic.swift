import Foundation

/// Pure, side-effect-free decision logic for direct text insertion. Isolated
/// from AppKit/CGEvent so it can be unit-tested without a running window server.

/// What the insertion pipeline should do for a given run, decided *before*
/// touching the pasteboard or synthesizing keystrokes.
enum InsertionDecision: Equatable {
    /// Attempt to paste into the target app.
    case insert
    /// Skip insertion; leave the text on the clipboard only. Carries a reason
    /// for logging/metrics (not shown to the user directly).
    case clipboardOnly(reason: ClipboardOnlyReason)

    enum ClipboardOnlyReason: Equatable {
        case disabled              // direct insertion toggle is off
        case noAccessibility       // AX permission not granted
        case ownApp                // frontmost is Whisper Clipboard itself
        case frontmostChanged      // frontmost app changed since capture
        case deniedApp             // target bundle id is on the deny list
        case noTarget              // no target app captured
    }
}

/// The identity of the app captured at recording start, verified at insert time.
struct InsertionTarget: Equatable {
    let bundleId: String?
    let processIdentifier: pid_t
}

enum InsertionPolicy {

    /// Bundle id of Whisper Clipboard itself, so we never paste into our own UI.
    static let ownBundleId = "nl.nielscroiset.whisperclipboard"

    /// Case-insensitive deny-list membership test.
    static func isDenied(bundleId: String?, deniedBundleIds: [String]) -> Bool {
        guard let bundleId, !bundleId.isEmpty else { return false }
        return deniedBundleIds.contains { $0.caseInsensitiveCompare(bundleId) == .orderedSame }
    }

    /// The full pre-insertion decision.
    ///
    /// - Parameters:
    ///   - directInsertionEnabled: the settings toggle.
    ///   - accessibilityGranted: whether AX trust is currently granted.
    ///   - capturedTarget: the app captured at recording start (`nil` if none).
    ///   - currentFrontmost: the app that is frontmost right now, at insert time.
    ///   - deniedBundleIds: the per-app deny list.
    ///   - ownBundleId: this app's bundle id.
    static func decide(
        directInsertionEnabled: Bool,
        accessibilityGranted: Bool,
        capturedTarget: InsertionTarget?,
        currentFrontmost: InsertionTarget?,
        deniedBundleIds: [String],
        ownBundleId: String = InsertionPolicy.ownBundleId
    ) -> InsertionDecision {
        guard directInsertionEnabled else { return .clipboardOnly(reason: .disabled) }
        guard accessibilityGranted else { return .clipboardOnly(reason: .noAccessibility) }
        guard let target = capturedTarget else { return .clipboardOnly(reason: .noTarget) }

        // Never insert into our own app.
        if let id = target.bundleId, id.caseInsensitiveCompare(ownBundleId) == .orderedSame {
            return .clipboardOnly(reason: .ownApp)
        }
        // If frontmost drifted to our own app since capture, don't paste blindly.
        if let front = currentFrontmost,
           let id = front.bundleId,
           id.caseInsensitiveCompare(ownBundleId) == .orderedSame {
            return .clipboardOnly(reason: .frontmostChanged)
        }
        // Frontmost app changed to a *different* app than the one we captured:
        // the paste would land somewhere the user didn't intend. Fall back.
        if let front = currentFrontmost, front.processIdentifier != target.processIdentifier {
            return .clipboardOnly(reason: .frontmostChanged)
        }
        // Per-app deny list.
        if isDenied(bundleId: target.bundleId, deniedBundleIds: deniedBundleIds) {
            return .clipboardOnly(reason: .deniedApp)
        }
        return .insert
    }
}

/// Pure decision for whether to restore the previous pasteboard string after a
/// paste. We only restore when the pasteboard still holds *our* text — i.e. its
/// change count hasn't moved past the write we made. If something else wrote to
/// the pasteboard in the meantime, we leave that newer content alone.
enum PasteboardRestore {
    /// - Parameters:
    ///   - changeCountAfterWrite: `NSPasteboard.changeCount` immediately after we
    ///     wrote our text.
    ///   - currentChangeCount: `changeCount` observed now (after the paste delay).
    /// - Returns: `true` when it is safe to overwrite the pasteboard with the
    ///   previously-saved contents.
    static func shouldRestore(changeCountAfterWrite: Int, currentChangeCount: Int) -> Bool {
        currentChangeCount == changeCountAfterWrite
    }

    /// Pasteboard type markers password managers (1Password, Keychain, Raycast…)
    /// attach so clipboard-history tools skip the value and macOS auto-expires it.
    /// See the de-facto NSPasteboard convention. We must never re-write such an
    /// item back as a plain `public.utf8-plain-text` string.
    static let concealedTypeNames: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
    ]

    /// Whether a saved clipboard item (identified by the pasteboard type names it
    /// carried) was concealed/transient and therefore must NOT be restored as a
    /// plain string — doing so would strip its markers and leak a password into
    /// clipboard-history managers. When `true`, the caller skips restoring the
    /// string (leaving the pasteboard cleared) rather than re-exposing the secret.
    static func isConcealed(typeNames: [String]) -> Bool {
        !concealedTypeNames.isDisjoint(with: Set(typeNames))
    }
}
