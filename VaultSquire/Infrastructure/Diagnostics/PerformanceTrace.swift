import OSLog

enum PerformanceEvent: Sendable {
    case applicationLaunchStarted
    case lockedShellVisible
    case processProbeFinished
    case processProbeStarted
    case quickSearchRequested
    case quickSearchVisible
}

enum PerformanceTrace {
    private static let log = OSLog(
        subsystem: "ch.lkmc.VaultSquire",
        category: "performance"
    )

    static func record(_ event: PerformanceEvent) {
        switch event {
        case .applicationLaunchStarted:
            os_signpost(.begin, log: log, name: "Application Launch")
        case .lockedShellVisible:
            os_signpost(.end, log: log, name: "Application Launch")
        case .processProbeFinished:
            os_signpost(.event, log: log, name: "Process Probe Finished")
        case .processProbeStarted:
            os_signpost(.event, log: log, name: "Process Probe Started")
        case .quickSearchRequested:
            os_signpost(.begin, log: log, name: "Quick Search Presentation")
        case .quickSearchVisible:
            os_signpost(.end, log: log, name: "Quick Search Presentation")
        }
    }
}
