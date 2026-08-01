import SwiftUI

@main
struct VaultSquireApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()

    init() {
        PerformanceTrace.record(.applicationLaunchStarted)
    }

    var body: some Scene {
        Window("VaultSquire", id: "main") {
            LockedShellView()
                .environmentObject(appModel)
                .background(WindowRestorationDisabler())
                .onAppear {
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
        }
    }
}
