import AppKit

@MainActor
final class ApplicationCoordinator {
    static let shared = ApplicationCoordinator()

    private var quickSearchController: QuickSearchPanelController?

    private init() {}

    func showQuickSearch() {
        PerformanceTrace.record(.quickSearchRequested)

        let controller: QuickSearchPanelController
        if let quickSearchController {
            controller = quickSearchController
        } else {
            controller = QuickSearchPanelController()
            quickSearchController = controller
        }

        controller.show()
    }

    func dismissQuickSearch() {
        quickSearchController?.dismiss()
    }
}
