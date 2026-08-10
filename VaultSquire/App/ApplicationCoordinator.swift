import AppKit

/// Supplies Quick Search with the current searchable items and receives the
/// user's selection, so the panel can search the unlocked vault without the
/// coordinator holding vault state.
@MainActor
protocol QuickSearchDataSource: AnyObject {
    var quickSearchItems: [VaultItemProjection] { get }
    var quickSearchIsUnlocked: Bool { get }
    func openFromQuickSearch(_ id: VaultItemID)
}

@MainActor
final class ApplicationCoordinator {
    static let shared = ApplicationCoordinator()

    private var quickSearchController: QuickSearchPanelController?
    /// The vault data source (AppModel), set when the shell appears. Weak so the
    /// coordinator never keeps the model alive.
    weak var quickSearchDataSource: (any QuickSearchDataSource)?

    private init() {}

    var quickSearchControllerForTesting: QuickSearchPanelController? {
        quickSearchController
    }

    func showQuickSearch() {
        PerformanceTrace.record(.quickSearchRequested)

        let controller: QuickSearchPanelController
        if let quickSearchController {
            controller = quickSearchController
        } else {
            controller = QuickSearchPanelController()
            quickSearchController = controller
        }

        controller.show(
            items: quickSearchDataSource?.quickSearchItems ?? [],
            isUnlocked: quickSearchDataSource?.quickSearchIsUnlocked ?? false,
            onOpen: { [weak self] id in
                self?.quickSearchDataSource?.openFromQuickSearch(id)
            }
        )
    }

    func dismissQuickSearch() {
        quickSearchController?.dismiss()
    }
}
