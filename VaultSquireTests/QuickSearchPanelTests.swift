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

    /// `clear()` is the lock path: AppModel.lock() → dismissQuickSearch() →
    /// controller.dismiss() → model.clear(). A locked vault's titles, usernames
    /// and addresses must not stay alive behind an invisible panel.
    @MainActor
    func testClearDropsEveryTraceOfThePresentation() {
        let model = QuickSearchPanelModel()
        model.present(
            items: [Self.projection(title: "GitHub", username: "octocat")],
            isUnlocked: true,
            vaultTitles: [AccountID(provider: .vaultwarden, rawValue: "primary"): "vault.example.com"],
            onOpen: { _ in }
        )
        model.query = "git"
        XCTAssertFalse(model.results.isEmpty)

        model.clear()

        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertTrue(model.vaultTitles.isEmpty)
        XCTAssertNil(model.selection)
        XCTAssertFalse(model.isUnlocked)
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.totalMatchCount, 0)
    }

    /// The same, for a panel dismissed without anything being typed. The query
    /// didSet only fires on a real change, so an untouched panel would keep its
    /// results and highlight if `clear()` relied on that alone.
    @MainActor
    func testClearAlsoResetsAPanelThatWasNeverTypedInto() {
        let model = QuickSearchPanelModel()
        model.present(
            items: [Self.projection(title: "GitHub")], isUnlocked: true, onOpen: { _ in }
        )
        XCTAssertFalse(model.results.isEmpty, "an empty query lists everything")
        XCTAssertNotNil(model.selection)

        model.clear()

        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.selection)
        XCTAssertTrue(model.items.isEmpty)
    }

    /// Opening the panel against a large vault must not render the whole
    /// corpus, and the count has to admit that it was truncated.
    @MainActor
    func testResultsAreCappedAndTheTotalIsStillReported() {
        let model = QuickSearchPanelModel()
        let many = (0..<(QuickSearchPanelModel.maximumResults + 50)).map {
            Self.projection(title: "Item \(String(format: "%04d", $0))")
        }
        model.present(items: many, isUnlocked: true, onOpen: { _ in })

        XCTAssertEqual(model.results.count, QuickSearchPanelModel.maximumResults)
        XCTAssertEqual(model.totalMatchCount, many.count)
        XCTAssertNotNil(model.selection, "a capped list still has a live Return target")
    }

    // MARK: - Fixtures

    /// A synthetic projection. Projections never carry secrets, so nothing here
    /// stands in for one.
    private static func projection(
        title: String,
        username: String? = nil,
        websites: [String] = [],
        folders: [String] = [],
        category: VaultItemCategory = .login,
        capabilities: Set<ProviderCapability> = [.viewItems, .searchItems]
    ) -> VaultItemProjection {
        let account = AccountID(provider: .vaultwarden, rawValue: "primary")
        return VaultItemProjection(
            id: VaultItemID(
                space: VaultSpaceID(account: account, scope: .personal),
                rawValue: "item-\(title)"
            ),
            displayTitle: title,
            displaySubtitle: username,
            category: category,
            username: username,
            websites: websites,
            groupingLabels: folders,
            capabilities: capabilities,
            cacheReference: ProviderCacheReference(
                scope: .wholeAccount(account),
                captureGeneration: SnapshotGeneration(rawValue: 1)
            )
        )
    }

    // MARK: - Actions

    /// A card's first `.secret` field is its number, so Copy Password must not
    /// be the primary action for anything but a login. A panel that shows
    /// nothing and then dismisses cannot afford to copy a card number under a
    /// label that says Password.
    @MainActor
    func testOnlyALoginOffersCopyPasswordOnReturn() {
        let copyable: Set<ProviderCapability> = [.viewItems, .searchItems, .copySecret]
        XCTAssertEqual(
            QuickSearchPanelModel.primaryAction(
                for: Self.projection(title: "GitHub", category: .login, capabilities: copyable)
            ), .copyPassword
        )
        for other in [VaultItemCategory.card, .secureNote, .identity, .unsupported] {
            XCTAssertEqual(
                QuickSearchPanelModel.primaryAction(
                    for: Self.projection(title: "x", category: other, capabilities: copyable)
                ), .show, "\(other)"
            )
        }
    }

    /// A provider that cannot produce a secret must not be offered a copy it
    /// cannot perform.
    @MainActor
    func testAProviderWithoutCopySecretFallsBackToShowing() {
        let item = Self.projection(title: "GitHub", category: .login, capabilities: [.viewItems])
        XCTAssertEqual(QuickSearchPanelModel.primaryAction(for: item), .show)
    }

    /// The footer's hints and the ⇧↩/⌥↩ key handlers read these two
    /// predicates, so a row and its hint can never disagree about whether the
    /// key does anything.
    @MainActor
    func testHintEligibilityMatchesWhatTheRowOffers() {
        XCTAssertTrue(QuickSearchPanelModel.offersUsername(
            Self.projection(title: "a", username: "someone")
        ))
        XCTAssertFalse(QuickSearchPanelModel.offersUsername(Self.projection(title: "b")))
        XCTAssertFalse(QuickSearchPanelModel.offersUsername(
            Self.projection(title: "c", username: "")
        ))

        var withCode = Self.projection(title: "d")
        XCTAssertFalse(QuickSearchPanelModel.offersOneTimeCode(withCode))
        withCode.hasOneTimeCode = true
        XCTAssertTrue(QuickSearchPanelModel.offersOneTimeCode(withCode))
    }

    /// The panel must not go away while the value is still being fetched. Both
    /// CLI providers list without secrets, so Return starts a fetch that can
    /// take seconds; dismissing first would hand focus to another application
    /// and then change the clipboard under the user.
    @MainActor
    func testThePanelStaysUpUntilAPendingCopyLands() async throws {
        let gate = CopyGate()
        let model = QuickSearchPanelModel()
        var finished: [Bool] = []
        model.present(
            items: [Self.projection(
                title: "GitHub", category: .login,
                capabilities: [.viewItems, .searchItems, .copySecret]
            )],
            isUnlocked: true,
            onOpen: nil,
            onDeliver: { _, _, _, before in await gate.wait(); before(); return .copied },
            onCancelCopy: { _ in },
            onFinish: { finished.append($0) }
        )

        model.perform(.primary)
        XCTAssertTrue(model.isWorking)
        XCTAssertTrue(finished.isEmpty, "dismissed before the value existed")

        await gate.open()
        for _ in 0..<200 where finished.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(finished, [true], "and then dismisses, handing focus back")
    }

    /// Escaping out of a fetch must withdraw the copy, or the value lands on
    /// the clipboard seconds later over something the user copied themselves.
    @MainActor
    func testEscapingAFetchCancelsThePendingCopy() async {
        let gate = CopyGate()
        let item = Self.projection(
            title: "GitHub", category: .login,
            capabilities: [.viewItems, .searchItems, .copySecret]
        )
        var cancelled: [VaultItemID] = []
        let model = QuickSearchPanelModel()
        model.present(
            items: [item], isUnlocked: true, onOpen: nil,
            onDeliver: { _, _, _, before in await gate.wait(); before(); return .copied },
            onCancelCopy: { cancelled.append($0) },
            onFinish: { _ in }
        )

        model.perform(.primary)
        model.cancelInFlightWork()

        XCTAssertEqual(cancelled, [item.id])
        XCTAssertFalse(model.isWorking)
        await gate.open()
    }

    /// Asking for a username an item does not have says so rather than
    /// dismissing into silence.
    @MainActor
    func testAMissingUsernameIsReportedRatherThanCopied() {
        let model = QuickSearchPanelModel()
        var copies = 0
        model.present(
            items: [Self.projection(title: "GitHub", category: .login)],
            isUnlocked: true, onOpen: nil,
            onDeliver: { _, _, _, before in copies += 1; before(); return .copied },
            onCancelCopy: { _ in }, onFinish: { _ in }
        )

        model.perform(.copyUsername)

        XCTAssertEqual(copies, 0, "nothing may be asked for")
        XCTAssertEqual(model.actionState, .failed(.username, .noSuchValue))
        // And the message belongs to that one keystroke.
        model.moveSelection(by: 1)
        XCTAssertEqual(model.actionState, .idle)
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

/// Holds an injected copy open so a test can observe the panel mid-fetch.
private actor CopyGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
