import AppKit
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var securityLockHandler: (@MainActor () -> Void)?

    func configureSecurityLock(
        _ handler: @escaping @MainActor () -> Void
    ) {
        securityLockHandler = handler
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A password manager must not intentionally leave process memory in a
        // core file. This is process-wide and is established before any vault
        // can be opened.
        var coreLimit = rlimit(rlim_cur: 0, rlim_max: 0)
        guard setrlimit(RLIMIT_CORE, &coreLimit) == 0 else {
            // Continuing would knowingly permit a plaintext memory image to be
            // written later. Exit without generating a Swift crash report.
            _exit(EXIT_FAILURE)
        }
        ProcessInfo.processInfo.disableSuddenTermination()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            workspaceCenter.addObserver(
                self,
                selector: #selector(handleSecurityLifecycleEvent(_:)),
                name: name,
                object: nil
            )
        }
        let distributedCenter = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            distributedCenter.addObserver(
                self,
                selector: #selector(handleSecurityLifecycleEvent(_:)),
                name: Notification.Name(name),
                object: nil
            )
        }
        AppLog.record(.applicationDidFinishLaunching)
    }

    func applicationWillTerminate(_ notification: Notification) {
        performSecurityLock()
        AppLog.record(.applicationWillTerminate)
    }

    @objc private func handleSecurityLifecycleEvent(_ notification: Notification) {
        performSecurityLock()
    }

    private func performSecurityLock() {
        // The model advances every session generation before cancelling work
        // and performs shared presentation cleanup. Before it is configured,
        // the coordinator still clears any presentation-only state directly.
        if let securityLockHandler {
            securityLockHandler()
        } else {
            ApplicationCoordinator.shared.vaultDidLock()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    /// Restoration is disabled per window (`WindowRestorationDisabler`) and by
    /// `NSQuitAlwaysKeepsWindows`. Returning `true` here does not re-enable it; it
    /// selects the secure archiver for any state AppKit still encodes, which is the
    /// safer of the two answers for a secret-bearing application.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
