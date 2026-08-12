import OSLog

enum AppLogEvent: String, CaseIterable, Sendable {
    case applicationDidFinishLaunching = "application.did-finish-launching"
    case applicationWillTerminate = "application.will-terminate"
    case quickSearchDismissed = "quick-search.dismissed"
    case quickSearchPresented = "quick-search.presented"
    /// The system or another application already holds the chord. A fixed
    /// event name; the chord itself is never logged.
    case quickSearchHotkeyUnavailable = "quick-search.hotkey-unavailable"
    case vaultLocked = "vault.locked"
}

enum AppLog {
    private static let logger = Logger(
        subsystem: "ch.lkmc.VaultSquire",
        category: "application"
    )

    static func record(_ event: AppLogEvent) {
        switch event {
        case .applicationDidFinishLaunching:
            logger.notice("application.did-finish-launching")
        case .applicationWillTerminate:
            logger.notice("application.will-terminate")
        case .quickSearchDismissed:
            logger.notice("quick-search.dismissed")
        case .quickSearchPresented:
            logger.notice("quick-search.presented")
        case .quickSearchHotkeyUnavailable:
            logger.notice("quick-search.hotkey-unavailable")
        case .vaultLocked:
            logger.notice("vault.locked")
        }
    }
}
