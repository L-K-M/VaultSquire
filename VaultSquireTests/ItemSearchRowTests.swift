import XCTest
@testable import VaultSquire

/// The haystacks both searches read. The browser's list filter used to have a
/// matcher of its own — `localizedCaseInsensitiveContains` over a freshly
/// allocated array per item per keystroke — so these cover the fields it has to
/// keep searching and the query normalization that decides when there is no
/// filter at all.
final class ItemSearchRowTests: XCTestCase {
    func testEveryDisplayedFieldIsSearchable() throws {
        let row = ItemSearchRow(Self.projection(
            title: "GitHub",
            username: "octocat",
            websites: ["https://github.com"],
            folders: ["Work"]
        ))

        for needle in ["github", "octocat", "github.com", "work"] {
            XCTAssertTrue(row.matches(needle), "\(needle) should match")
        }
        XCTAssertFalse(row.matches("gitlab"))
    }

    /// The list is filtered by what the user typed, in whatever case they typed
    /// it, against titles that are capitalized however the vault stored them.
    func testMatchingIgnoresCaseOnBothSides() throws {
        let row = ItemSearchRow(Self.projection(title: "GitHub", username: "OctoCat"))

        XCTAssertTrue(row.matches(try XCTUnwrap(ItemSearchRow.normalize("GITHUB"))))
        XCTAssertTrue(row.matches(try XCTUnwrap(ItemSearchRow.normalize("  OctoCat "))))
    }

    /// Matching is a substring test, so a needle found mid-word still matches —
    /// the browser's list ranks nothing and shows every match.
    func testAMatchInsideAWordCounts() {
        let row = ItemSearchRow(Self.projection(title: "Digital Ocean"))

        XCTAssertTrue(row.matches("ocean"))
        XCTAssertTrue(row.matches("gital"))
    }

    /// The one case a `contains` matcher gets wrong on its own: an empty needle
    /// is inside every string, so a query of nothing but spaces would match the
    /// whole vault and read as a filter that silently did not apply.
    func testAnEmptyOrBlankQueryIsNotAFilter() {
        XCTAssertNil(ItemSearchRow.normalize(""))
        XCTAssertNil(ItemSearchRow.normalize("   "))
        XCTAssertNil(ItemSearchRow.normalize("\t \n"))
    }

    func testNormalizationTrimsAndLowercases() {
        XCTAssertEqual(ItemSearchRow.normalize("  GitHub  "), "github")
    }

    /// Empty fields are dropped when the row is built, so an item with no
    /// username or folders carries no empty haystack for a needle to hit.
    func testEmptyFieldsAreNotSearchable() {
        let row = ItemSearchRow(Self.projection(title: "Note", username: "", websites: [""]))

        XCTAssertEqual(row.others, [], "empty fields are dropped, not lowercased and kept")
        XCTAssertTrue(row.matches("note"))
    }

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
}
