import XCTest
@testable import VaultSquire

/// The descriptor store is the source of truth for "which accounts exist". Its
/// failure mode matters more than its success one: reading unreadable
/// preferences as an empty list and then writing over them destroys the user's
/// other accounts to add one.
final class AccountDescriptorStoreTests: XCTestCase {
    private func makeStore() -> (AccountDescriptorStore, UserDefaults, String) {
        let suite = "VSQ-descriptors-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        // Only the suite name is captured. `UserDefaults` is not `Sendable`, so
        // sending the instance itself into the teardown block is a data-race
        // error under Swift 6 unless the whole case is actor-isolated, which a
        // test for a plain value type has no reason to be.
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return (AccountDescriptorStore(defaults: defaults), defaults, suite)
    }

    private static let key = "ch.lkmc.VaultSquire.account-descriptors.v1"

    private func descriptor(
        _ raw: String,
        provider: ProviderID = .vaultwarden,
        server: String = "vault.example.com",
        email: String = "user@example.com"
    ) -> AccountDescriptor {
        AccountDescriptor(
            account: AccountID(provider: provider, rawValue: raw),
            serverDisplay: server,
            email: email
        )
    }

    // MARK: - The round trip

    func testAnEmptyStoreReadsAsNoAccountsRatherThanAFailure() {
        let (store, _, _) = makeStore()
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertTrue(store.upsert(descriptor("a")), "an absent key is empty, not corrupt")
        XCTAssertEqual(store.all().count, 1)
    }

    func testUpsertReplacesByAccountRatherThanAppending() {
        let (store, _, _) = makeStore()
        XCTAssertTrue(store.upsert(descriptor("a", server: "first.example.com")))
        XCTAssertTrue(store.upsert(descriptor("a", server: "second.example.com")))
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.all().first?.serverDisplay, "second.example.com")
    }

    func testRemoveDropsOnlyTheNamedAccount() {
        let (store, _, _) = makeStore()
        XCTAssertTrue(store.upsert(descriptor("a")))
        XCTAssertTrue(store.upsert(descriptor("b", provider: .protonCLI)))
        XCTAssertTrue(store.remove(AccountID(provider: .vaultwarden, rawValue: "a")))
        XCTAssertEqual(store.all().map(\.account.rawValue), ["b"])
    }

    // MARK: - Failing closed

    /// The finding this store change exists for. Corrupt preferences used to
    /// decode as `[]`, so adding one account rewrote the key with only that
    /// account in it and silently destroyed the rest.
    func testCorruptDataIsNotTreatedAsEmptyAndOverwritten() {
        let (store, defaults, _) = makeStore()
        let corrupt = Data("this is not the JSON you are looking for".utf8)
        defaults.set(corrupt, forKey: Self.key)

        XCTAssertFalse(store.upsert(descriptor("a")), "an unreadable list must not be replaced")
        XCTAssertEqual(
            defaults.data(forKey: Self.key), corrupt,
            "the bytes on disk are untouched, so a later migration can still recover them"
        )
    }

    func testRemoveAlsoRefusesToActOnCorruptData() {
        let (store, defaults, _) = makeStore()
        let corrupt = Data([0x00, 0x01, 0x02, 0x03])
        defaults.set(corrupt, forKey: Self.key)

        XCTAssertFalse(store.remove(AccountID(provider: .vaultwarden, rawValue: "a")))
        XCTAssertEqual(defaults.data(forKey: Self.key), corrupt)
    }

    /// A decodable list that violates the store's own shape rules is corrupt
    /// too — otherwise the bound is only enforced on the way in.
    func testADecodableButDuplicatedListIsRejected() throws {
        let (store, defaults, _) = makeStore()
        let duplicated = [descriptor("a"), descriptor("a", server: "other.example.com")]
        defaults.set(try JSONEncoder().encode(duplicated), forKey: Self.key)

        XCTAssertTrue(store.all().isEmpty, "a duplicated list reads as no accounts")
        XCTAssertFalse(store.upsert(descriptor("b")), "and is not overwritten")
    }

    // MARK: - Rejecting what must not be stored

    func testADescriptorWithControlCharactersIsRefused() {
        let (store, _, _) = makeStore()
        XCTAssertFalse(store.upsert(descriptor("a", server: "vault\u{0}example.com")))
        XCTAssertFalse(store.upsert(descriptor("a", email: "user\nname@example.com")))
        XCTAssertTrue(store.all().isEmpty)
    }

    func testADescriptorWithAnEmptyIdentityIsRefused() {
        let (store, _, _) = makeStore()
        XCTAssertFalse(store.upsert(descriptor("")))
        XCTAssertFalse(store.upsert(descriptor("a", server: "")))
        XCTAssertTrue(store.all().isEmpty)
    }

    func testAnOversizeDescriptorIsRefused() {
        let (store, _, _) = makeStore()
        XCTAssertFalse(store.upsert(descriptor("a", server: String(repeating: "x", count: 2_049))))
        XCTAssertFalse(store.upsert(descriptor("a", email: String(repeating: "x", count: 321))))
        XCTAssertFalse(store.upsert(descriptor(String(repeating: "x", count: 257))))
        XCTAssertTrue(store.all().isEmpty)
    }

    /// An account may legitimately have no email — both CLI providers describe
    /// themselves rather than a mailbox — so empty must stay allowed.
    func testAnEmptyEmailIsStillAllowed() {
        let (store, _, _) = makeStore()
        XCTAssertTrue(store.upsert(descriptor("p", provider: .protonCLI, server: "Proton Pass", email: "")))
        XCTAssertEqual(store.all().count, 1)
    }
}
