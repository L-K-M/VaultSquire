import AppKit

/// Supplies Quick Search with the current searchable items and receives the
/// user's selection, so the panel can search the unlocked vault without the
/// coordinator holding vault state.
@MainActor
protocol QuickSearchDataSource: AnyObject {
    var quickSearchItems: [VaultItemProjection] { get }
    var quickSearchIsUnlocked: Bool { get }
    /// Display names for the configured vaults, so a result found across a
    /// merged search can name the vault it came from.
    var quickSearchVaultTitles: [AccountID: String] { get }
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
            vaultTitles: quickSearchDataSource?.quickSearchVaultTitles ?? [:],
            onOpen: { [weak self] id in
                self?.quickSearchDataSource?.openFromQuickSearch(id)
            }
        )
    }

    /// Re-reads the data source into a panel that is already on screen. The
    /// panel takes a snapshot when it opens, so without this a vault locked
    /// behind it would keep offering its items — and a sync that landed would
    /// be invisible until the panel was closed and reopened.
    func refreshQuickSearch() {
        guard let controller = quickSearchController, controller.isVisible else { return }
        controller.update(
            items: quickSearchDataSource?.quickSearchItems ?? [],
            isUnlocked: quickSearchDataSource?.quickSearchIsUnlocked ?? false,
            vaultTitles: quickSearchDataSource?.quickSearchVaultTitles ?? [:]
        )
    }

    func dismissQuickSearch() {
        quickSearchController?.dismiss()
    }
}
