import AppKit
import XCTest
@testable import VaultSquire

final class QuickSearchPanelTests: XCTestCase {
    @MainActor
    func testModelClearsQuery() {
        let model = QuickSearchPanelModel()
        model.query = "synthetic query"

        model.clear()

        XCTAssertEqual(model.query, "")
    }

    @MainActor
    func testPanelSupportsSpacesAndSecureRestorationPolicy() {
        let controller = QuickSearchPanelController()
        let panel = controller.windowForTesting

        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.transient))
        XCTAssertFalse(panel.isRestorable)
        XCTAssertFalse(panel.isReleasedWhenClosed)
    }

    @MainActor
    func testDismissClearsQueryAndOrdersPanelOut() {
        let controller = QuickSearchPanelController()

        controller.show()
        XCTAssertTrue(controller.windowForTesting.isVisible)

        controller.modelForTesting.query = "synthetic query"
        controller.dismiss()

        XCTAssertFalse(controller.windowForTesting.isVisible)
        XCTAssertEqual(controller.modelForTesting.query, "")
    }

    /// The warm Quick Search signpost interval is opened by the coordinator and
    /// closed by the controller, so the coordinator hop is the measured path. This
    /// keeps the two halves from drifting apart again.
    @MainActor
    func testCoordinatorPresentsAndDismissesTheSamePanel() {
        ApplicationCoordinator.shared.showQuickSearch()

        let panel = ApplicationCoordinator.shared
            .quickSearchControllerForTesting?
            .windowForTesting
        XCTAssertNotNil(panel)
        XCTAssertEqual(panel?.isVisible, true)

        ApplicationCoordinator.shared.dismissQuickSearch()
        XCTAssertEqual(panel?.isVisible, false)
    }

    /// The Quick Search panel is a floating window: it can stay open across
    /// syncs and vault changes, and the merged search must still name where an
    /// item came from.
    @MainActor
    func testEmptyQueryResultsAreCapped() {
        let model = QuickSearchPanelModel()
        model.present(items: Self.makeItems(250), isUnlocked: true, vaultTitles: [:], onOpen: nil)

        XCTAssertEqual(model.results.count, QuickSearchPanelModel.maximumResults)
    }

    @MainActor
    func testFilteredResultsAreCappedToo() {
        let model = QuickSearchPanelModel()
        model.present(items: Self.makeItems(250), isUnlocked: true, vaultTitles: [:], onOpen: nil)
        model.query = "item 1"

        XCTAssertLessThanOrEqual(model.results.count, QuickSearchPanelModel.maximumResults)
    }

    @MainActor
    func testSourceVaultBadgeComesFromPresentedTitles() {
        let account = AccountID(provider: .vaultwarden, rawValue: "primary")
        let item = Self.makeItem(account: account, index: 0)
        let model = QuickSearchPanelModel()
        model.present(
            items: [item],
            isUnlocked: true,
            vaultTitles: [account: "Home Vault"],
            onOpen: nil
        )

        XCTAssertEqual(model.vaultTitle(for: item), "Home Vault")
        XCTAssertNil(model.vaultTitle(for: Self.makeItem(
            account: AccountID(provider: .protonCLI, rawValue: "other"), index: 0
        )))
    }

    private static func makeItem(account: AccountID, index: Int) -> VaultItemProjection {
        VaultItemProjection(
            id: VaultItemID(
                space: VaultSpaceID(account: account, scope: .personal),
                rawValue: "\(index)"
            ),
            displayTitle: "Item \(index)",
            displaySubtitle: nil,
            category: .login,
            username: nil,
            websites: [],
            groupingLabels: [],
            capabilities: [.viewItems, .searchItems],
            cacheReference: ProviderCacheReference(
                scope: .wholeAccount(account),
                captureGeneration: SnapshotGeneration(rawValue: 1)
            )
        )
    }

    private static func makeItems(_ count: Int) -> [VaultItemProjection] {
        let account = AccountID(provider: .vaultwarden, rawValue: "primary")
        return (0..<count).map { makeItem(account: account, index: $0) }
    }
}
