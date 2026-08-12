import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.record(.applicationDidFinishLaunching)
    }

    func applicationWillTerminate(_ notification: Notification) {
        ApplicationCoordinator.shared.dismissQuickSearch()
        // The same conditional clear as lock: only a pasteboard write this
        // process still owns is erased, a later user copy never is.
        ClipboardService.shared.clearIfOwned()
        AppLog.record(.applicationWillTerminate)
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    /// A Dock click on a running, windowless app reopens the main scene.
    /// With the main scene a `WindowGroup`, AppKit/SwiftUI recreate the window
    /// themselves; returning true keeps that default behavior. Returning false
    /// here would leave a user who closed the window with no way back except
    /// relaunching.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        true
    }

    /// Restoration is disabled per window (`WindowRestorationDisabler`) and by
    /// `NSQuitAlwaysKeepsWindows`. Returning `true` here does not re-enable it; it
    /// selects the secure archiver for any state AppKit still encodes, which is the
    /// safer of the two answers for a secret-bearing application.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
