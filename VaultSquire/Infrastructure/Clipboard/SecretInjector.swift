import AppKit
import ApplicationServices
import CoreGraphics

/// Types a value into whatever application had focus before Quick Search
/// appeared, instead of leaving it on the clipboard.
///
/// **Why this is worth a permission.** The keystrokes carry the value directly
/// — `keyboardSetUnicodeString` puts the text on the event, so the pasteboard is
/// never touched. For a password manager that is a better path than the
/// clipboard, not merely a faster one: nothing is left for a clipboard-history
/// manager to capture, nothing syncs to another device over Universal
/// Clipboard, and there is no window during which any process that asks the
/// pasteboard can read the secret. The clipboard route has all three, which is
/// why it needs an expiry and a concealed-type hint; this route needs neither.
///
/// **What the permission costs.** Posting events to another application
/// requires Accessibility (TCC), and that is a real grant with a real blast
/// radius — it is the same permission that would let a process observe the
/// user's input. VaultSquire only ever posts, never observes: there is no event
/// tap here and no monitor. The grant cannot be narrowed to "posting only",
/// though, so the honest statement is that the user is trusting this app with
/// more than it uses, and `SECURITY_AND_TESTING.md` says so.
///
/// **Without the grant nothing breaks.** Delivery falls back to the clipboard,
/// which is what the app did before, and the user is told which of the two
/// happened rather than left guessing.
@MainActor
enum SecretInjector {
    /// How long to wait after the target application is asked to come forward
    /// before posting keystrokes at it.
    ///
    /// Events go to whatever is frontmost when they are posted, so posting too
    /// early types a password into the panel that is on its way out, or into
    /// the wrong window. This is the one number in the feature that is a guess
    /// rather than a rule, and it is why the delivery is confirmed afterwards.
    static let activationSettlingDelay: Duration = .milliseconds(150)

    /// Whether this app may post synthetic events to another application.
    ///
    /// `prompt: false` everywhere except the explicit Settings button: a
    /// password manager asking for Accessibility unbidden, at the moment the
    /// user pressed Return expecting a credential, is how a permission dialog
    /// gets clicked through rather than read.
    static func hasPermission(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Shows the system prompt and opens the pane, for the Settings button that
    /// says what it is about to ask for.
    static func requestPermission() {
        _ = hasPermission(prompt: true)
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Brings `process` forward and types `value` into it.
    ///
    /// Returns false when the permission is absent, so the caller can fall back
    /// to the clipboard. The value is not retained: it is turned into one event
    /// pair and posted.
    static func type(_ value: String, into process: pid_t?) async -> Bool {
        guard hasPermission() else { return false }
        guard !value.isEmpty else { return true }

        if let process,
           let target = NSRunningApplication(processIdentifier: process),
           !target.isTerminated {
            target.activate()
        }
        // The panel is already ordering out and the target is coming forward;
        // keystrokes posted before that settles land in the wrong window.
        try? await Task.sleep(for: activationSettlingDelay)

        post(value)
        return true
    }

    /// One key-down/key-up pair carrying the whole string as its Unicode
    /// payload. Layout-independent — the receiving app is handed characters, not
    /// key codes it would have to interpret through the current layout — and it
    /// leaves no trace on the pasteboard.
    private static func post(_ value: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return
        }
        var utf16 = Array(value.utf16)
        // Zeroed after posting: this array is the only copy of the secret this
        // file makes, and it outlives the post by the length of this function.
        defer { utf16.resetToZero() }
        utf16.withUnsafeBufferPointer { buffer in
            keyDown.keyboardSetUnicodeString(
                stringLength: buffer.count, unicodeString: buffer.baseAddress
            )
            keyUp.keyboardSetUnicodeString(
                stringLength: buffer.count, unicodeString: buffer.baseAddress
            )
        }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

private extension Array where Element == UInt16 {
    /// Best-effort erasure, matching `VaultwardenCryptoZeroize`'s contract: Swift
    /// and the runtime may have made copies this cannot reach.
    mutating func resetToZero() {
        withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            base.update(repeating: 0, count: buffer.count)
        }
    }
}
