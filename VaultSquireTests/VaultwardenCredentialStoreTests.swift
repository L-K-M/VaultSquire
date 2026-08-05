import XCTest
@testable import VaultSquire

final class VaultwardenCredentialStoreTests: XCTestCase {
    private let account = VaultwardenAccountKey.primary

    func testInMemorySaveLoadRoundTrip() throws {
        let store = InMemoryCredentialStore()
        let credentials = VaultwardenStoredCredentials(
            refreshToken: "VSQ-Canary-refresh",
            rememberedTwoFactorToken: "VSQ-Canary-2fa"
        )

        try store.save(credentials, for: account)

        XCTAssertEqual(try store.load(for: account), credentials)
    }

    func testReplaceRefreshTokenIsAtomicAndPreservesRememberedToken() throws {
        let store = InMemoryCredentialStore()
        try store.save(
            VaultwardenStoredCredentials(
                refreshToken: "old",
                rememberedTwoFactorToken: "VSQ-Canary-2fa"
            ),
            for: account
        )

        try store.replaceRefreshToken("new", for: account)

        let updated = try store.load(for: account)
        XCTAssertEqual(updated?.refreshToken, "new")
        XCTAssertEqual(updated?.rememberedTwoFactorToken, "VSQ-Canary-2fa")
    }

    func testDeleteRemovesTheRecord() throws {
        let store = InMemoryCredentialStore()
        try store.save(
            VaultwardenStoredCredentials(refreshToken: "r"), for: account
        )

        try store.delete(for: account)

        XCTAssertNil(try store.load(for: account))
    }

    func testLoadMissingReturnsNil() throws {
        let store = InMemoryCredentialStore()
        XCTAssertNil(try store.load(for: account))
    }

    func testStoredCredentialsCarryTheLayoutVersion() {
        let credentials = VaultwardenStoredCredentials(refreshToken: "r")
        XCTAssertEqual(credentials.version, VaultwardenStoredCredentials.currentVersion)
    }

    func testDerivedAccountKeyHidesTheEmail() {
        let key = VaultwardenAccountKey.derived(
            serverHost: "vault.example.com",
            normalizedEmail: "user@example.com"
        )
        XCTAssertFalse(key.rawValue.contains("user@example.com"))
        XCTAssertEqual(key.rawValue.count, 64) // SHA-256 hex
    }

    // Exercises the real Keychain implementation end to end; skips when the
    // ad-hoc-signed host cannot access the Data Protection Keychain.
    func testKeychainRoundTripOrSkipWhenUnavailable() throws {
        let store = KeychainCredentialStore(
            service: "ch.lkmc.VaultSquire.test.\(UUID().uuidString)"
        )
        let account = VaultwardenAccountKey(rawValue: "test-\(UUID().uuidString)")
        let credentials = VaultwardenStoredCredentials(
            refreshToken: "VSQ-Canary-refresh",
            rememberedTwoFactorToken: "VSQ-Canary-2fa"
        )

        do {
            try store.save(credentials, for: account)
        } catch VaultwardenCredentialStoreError.storeUnavailable(let status) {
            throw XCTSkip("Keychain unavailable on this host (OSStatus \(status)).")
        }
        addTeardownBlock { try? store.delete(for: account) }

        XCTAssertEqual(try store.load(for: account), credentials)

        try store.replaceRefreshToken("VSQ-Canary-refresh-2", for: account)
        let updated = try store.load(for: account)
        XCTAssertEqual(updated?.refreshToken, "VSQ-Canary-refresh-2")
        XCTAssertEqual(updated?.rememberedTwoFactorToken, "VSQ-Canary-2fa")

        try store.delete(for: account)
        XCTAssertNil(try store.load(for: account))
    }
}
