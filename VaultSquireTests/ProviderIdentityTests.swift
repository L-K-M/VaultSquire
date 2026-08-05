import XCTest
@testable import VaultSquire

final class ProviderIdentityTests: XCTestCase {
    private let vaultwardenAccount = AccountID(
        provider: .vaultwarden,
        rawValue: "account-1"
    )
    private let protonAccount = AccountID(
        provider: .protonCLI,
        rawValue: "account-1"
    )

    func testSameRawAccountIdentifierIsDistinctAcrossProviders() {
        XCTAssertNotEqual(vaultwardenAccount, protonAccount)
        XCTAssertEqual(Set([vaultwardenAccount, protonAccount]).count, 2)
    }

    func testSameRawItemIdentifierIsDistinctAcrossAccountsAndSpaces() {
        let firstAccountPersonal = VaultSpaceID(
            account: vaultwardenAccount,
            scope: .personal
        )
        let secondAccountPersonal = VaultSpaceID(
            account: AccountID(provider: .vaultwarden, rawValue: "account-2"),
            scope: .personal
        )
        let firstAccountShare = VaultSpaceID(
            account: vaultwardenAccount,
            scope: .providerSpace("share-1")
        )

        let items = [
            VaultItemID(space: firstAccountPersonal, rawValue: "item-1"),
            VaultItemID(space: secondAccountPersonal, rawValue: "item-1"),
            VaultItemID(space: firstAccountShare, rawValue: "item-1")
        ]

        XCTAssertEqual(Set(items).count, items.count)
    }

    func testPersonalScopeIsDistinctFromProviderSpaceNamedPersonal() {
        let personal = VaultSpaceID(
            account: vaultwardenAccount,
            scope: .personal
        )
        let namedPersonal = VaultSpaceID(
            account: vaultwardenAccount,
            scope: .providerSpace("personal")
        )

        XCTAssertNotEqual(personal, namedPersonal)
    }

    func testItemIdentityExposesItsFullNamespace() {
        let space = VaultSpaceID(
            account: protonAccount,
            scope: .providerSpace("share-9")
        )
        let item = VaultItemID(space: space, rawValue: "item-42")

        XCTAssertEqual(item.account, protonAccount)
        XCTAssertEqual(item.provider, .protonCLI)
    }

    func testIdentityCodableRoundTripPreservesEquality() throws {
        let item = VaultItemID(
            space: VaultSpaceID(
                account: vaultwardenAccount,
                scope: .providerSpace("collection-3")
            ),
            rawValue: "item-7"
        )

        let encoded = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(VaultItemID.self, from: encoded)

        XCTAssertEqual(decoded, item)
    }
}
