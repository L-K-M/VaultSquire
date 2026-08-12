import AppKit

/// Supplies Quick Search with the current searchable items and receives the
/// user's selection, so the panel can search the unlocked vault without the
/// coordinator holding vault state.
/// A value Quick Search can put on the clipboard. The username sits alongside
/// the two secrets because the panel offers it as a peer action, not because it
/// is one: `AppModel` routes it through `copyPlain`.
enum QuickSearchCopy: Hashable, Sendable {
    case password
    case username
    case oneTimeCode

    /// The only strings the panel may show about a copy. Never interpolated
    /// with a value.
    var name: String {
        switch self {
        case .password: return "Password"
        case .username: return "Username"
        case .oneTimeCode: return "One-time code"
        }
    }
}

@MainActor
protocol QuickSearchDataSource: AnyObject {
    var quickSearchItems: [VaultItemProjection] { get }
    var quickSearchIsUnlocked: Bool { get }
    /// Display names for the configured vaults, so a result found across a
    /// merged search can name the vault it came from.
    var quickSearchVaultTitles: [AccountID: String] { get }
    func openFromQuickSearch(_ id: VaultItemID)
    /// Puts a value on the clipboard and reports what happened, so the panel
    /// can say "this item has no password" instead of dismissing into silence.
    /// Async because a CLI-backed item's secret does not exist yet at the
    /// moment the user presses Return.
    func copyFromQuickSearch(_ value: QuickSearchCopy, of id: VaultItemID) async -> SecretCopyOutcome
    /// Abandons an in-flight copy the user escaped out of.
    func cancelQuickSearchCopy(of id: VaultItemID)
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
            },
            onCopy: { [weak self] value, id in
                guard let source = self?.quickSearchDataSource else { return .notPermitted }
                return await source.copyFromQuickSearch(value, of: id)
            },
            onCancelCopy: { [weak self] id in
                self?.quickSearchDataSource?.cancelQuickSearchCopy(of: id)
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

    /// What the global hotkey runs. Pressing it again takes the panel down,
    /// which is what every launcher does and what makes the chord safe to lean
    /// on: the user never has to find the mouse to get rid of it.
    func toggleQuickSearch() {
        if quickSearchController?.isVisible == true {
            quickSearchController?.dismiss()
        } else {
            showQuickSearch()
        }
    }

    /// A lock or a termination must not shove the user into whatever
    /// application happened to be behind the panel.
    func dismissQuickSearch() {
        quickSearchController?.dismiss(restoringFocus: false)
    }
}
