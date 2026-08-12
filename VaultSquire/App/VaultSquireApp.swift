import SwiftUI

@main
struct VaultSquireApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()
    /// Owned at the root so the browser and Settings see one store: the switch
    /// in Settings has to change what the item list draws immediately.
    @StateObject private var siteIcons = SiteIconStore()
    /// The configurable Quick Search chord. Held here so `VaultCommands` can
    /// observe it: the menu bar has to show and honour a new chord without a
    /// relaunch.
    @StateObject private var shortcuts = QuickSearchShortcutStore.shared

    init() {
        PerformanceTrace.record(.applicationLaunchStarted)
    }

    var body: some Scene {
        // A WindowGroup rather than a Window: the app deliberately outlives its
        // last closed window (applicationShouldTerminateAfterLastWindowClosed is
        // false), and a Window scene cannot be recreated once closed — a user
        // who closed the window would be left with a running app with no way
        // back. WindowGroup lets a Dock click reopen the main window.
        WindowGroup("VaultSquire", id: "main") {
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
                    // Claims the stored chord system-wide. Done here rather
                    // than in the store's initialiser so registration happens
                    // once the app is running, and so a failure is visible in
                    // Settings rather than during a property read.
                    shortcuts.activate()
                }
        }
        .defaultSize(width: 820, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            VaultCommands {
                appModel.lock()
                // Icons are drawn from the sites in the vault, so a lock
                // clears them along with everything else it decrypted.
                siteIcons.clear()
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appModel)
                .environmentObject(siteIcons)
        }
        // Stated, because otherwise the window is sized from what its content
        // asks for — and a paragraph that is free to be as wide as it likes
        // asks for its whole sentence on one line. That produced a Settings
        // window wider than the display, with its leading edge, and therefore
        // the labels, off the screen entirely.
        .defaultSize(width: 620, height: 520)
    }
}

/// VaultSquire's menu commands.
///
/// The Quick Search item carries no key equivalent. The chord is registered
/// system-wide, so it already fires while VaultSquire is frontmost; giving the
/// menu item the same chord as well would mean two claims on one keystroke. The
/// item stays so the command is discoverable and clickable, and Settings is
/// where the chord is shown.
struct VaultCommands: Commands {
    let onLock: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(QuickSearchShortcutStore.menuItemTitle) {
                ApplicationCoordinator.shared.showQuickSearch()
            }

            Divider()

            Button("Lock Vault", action: onLock)
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}
