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

    // MARK: - Ranking

    /// The panel is a launcher, so the best match has to come first. In vault
    /// order these are alphabetical, which would put "Digital Ocean" above
    /// "GitHub" for "git".
    @MainActor
    func testTitleMatchesOutrankAlphabeticalOrder() {
        let items = [
            Self.projection(title: "Digital Ocean", username: "git@example.com"),
            Self.projection(title: "GitHub", username: "octocat"),
            Self.projection(title: "Work GitHub", username: "octocat"),
        ]

        let ranked = QuickSearchPanelModel.ranked(items, query: "git")

        XCTAssertEqual(
            ranked.map(\.displayTitle),
            ["GitHub", "Work GitHub", "Digital Ocean"],
            "a title prefix beats a later word, which beats a match on another field"
        )
    }

    @MainActor
    func testAnExactTitleWinsOverAPrefix() {
        let items = [
            Self.projection(title: "Mail Archive"),
            Self.projection(title: "Mail"),
        ]

        XCTAssertEqual(
            QuickSearchPanelModel.ranked(items, query: "mail").map(\.displayTitle),
            ["Mail", "Mail Archive"]
        )
    }

    @MainActor
    func testNonMatchesAreDroppedAndAnEmptyQueryKeepsEveryItem() {
        let items = [Self.projection(title: "GitHub"), Self.projection(title: "Fastmail")]

        XCTAssertEqual(QuickSearchPanelModel.ranked(items, query: "zzz").count, 0)
        XCTAssertEqual(QuickSearchPanelModel.ranked(items, query: "   ").count, 2)
    }

    @MainActor
    func testWebsitesAndFoldersAreSearchedButRankBelowTitles() {
        let items = [
            Self.projection(title: "Nothing Like It", websites: ["https://example.com"]),
            Self.projection(title: "Example"),
        ]

        XCTAssertEqual(
            QuickSearchPanelModel.ranked(items, query: "example").map(\.displayTitle),
            ["Example", "Nothing Like It"]
        )
    }

    // MARK: - Selection

    /// Return opened the first result whatever the user had arrowed to, and the
    /// arrows did nothing at all. Both are the panel's whole keyboard story.
    @MainActor
    func testArrowKeysMoveTheSelectionAndClampAtBothEnds() {
        let model = QuickSearchPanelModel()
        model.present(
            items: [
                Self.projection(title: "One"),
                Self.projection(title: "Two"),
                Self.projection(title: "Three"),
            ],
            isUnlocked: true,
            onOpen: nil
        )

        XCTAssertEqual(model.selection, model.results.first?.id, "a fresh query preselects the top")

        model.moveSelection(by: 1)
        XCTAssertEqual(model.selection, model.results[1].id)

        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selection, model.results[2].id, "the last row is the floor, not a wrap")

        model.moveSelection(by: -5)
        XCTAssertEqual(model.selection, model.results[0].id)
    }

    @MainActor
    func testReturnOpensTheHighlightedResultRatherThanTheFirst() {
        var opened: [String] = []
        let model = QuickSearchPanelModel()
        let items = [Self.projection(title: "One"), Self.projection(title: "Two")]
        model.present(items: items, isUnlocked: true) { id in
            opened.append(id.rawValue)
        }

        model.moveSelection(by: 1)
        model.openSelection()

        XCTAssertEqual(opened, [model.results[1].id.rawValue])
    }

    /// Typing narrows the list under the highlight, so the highlight has to
    /// follow rather than point at a row that is no longer there.
    @MainActor
    func testTypingKeepsTheSelectionValid() {
        let model = QuickSearchPanelModel()
        model.present(
            items: [Self.projection(title: "GitHub"), Self.projection(title: "Fastmail")],
            isUnlocked: true,
            onOpen: nil
        )

        model.moveSelection(by: 1)
        XCTAssertEqual(model.selection, model.results[1].id)

        model.query = "github"
        XCTAssertEqual(model.results.count, 1)
        XCTAssertEqual(model.selection, model.results[0].id)
    }

    /// The panel takes a snapshot when it opens. A vault locking behind it must
    /// not leave its items offered, and the query must survive the refresh.
    @MainActor
    func testUpdateReplacesTheSearchableItemsWithoutDisturbingTheQuery() {
        let model = QuickSearchPanelModel()
        model.present(
            items: [Self.projection(title: "GitHub"), Self.projection(title: "GitLab")],
            isUnlocked: true,
            onOpen: nil
        )
        model.query = "git"
        XCTAssertEqual(model.results.count, 2)

        model.update(items: [], isUnlocked: false)

        XCTAssertEqual(model.query, "git")
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.selection)
        XCTAssertFalse(model.isUnlocked)
    }

    @MainActor
    func testLockedPanelOpensNothing() {
        var opened = 0
        let model = QuickSearchPanelModel()
        model.present(items: [Self.projection(title: "One")], isUnlocked: false) { _ in
            opened += 1
        }

        model.openSelection()

        XCTAssertEqual(opened, 0)
    }

    // MARK: - Fixtures

    /// A synthetic projection. Projections never carry secrets, so nothing here
    /// stands in for one.
    private static func projection(
        title: String,
        username: String? = nil,
        websites: [String] = [],
        folders: [String] = []
    ) -> VaultItemProjection {
        let account = AccountID(provider: .vaultwarden, rawValue: "primary")
        return VaultItemProjection(
            id: VaultItemID(
                space: VaultSpaceID(account: account, scope: .personal),
                rawValue: "item-\(title)"
            ),
            displayTitle: title,
            displaySubtitle: username,
            category: .login,
            username: username,
            websites: websites,
            groupingLabels: folders,
            capabilities: [.viewItems, .searchItems],
            cacheReference: ProviderCacheReference(
                scope: .wholeAccount(account),
                captureGeneration: SnapshotGeneration(rawValue: 1)
            )
        )
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
}
