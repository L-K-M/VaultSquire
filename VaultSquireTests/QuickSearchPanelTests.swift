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
        XCTAssertTrue(controller.modelForTesting.results.isEmpty)
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

    @MainActor
    func testSearchRanksExactTitleThenTitlePrefixThenUsernameOrHostPrefixThenContains() async throws {
        let model = VaultItemSearchModel(resultLimit: 10, emptyQueryLimit: 10)
        model.updateItems([
            projection(id: "contains", title: "Archive", subtitle: nil, username: nil, websites: [], groups: ["Cafe Team"]),
            projection(id: "exact", title: "Cafe", subtitle: nil, username: nil, websites: [], groups: []),
            projection(id: "title-prefix", title: "Cafe Portal", subtitle: nil, username: nil, websites: [], groups: []),
            projection(id: "username-prefix", title: "Profile", subtitle: nil, username: "cafe-user", websites: [], groups: []),
            projection(id: "host-prefix", title: "Website", subtitle: nil, username: nil, websites: ["cafe.example.test"], groups: []),
        ])

        model.query = "cafe"
        try await waitUntil { model.totalMatchCount == 5 }

        XCTAssertEqual(
            model.results.map(\.id.rawValue),
            ["exact", "title-prefix", "username-prefix", "host-prefix", "contains"]
        )
    }

    @MainActor
    func testSearchNormalizesCaseAndDiacritics() async throws {
        let model = VaultItemSearchModel(resultLimit: 10, emptyQueryLimit: 10)
        model.updateItems([
            projection(id: "normalized", title: "Cafe Resume", subtitle: nil, username: nil, websites: [], groups: []),
            projection(id: "accented", title: "Café Résumé", subtitle: nil, username: nil, websites: [], groups: [])
        ])

        model.query = "cafe resume"
        try await waitUntil { model.totalMatchCount == 2 }

        XCTAssertEqual(model.results.map(\.id.rawValue), ["accented", "normalized"])
    }

    @MainActor
    func testSearchUsesInvariantNormalizationInsteadOfTheCurrentLocale() async throws {
        let model = VaultItemSearchModel(resultLimit: 10, emptyQueryLimit: 10)
        model.updateItems([
            projection(id: "istanbul", title: "Istanbul", subtitle: nil, username: nil, websites: [], groups: [])
        ])

        model.query = "istanbul"
        try await waitUntil { model.totalMatchCount == 1 }

        XCTAssertEqual(model.results.map(\.id.rawValue), ["istanbul"])
    }

    @MainActor
    func testQuotedTermsRequireTheQuotedPhrase() async throws {
        let model = VaultItemSearchModel(resultLimit: 10, emptyQueryLimit: 10)
        model.updateItems([
            projection(id: "phrase", title: "Alpha Beta Control", subtitle: nil, username: nil, websites: [], groups: ["prod"]),
            projection(id: "split", title: "Alpha Control", subtitle: nil, username: nil, websites: [], groups: ["beta prod"])
        ])

        model.query = "\"alpha beta\" prod"
        try await waitUntil { model.totalMatchCount == 1 }

        XCTAssertEqual(model.results.map(\.id.rawValue), ["phrase"])
    }

    @MainActor
    func testStaleQueryCancellationPublishesOnlyTheLatestResult() async throws {
        let model = VaultItemSearchModel(
            resultLimit: 10,
            emptyQueryLimit: 10,
            searchDelay: .milliseconds(50)
        )
        model.updateItems([
            projection(id: "alpha", title: "Alpha Service", subtitle: nil, username: nil, websites: [], groups: []),
            projection(id: "beta", title: "Beta Service", subtitle: nil, username: nil, websites: [], groups: [])
        ])
        try await waitUntil { model.totalMatchCount == 2 }

        model.query = "alpha"
        model.query = "beta"
        try await waitUntil { model.totalMatchCount == 1 && model.results.first?.id.rawValue == "beta" }

        XCTAssertEqual(model.results.map(\.id.rawValue), ["beta"])
    }

    @MainActor
    func testSearchCapsInitialAndQueryResultsWhileReportingTotalCount() async throws {
        let model = VaultItemSearchModel(resultLimit: 2, emptyQueryLimit: 3)
        model.updateItems([
            projection(id: "1", title: "Entry 1", subtitle: nil, username: nil, websites: [], groups: []),
            projection(id: "2", title: "Entry 2", subtitle: nil, username: nil, websites: [], groups: []),
            projection(id: "3", title: "Entry 3", subtitle: nil, username: nil, websites: [], groups: []),
            projection(id: "4", title: "Entry 4", subtitle: nil, username: nil, websites: [], groups: []),
            projection(id: "5", title: "Entry 5", subtitle: nil, username: nil, websites: [], groups: [])
        ])

        try await waitUntil { model.totalMatchCount == 5 && model.results.count == 3 }
        XCTAssertEqual(model.results.map(\.id.rawValue), ["1", "2", "3"])

        model.query = "entry"
        try await waitUntil { model.totalMatchCount == 5 && model.results.count == 2 }
        XCTAssertEqual(model.results.map(\.id.rawValue), ["1", "2"])
    }

    @MainActor
    func testUpdatingItemsClearsVisibleResultsBeforeADelayedReplacementIndexFinishes() async throws {
        let model = VaultItemSearchModel(
            resultLimit: 10,
            emptyQueryLimit: 10,
            buildDelay: .milliseconds(75)
        )
        model.updateItems([
            projection(id: "old", title: "Alpha", subtitle: nil, username: nil, websites: [], groups: [])
        ], isUnlocked: true)
        try await waitUntil { model.totalMatchCount == 1 }

        model.query = "alpha"
        try await waitUntil { model.totalMatchCount == 1 && model.results.map(\.id.rawValue) == ["old"] }

        model.updateItems([
            projection(id: "new", title: "Beta", subtitle: nil, username: nil, websites: [], groups: [])
        ], isUnlocked: true)

        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.totalMatchCount, 0)

        try await waitUntil { model.totalMatchCount == 0 && model.results.isEmpty }
        model.query = "beta"
        try await waitUntil { model.totalMatchCount == 1 && model.results.map(\.id.rawValue) == ["new"] }
    }

    @MainActor
    func testGeneratedHundredThousandCorpusReportsBoundedResults() async throws {
        let model = VaultItemSearchModel(resultLimit: 40, emptyQueryLimit: 25)
        let items = (0..<100_000).map { index in
            projection(
                id: "item-\(index)",
                title: index.isMultiple(of: 1_000) ? "Needle Entry \(index)" : "Entry \(index)",
                subtitle: nil,
                username: nil,
                websites: [],
                groups: [index.isMultiple(of: 1_000) ? "needle" : "group"]
            )
        }

        model.updateItems(items)
        try await waitUntil { model.totalMatchCount == 100_000 && model.results.count == 25 }

        model.query = "needle"
        try await waitUntil { model.totalMatchCount == 100 && model.results.count == 40 }

        XCTAssertEqual(model.results.first?.displayTitle, "Needle Entry 0")
        XCTAssertEqual(model.results.count, 40)
    }

    private func projection(
        id: String,
        title: String,
        subtitle: String?,
        username: String?,
        websites: [String],
        groups: [String]
    ) -> VaultItemProjection {
        VaultItemProjection(
            id: VaultItemID(
                space: VaultSpaceID(
                    account: AccountID(provider: .vaultwarden, rawValue: "synthetic-account"),
                    scope: .personal
                ),
                rawValue: id
            ),
            displayTitle: title,
            displaySubtitle: subtitle,
            category: .login,
            username: username,
            websites: websites,
            groupingLabels: groups,
            capabilities: [.viewItems, .searchItems],
            cacheReference: ProviderCacheReference(
                scope: .wholeAccount(AccountID(provider: .vaultwarden, rawValue: "synthetic-account")),
                captureGeneration: SnapshotGeneration(rawValue: 1)
            )
        )
    }

    @MainActor
    private func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition did not hold within the timeout", file: file, line: line)
    }
}
