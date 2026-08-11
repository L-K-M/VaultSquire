import AppKit

/// Supplies Quick Search with the current searchable items and receives the
/// user's selection, so the panel can search the unlocked vault without the
/// coordinator holding vault state.
@MainActor
protocol QuickSearchDataSource: AnyObject {
    var quickSearchItems: [VaultItemProjection] { get }
    var quickSearchIsUnlocked: Bool { get }
    /// The non-secret display title of the vault an item came from, for the
    /// merged search's source badge. Nil when the vault is no longer known.
    func vaultTitle(for account: AccountID) -> String?
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

        let items = quickSearchDataSource?.quickSearchItems ?? []
        // One title per account, for the merged search's source badge.
        var vaultTitles: [AccountID: String] = [:]
        for item in items where vaultTitles[item.id.account] == nil {
            if let title = quickSearchDataSource?.vaultTitle(for: item.id.account) {
                vaultTitles[item.id.account] = title
            }
        }

        controller.show(
            items: items,
            isUnlocked: quickSearchDataSource?.quickSearchIsUnlocked ?? false,
            vaultTitles: vaultTitles,
            onOpen: { [weak self] id in
                self?.quickSearchDataSource?.openFromQuickSearch(id)
            }
        )
    }

    func dismissQuickSearch() {
        quickSearchController?.dismiss()
    }
}
