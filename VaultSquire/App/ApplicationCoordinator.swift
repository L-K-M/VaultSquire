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

    nonisolated static let clipboardExpirationPreference =
        "ch.lkmc.VaultSquire.clipboard-expiration-seconds"
    nonisolated static let securityLockNotification = Notification.Name(
        "ch.lkmc.VaultSquire.security-lock"
    )
    private static let transientPasteboardType =
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedPasteboardType =
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private var quickSearchController: QuickSearchPanelController?
    private var ownedPasteboardChangeCount: Int?
    private var clipboardClearTask: Task<Void, Never>?
    private var vaultLockCleanup: (@MainActor () -> Void)?
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

    /// Writes a vault value only after the user's explicit copy action, marks it
    /// transient (and concealed for passwords), and remembers ownership by
    /// change count rather than by retaining or reading the value back.
    func copyVaultValue(_ value: String, concealed: Bool) {
        guard value.utf8.count <= 4 * 1024 * 1024 else { return }
        clipboardClearTask?.cancel()

        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        item.setData(Data(), forType: Self.transientPasteboardType)
        if concealed {
            item.setData(Data(), forType: Self.concealedPasteboardType)
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            ownedPasteboardChangeCount = nil
            return
        }
        let changeCount = pasteboard.changeCount
        ownedPasteboardChangeCount = changeCount

        let configured = UserDefaults.standard.integer(
            forKey: Self.clipboardExpirationPreference
        )
        let seconds = configured == 0 ? 30 : min(30, max(5, configured))
        clipboardClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.clearOwnedClipboard(expectedChangeCount: changeCount)
        }
    }

    /// Clears only the value this app still owns. If the user copied anything
    /// later, its different change count is left untouched.
    func clearOwnedClipboard() {
        clipboardClearTask?.cancel()
        clipboardClearTask = nil
        guard let changeCount = ownedPasteboardChangeCount else { return }
        clearOwnedClipboard(expectedChangeCount: changeCount)
    }

    func configureVaultLockCleanup(
        _ cleanup: @escaping @MainActor () -> Void
    ) {
        vaultLockCleanup = cleanup
    }

    /// Shared lock cleanup for explicit, provider-forced, and lifecycle locks.
    func vaultDidLock() {
        dismissQuickSearch()
        clearOwnedClipboard()
        vaultLockCleanup?()
        NotificationCenter.default.post(name: Self.securityLockNotification, object: nil)
    }

    private func clearOwnedClipboard(expectedChangeCount: Int) {
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount == expectedChangeCount {
            pasteboard.clearContents()
        }
        if ownedPasteboardChangeCount == expectedChangeCount {
            ownedPasteboardChangeCount = nil
        }
        clipboardClearTask = nil
    }
}
