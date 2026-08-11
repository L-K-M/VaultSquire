import CryptoKit
import XCTest
@testable import VaultSquire

final class BiometricUnlockTests: XCTestCase {
    private let account = AccountID.vaultwardenPrimary
    /// A synthetic 64-byte user key: 32 bytes of encryption key then 32 of MAC.
    private let userKeyData = Data((0..<64).map { UInt8($0) })
    private let wrappedUserKey = "2.wrapped|iv|mac"

    private func makeService() throws -> (VaultwardenAccountService, VaultwardenVaultCache) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VSQ-bio-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let cache = VaultwardenVaultCache(keyProvider: { key }, directory: directory)
        let defaults = UserDefaults(suiteName: "VSQ-bio-\(UUID().uuidString)")!
        let descriptors = AccountDescriptorStore(defaults: defaults)
        // The vault must be configured for the model to build a session for it.
        descriptors.upsert(AccountDescriptor(
            account: account, serverDisplay: "vault.example.com", email: "user@example.com"
        ))
        let service = VaultwardenAccountService(
            account: account,
            credentialStore: InMemoryCredentialStore(),
            vaultCache: cache,
            descriptorStore: descriptors
        )
        try cache.save(makeSnapshot(), for: account)
        return (service, cache)
    }

    private func makeSnapshot() -> VaultwardenVaultSnapshot {
        VaultwardenVaultSnapshot(
            version: VaultwardenVaultSnapshot.currentVersion,
            serverBaseURL: "https://vault.example.com",
            identityBaseURL: "https://vault.example.com/identity",
            email: "user@example.com",
            kdf: .init(configuration: .pbkdf2SHA256(iterations: 600_000)),
            wrappedUserKey: wrappedUserKey,
            wrappedPrivateKey: nil,
            organizations: [],
            folders: [],
            ciphers: [],
            syncedAt: Date(timeIntervalSince1970: 1_700_000_000),
            generation: 2
        )
    }

    // MARK: - Key-only unlock

    func testUnlockWithAUserKeyOpensTheVaultWithoutAPassword() throws {
        let (service, _) = try makeService()
        let vault = try service.unlock(userKeyData: userKeyData)
        XCTAssertEqual(vault.keyring.userKey.encryptionKey, Data(userKeyData.prefix(32)))
        XCTAssertEqual(vault.keyring.userKey.macKey, Data(userKeyData.suffix(32)))
        XCTAssertEqual(vault.snapshot.wrappedUserKey, wrappedUserKey)
    }

    func testUnlockRejectsMalformedKeyMaterial() throws {
        let (service, _) = try makeService()
        XCTAssertThrowsError(try service.unlock(userKeyData: Data([1, 2, 3]))) { error in
            XCTAssertEqual(error as? VaultwardenAccountError, .missingKeyMaterial)
        }
    }

    func testCurrentWrappedUserKeyIsTheBindingValue() throws {
        let (service, _) = try makeService()
        XCTAssertEqual(service.currentWrappedUserKey(), wrappedUserKey)
    }

    // MARK: - AppModel flows

    @MainActor
    private func makeModel(
        store: FakeBiometricVaultKeyStore
    ) throws -> AppModel {
        let (service, _) = try makeService()
        return AppModel(
            queryAccountPresence: { .present },
            service: service,
            biometricStore: store
        )
    }

    @MainActor
    func testEnrolledKeyUnlocksWithBiometrics() async throws {
        let store = FakeBiometricVaultKeyStore()
        try store.store(userKey: userKeyData, boundTo: wrappedUserKey, for: account)
        let model = try makeModel(store: store)

        model.refreshAccountPresence()
        XCTAssertTrue(model.canUnlockWithBiometrics)

        model.unlockWithBiometrics()
        try await pollUntil { model.isUnlocked }
        XCTAssertNil(model.unlockError)
    }

    @MainActor
    func testBiometricsAreNotOfferedWhenUnavailable() throws {
        let store = FakeBiometricVaultKeyStore(available: false)
        try? store.store(userKey: userKeyData, boundTo: wrappedUserKey, for: account)
        let model = try makeModel(store: store)
        model.refreshAccountPresence()
        XCTAssertFalse(model.canUnlockWithBiometrics)
        XCTAssertFalse(model.canEnrollBiometrics)
    }

    /// A dismissed Touch ID prompt is a choice, not an error: the shell returns
    /// to the password field with nothing shouted at the user.
    @MainActor
    func testCancelledPromptReturnsToThePasswordFieldSilently() async throws {
        let store = FakeBiometricVaultKeyStore()
        try store.store(userKey: userKeyData, boundTo: wrappedUserKey, for: account)
        store.loadFailure = .cancelled
        let model = try makeModel(store: store)
        model.refreshAccountPresence()

        model.unlockWithBiometrics()
        try await pollUntil { !model.isUnlocking }
        XCTAssertTrue(model.isLocked)
        XCTAssertNil(model.unlockError)
    }

    @MainActor
    func testInvalidatedKeyTurnsTheOfferOffAndExplains() async throws {
        let store = FakeBiometricVaultKeyStore()
        try store.store(userKey: userKeyData, boundTo: wrappedUserKey, for: account)
        store.loadFailure = .invalidated
        let model = try makeModel(store: store)
        model.refreshAccountPresence()

        model.unlockWithBiometrics()
        try await pollUntil { !model.isUnlocking }
        XCTAssertTrue(model.isLocked)
        XCTAssertFalse(model.canUnlockWithBiometrics)
        XCTAssertNotNil(model.unlockError)
    }

    /// A key stored against different key material must not open the vault:
    /// rotating the vault key invalidates the enrollment.
    @MainActor
    func testKeyBoundToRotatedMaterialIsRejected() async throws {
        let store = FakeBiometricVaultKeyStore()
        try store.store(userKey: userKeyData, boundTo: "2.some-older-key|iv|mac", for: account)
        let model = try makeModel(store: store)
        model.refreshAccountPresence()

        model.unlockWithBiometrics()
        try await pollUntil { !model.isUnlocking }
        XCTAssertTrue(model.isLocked)
        XCTAssertFalse(store.hasKey(for: account), "the stale entry is dropped")
    }

    /// Enrollment stores the 64-byte user key — never the master password — and
    /// binds it to the snapshot's current wrapped key.
    @MainActor
    func testEnrollmentStoresTheUserKeyBoundToTheCurrentWrapping() async throws {
        let store = FakeBiometricVaultKeyStore()
        try store.store(userKey: userKeyData, boundTo: wrappedUserKey, for: account)
        let model = try makeModel(store: store)
        model.refreshAccountPresence()
        model.unlockWithBiometrics()
        try await pollUntil { model.isUnlocked }

        model.disableBiometricUnlock()
        XCTAssertFalse(store.hasKey(for: account))
        XCTAssertFalse(model.canUnlockWithBiometrics)
        XCTAssertTrue(model.canEnrollBiometrics, "an open vault can be enrolled")

        model.enableBiometricUnlock()
        XCTAssertTrue(store.hasKey(for: account))
        XCTAssertTrue(model.canUnlockWithBiometrics)

        // What was stored is the vault key, and it still opens the vault.
        let stored = try await store.loadUserKey(
            for: account, boundTo: wrappedUserKey, reason: "test"
        )
        XCTAssertEqual(stored.count, 64)
        XCTAssertEqual(stored, userKeyData)
    }

    /// The silent-failure regression: pressing the Settings button did nothing
    /// visible when the Keychain refused the write. Enrollment that fails must
    /// leave a message and must not claim to be enrolled.
    @MainActor
    func testFailedEnrollmentReportsInsteadOfDoingNothing() async throws {
        let store = FakeBiometricVaultKeyStore()
        try store.store(userKey: userKeyData, boundTo: wrappedUserKey, for: account)
        let model = try makeModel(store: store)
        model.refreshAccountPresence()
        model.unlockWithBiometrics()
        try await pollUntil { model.isUnlocked }

        model.disableBiometricUnlock()
        XCTAssertTrue(model.canEnrollBiometrics)

        store.storeFails = true
        model.enableBiometricUnlock()

        XCTAssertNotNil(model.biometricError, "a refused enrollment must say so")
        XCTAssertFalse(model.canUnlockWithBiometrics, "and must not claim to be enrolled")
    }

    /// Pressing enroll with no vault open explains itself rather than silently
    /// returning.
    @MainActor
    func testEnrollingWithNoOpenVaultExplainsItself() throws {
        let store = FakeBiometricVaultKeyStore()
        let model = try makeModel(store: store)
        model.refreshAccountPresence()

        model.enableBiometricUnlock()

        XCTAssertNotNil(model.biometricError)
        XCTAssertFalse(store.hasKey(for: account))
    }

    @MainActor
    func testLockingDropsTheEnrollmentOffer() async throws {
        let store = FakeBiometricVaultKeyStore()
        try store.store(userKey: userKeyData, boundTo: wrappedUserKey, for: account)
        let model = try makeModel(store: store)
        model.refreshAccountPresence()
        model.unlockWithBiometrics()
        try await pollUntil { model.isUnlocked }

        model.lock()
        XCTAssertTrue(model.isLocked)
        XCTAssertFalse(model.canEnrollBiometrics)
        // The enrolled key survives a lock: that is the point of enrolling.
        XCTAssertTrue(model.canUnlockWithBiometrics)
    }

    @MainActor
    private func pollUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition did not hold within the timeout", file: file, line: line)
    }
}
