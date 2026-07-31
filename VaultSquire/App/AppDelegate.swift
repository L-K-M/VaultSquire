import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.record(.applicationDidFinishLaunching)
    }

    func applicationWillTerminate(_ notification: Notification) {
        ApplicationCoordinator.shared.dismissQuickSearch()
        AppLog.record(.applicationWillTerminate)
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }
}
