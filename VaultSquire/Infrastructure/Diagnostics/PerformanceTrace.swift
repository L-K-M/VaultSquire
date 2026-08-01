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

    @MainActor private static var launchIntervalClosed = false

    /// Closes the launch interval exactly once. SwiftUI can run `onAppear` again for
    /// the same scene, and a repeated `.end` on an exclusive signpost would emit an
    /// unmatched event.
    @MainActor
    static func recordLaunchCompleted() {
        guard !launchIntervalClosed else {
            return
        }

        launchIntervalClosed = true
        record(.lockedShellVisible)
    }

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
