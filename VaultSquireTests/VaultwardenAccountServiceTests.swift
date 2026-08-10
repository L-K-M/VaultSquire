import CryptoKit
import XCTest
@testable import VaultSquire

final class VaultwardenAccountServiceTests: XCTestCase {
    private func makeService() -> (
        service: VaultwardenAccountService,
        descriptors: AccountDescriptorStore,
        cache: VaultwardenVaultCache,
        account: AccountID
    ) {
        let account = AccountID.vaultwardenPrimary
        let defaults = UserDefaults(suiteName: "VaultSquireTest-\(UUID().uuidString)")!
        let descriptors = AccountDescriptorStore(defaults: defaults)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VSQ-acct-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let cache = VaultwardenVaultCache(keyProvider: { key }, directory: directory)
        let service = VaultwardenAccountService(
            account: account,
            credentialStore: InMemoryCredentialStore(),
            vaultCache: cache,
            descriptorStore: descriptors
        )
        return (service, descriptors, cache, account)
    }

    private func session(wrappedUserKey: String?) -> VaultwardenAuthSession {
        VaultwardenAuthSession(
            accessToken: "a",
            refreshToken: "r",
            expiresIn: 3600,
            masterKey: Data(repeating: 1, count: 32),
            stretchedMasterKey: Data(repeating: 2, count: 64),
            wrappedUserKey: wrappedUserKey,
            wrappedPrivateKey: nil,
            rememberTwoFactorToken: nil,
            kdfConfiguration: .pbkdf2SHA256(iterations: 600_000),
            identityBaseURL: URL(string: "https://vault.example.com/identity")!
        )
    }

    /// The regression: a login whose token carried no wrapped user key must
    /// still leave a descriptor, so the shell shows an unlock prompt instead of
    /// the dead promptless locked state.
    func testPersistAfterLoginWritesDescriptorWhenTokenHasNoWrappedKey() throws {
        let (service, descriptors, cache, account) = makeService()

        service.persistAfterLogin(
            session: session(wrappedUserKey: nil),
            serverBaseURL: URL(string: "https://vault.example.com")!,
            email: "User@Example.com"
        )

        XCTAssertEqual(descriptors.all().map(\.account), [account])
        // The cache is seeded with an empty key the first unlock's sync fills.
        let snapshot = try XCTUnwrap(try cache.load(for: account))
        XCTAssertTrue(snapshot.wrappedUserKey.isEmpty)
        XCTAssertEqual(snapshot.serverBaseURL, "https://vault.example.com")
    }

    func testPersistAfterLoginSeedsTheWrappedKeyWhenTheTokenProvidesIt() throws {
        let (service, descriptors, cache, account) = makeService()

        service.persistAfterLogin(
            session: session(wrappedUserKey: "2.userkey|mac"),
            serverBaseURL: URL(string: "https://vault.example.com")!,
            email: "u@example.com"
        )

        XCTAssertEqual(descriptors.all().count, 1)
        let snapshot = try XCTUnwrap(try cache.load(for: account))
        XCTAssertEqual(snapshot.wrappedUserKey, "2.userkey|mac")
    }

    /// The token grant is snake_case, but the wrapped key material is PascalCase
    /// on most servers and lowerCamel on some. Both must decode so a login never
    /// silently loses the key.
    func testTokenResponseAcceptsBothKeyCasings() throws {
        let pascal = try JSONDecoder().decode(
            VaultwardenTokenResponse.self,
            from: Data(#"{"access_token":"a","Key":"2.k","PrivateKey":"2.pk"}"#.utf8)
        )
        XCTAssertEqual(pascal.key, "2.k")
        XCTAssertEqual(pascal.privateKey, "2.pk")

        let lower = try JSONDecoder().decode(
            VaultwardenTokenResponse.self,
            from: Data(#"{"access_token":"a","key":"2.k2","privateKey":"2.pk2"}"#.utf8)
        )
        XCTAssertEqual(lower.key, "2.k2")
        XCTAssertEqual(lower.privateKey, "2.pk2")
    }
}
