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
                }
        }
        .defaultSize(width: 820, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            VaultCommands(shortcuts: shortcuts) {
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
/// A `Commands`-conforming struct rather than an inline `.commands { }` body
/// for one reason: it has to observe `QuickSearchShortcutStore`, and property
/// wrappers cannot be declared inside a `CommandsBuilder` closure.
///
/// Whether SwiftUI re-applies a changed `keyboardShortcut` to an
/// already-installed `NSMenuItem` is not something SwiftUI promises, so
/// `QuickSearchShortcutStore.set` also writes the chord onto the live menu item
/// through `MainMenuShortcuts`. The two cannot diverge — both read this one
/// store — so whichever of them is the one that actually works, the menu shows
/// and honours the same chord.
struct VaultCommands: Commands {
    @ObservedObject var shortcuts: QuickSearchShortcutStore
    let onLock: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(QuickSearchShortcutStore.menuItemTitle) {
                ApplicationCoordinator.shared.showQuickSearch()
            }
            .keyboardShortcut(
                shortcuts.shortcut.keyEquivalent,
                modifiers: shortcuts.shortcut.eventModifiers
            )

            Divider()

            Button("Lock Vault", action: onLock)
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}
