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
        XCTAssertTrue(
            key.rawValue.allSatisfy { $0.isHexDigit },
            "expected a hex-encoded SHA-256 digest"
        )
        XCTAssertEqual(key.rawValue.count, 64)
    }

    // Exercises the real Keychain implementation end to end; skips when the
    // ad-hoc-signed host cannot access the Data Protection Keychain.
    func testKeychainRoundTripOrSkipWhenUnavailable() throws {
        let store = KeychainCredentialStore(
            service: "ch.lkmc.VaultSquire.test.\(UUID().uuidString)"
        )
        let keychainAccount = VaultwardenAccountKey(rawValue: "test-\(UUID().uuidString)")
        let credentials = VaultwardenStoredCredentials(
            refreshToken: "VSQ-Canary-refresh",
            rememberedTwoFactorToken: "VSQ-Canary-2fa"
        )

        // Every Keychain operation converts a store-unavailable status into a
        // skip, so a host that loses Keychain access partway through skips
        // rather than fails.
        try skippingIfUnavailable { try store.save(credentials, for: keychainAccount) }
        addTeardownBlock { try? store.delete(for: keychainAccount) }

        XCTAssertEqual(
            try skippingIfUnavailable { try store.load(for: keychainAccount) }, credentials
        )

        try skippingIfUnavailable {
            try store.replaceRefreshToken("VSQ-Canary-refresh-2", for: keychainAccount)
        }
        let updated = try skippingIfUnavailable { try store.load(for: keychainAccount) }
        XCTAssertEqual(updated?.refreshToken, "VSQ-Canary-refresh-2")
        XCTAssertEqual(updated?.rememberedTwoFactorToken, "VSQ-Canary-2fa")

        try skippingIfUnavailable { try store.delete(for: keychainAccount) }
        XCTAssertNil(try skippingIfUnavailable { try store.load(for: keychainAccount) })
    }

    /// Runs a Keychain operation, converting a store-unavailable status into an
    /// `XCTSkip` so the test skips (rather than fails) on a host without
    /// Keychain access.
    private func skippingIfUnavailable<T>(_ block: () throws -> T) throws -> T {
        do {
            return try block()
        } catch VaultwardenCredentialStoreError.storeUnavailable(let status) {
            throw XCTSkip("Keychain unavailable on this host (OSStatus \(status)).")
        }
    }
}
