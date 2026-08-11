import Foundation
import XCTest
@testable import VaultSquire

final class ProviderCapabilityTests: XCTestCase {
    private let account = AccountID(
        provider: FakeVaultProvider.providerID,
        rawValue: "account-1"
    )

    private var space: VaultSpaceID {
        VaultSpaceID(account: account, scope: .personal)
    }

    private var item: VaultItemID {
        VaultItemID(space: space, rawValue: "item-1")
    }

    private var allMutations: [VaultItemMutation] {
        [
            .createItem(space),
            .updateItem(item),
            .archiveItem(item),
            .trashItem(item),
            .restoreItem(item),
            .deleteItemPermanently(item),
            .favoriteItem(item)
        ]
    }

    func testEveryMutationRequiresItsExactCapability() {
        XCTAssertEqual(
            allMutations.map(\.requiredCapability),
            [
                .createItem,
                .updateItem,
                .archiveItem,
                .trashItem,
                .restoreItem,
                .deleteItemPermanently,
                .favoriteItem
            ]
        )
    }

    func testUnsupportedMutationIsRejectedFromEveryEntryPoint() {
        let gate = CapabilityGate(capabilities: [.viewItems, .searchItems])

        for mutation in allMutations {
            for entryPoint in ActionEntryPoint.allCases {
                XCTAssertThrowsError(
                    try gate.authorize(mutation, from: entryPoint)
                ) { error in
                    XCTAssertEqual(
                        error as? CapabilityGateError,
                        .unsupportedCapability(mutation.requiredCapability)
                    )
                }
            }
        }

        // Reaching VaultProvider.perform without a gate-issued authorization
        // is a compile error: CapabilityAuthorization's initializer is
        // private to the gate's file, so the rejections above are the only
        // outcome any entry point can produce.
    }

    func testSupportedMutationPassesTheGateAndReachesTheProvider() async throws {
        let provider = FakeVaultProvider()
        let gate = CapabilityGate(
            capabilities: Set(allMutations.map(\.requiredCapability))
        )

        for (index, mutation) in allMutations.enumerated() {
            let entryPoint = ActionEntryPoint.allCases[
                index % ActionEntryPoint.allCases.count
            ]
            let authorization = try gate.authorize(mutation, from: entryPoint)
            try await provider.perform(authorization)
        }

        let performed = await provider.performedMutations
        XCTAssertEqual(performed.map(\.mutation), allMutations)
    }

    func testAuthorizationCarriesTheExactMutationItWasIssuedFor() throws {
        let gate = CapabilityGate(capabilities: [.trashItem])
        let mutation = VaultItemMutation.trashItem(item)

        let authorization = try gate.authorize(mutation, from: .contextMenu)

        XCTAssertEqual(authorization.mutation, mutation)
        XCTAssertEqual(authorization.entryPoint, .contextMenu)
    }

    func testVaultwardenMutationsRemainDisabledUntilTheirContractGatesPass() {
        let mutations: Set<ProviderCapability> = [
            .createItem, .updateItem, .archiveItem, .trashItem, .restoreItem,
            .deleteItemPermanently, .favoriteItem,
        ]

        XCTAssertTrue(VaultwardenAccountService.capabilities.isDisjoint(with: mutations))
        XCTAssertTrue(VaultwardenAccountService.capabilities.contains(.viewItems))
        XCTAssertTrue(VaultwardenAccountService.capabilities.contains(.searchItems))
    }

    func testVaultwardenMutationEntryPointRejectsEvenIfCalledDirectly() async throws {
        let service = VaultwardenAccountService()
        let keyring = VaultwardenKeyring(
            userKey: try VaultwardenSymmetricKey(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let draft = VaultItemDraft(
            title: "VSQ-title",
            username: "VSQ-user",
            password: "VSQ-password"
        )

        let result = await service.create(draft: draft, keyring: keyring)

        guard case .failure(let error) = result else {
            return XCTFail("production mutation entry point must reject")
        }
        XCTAssertEqual(error, .rejected)
    }

    func testGateSupportsReportsExactCapabilities() {
        let gate = CapabilityGate(capabilities: [.viewItems])

        XCTAssertTrue(gate.supports(.viewItems))
        XCTAssertFalse(gate.supports(.copySecret))
    }
}
