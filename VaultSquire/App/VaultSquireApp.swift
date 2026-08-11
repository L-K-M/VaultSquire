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
        Window("VaultSquire", id: "main") {
            LockedShellView()
                .environmentObject(appModel)
                .environmentObject(siteIcons)
                .background(WindowRestorationDisabler())
                .onAppear {
                    ApplicationCoordinator.shared.configureVaultLockCleanup {
                        siteIcons.clear()
                    }
                    appDelegate.configureSecurityLock {
                        appModel.lock()
                    }
                    PerformanceTrace.recordLaunchCompleted()
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
