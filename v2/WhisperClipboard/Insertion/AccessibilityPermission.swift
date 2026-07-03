import ApplicationServices
import AppKit

/// Thin wrapper over the Accessibility (AX) trust APIs. Direct text insertion
/// synthesizes a Cmd+V keystroke via `CGEvent`, which macOS only delivers to
/// other apps when this process is trusted for Accessibility.
enum AccessibilityPermission {

    /// Whether this process is currently trusted for Accessibility.
    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system Accessibility prompt (adds us to the list, unchecked,
    /// and shows the standard "wants to control your computer" dialog). Returns
    /// the current trust state (usually `false` on first call — the user must
    /// still flip the switch in System Settings).
    @discardableResult
    static func request() -> Bool {
        // Literal instead of `kAXTrustedCheckOptionPrompt`: that global is a
        // `var` and not concurrency-safe under Swift 6 strict concurrency.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings directly on the Privacy → Accessibility pane.
    static func openSettingsPane() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// AX exposes no change notification, so callers that want to reflect a
    /// freshly-granted permission in the UI poll for a short window. `onChange`
    /// fires on the main actor whenever the granted state flips, and polling
    /// stops once granted or the deadline passes.
    ///
    /// - Parameters:
    ///   - interval: seconds between checks (default 0.5s).
    ///   - timeout: total seconds to keep polling (default 30s).
    @MainActor
    static func pollUntilGranted(
        interval: TimeInterval = 0.5,
        timeout: TimeInterval = 30,
        onChange: @escaping (Bool) -> Void
    ) {
        var last = isGranted
        let deadline = Date().addingTimeInterval(timeout)
        Task { @MainActor in
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(interval))
                let now = isGranted
                if now != last {
                    last = now
                    onChange(now)
                }
                if now { break }
            }
        }
    }
}
