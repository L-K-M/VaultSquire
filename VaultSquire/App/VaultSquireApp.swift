import SwiftUI

@main
struct VaultSquireApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()
    /// Owned at the root so the browser and Settings see one store: the switch
    /// in Settings has to change what the item list draws immediately.
    @StateObject private var siteIcons = SiteIconStore()

    init() {
        PerformanceTrace.record(.applicationLaunchStarted)
    }

    var body: some Scene {
        // A WindowGroup rather than a Window: the app deliberately outlives its
        // last closed window (applicationShouldTerminateAfterLastWindowClosed is
        // false), and a Window scene cannot be recreated once closed — a user
        // who closed the window would be left with a running app with no way
        // back. WindowGroup lets a Dock click reopen the main window.
        WindowGroup("VaultSquire") {
            LockedShellView()
                .environmentObject(appModel)
                .environmentObject(siteIcons)
                .background(WindowRestorationDisabler())
                .onAppear {
                    PerformanceTrace.recordLaunchCompleted()
                    // The lock triggers the explicit menu command cannot cover:
                    // screen lock, screensaver, sleep, session resignation, and
                    // inactivity all run the same lock-everything action.
                    AutoLockController.shared.start(onLock: {
                        appModel.lock()
                        siteIcons.clear()
                    })
                }
        }
        .defaultSize(width: 820, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Quick Search") {
                    ApplicationCoordinator.shared.showQuickSearch()
                }
                .keyboardShortcut(" ", modifiers: [.command, .shift])

                Divider()

                Button("Lock Vault") {
                    appModel.lock()
                    // Icons are drawn from the sites in the vault, so a lock
                    // clears them along with everything else it decrypted.
                    siteIcons.clear()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appModel)
                .environmentObject(siteIcons)
        }
    }
}
