import CryptoKit
import XCTest
@testable import VaultSquire

final class BiometricUnlockTests: XCTestCase {
    private let account = AccountID.vaultwardenPrimary
    /// A synthetic 64-byte user key: 32 bytes of encryption key then 32 of MAC.
    private let userKeyData = Data((0..<64).map { UInt8($0) })
    private let wrappedUserKey = "2.wrapped|iv|mac"

    private func makeService(
        alsoConfiguring extra: [AccountDescriptor] = []
    ) throws -> (VaultwardenAccountService, VaultwardenVaultCache) {
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
        for descriptor in extra {
            descriptors.upsert(descriptor)
        }
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
        store: FakeBiometricVaultKeyStore,
        protonExecutor: FakeCLIExecutor? = nil
    ) throws -> AppModel {
        // Proton is configured only when a test drives its CLI, so the vaults
        // the other tests see stay exactly what they were.
        let (service, _) = try makeService(
            alsoConfiguring: protonExecutor == nil ? [] : [Self.protonDescriptor]
        )
        return AppModel(
            queryAccountPresence: { .present },
            service: service,
            protonService: makeProtonService(executor: protonExecutor ?? FakeCLIExecutor()),
            biometricStore: store
        )
    }

    private static let protonDescriptor = AccountDescriptor(
        account: ProtonAccountService.accountID,
        serverDisplay: "Proton Pass",
        email: "Official Proton Pass CLI"
    )

    /// A Proton service whose CLI is always "installed" and whose every command
    /// is answered by the supplied fake, so no child process is ever spawned.
    private func makeProtonService(executor: FakeCLIExecutor) -> ProtonAccountService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VSQ-bio-proton-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        return ProtonAccountService(
            locator: ProtonCLILocator(
                candidatePaths: ["/opt/homebrew/bin/pass-cli"],
                isExecutable: { _ in true },
                resolveRealPath: { $0 }
            ),
            executor: executor,
            versionGate: ProtonCLIVersionGate(supportedVersions: ["2.2.4"]),
            cache: ProtonSnapshotCache(keyProvider: { key }, directory: directory)
        )
    }

    /// Main-actor isolated like its callers: a nonisolated `async` helper would
    /// have to send the (non-Sendable) test case across an isolation boundary,
    /// which Swift 6 rejects. The synchronous helpers above need no annotation
    /// because they never suspend.
    @MainActor
    private func stubSignedInCLI(_ executor: FakeCLIExecutor) async {
        await executor.stub(arguments: ["--version"], stdout: "pass-cli 2.2.4\n")
        await executor.stub(
            arguments: ["vault", "list", "--output", "json"],
            stdout: #"{"vaults":[{"shareId":"S1","name":"Personal"}]}"#
        )
        await executor.stub(
            arguments: ["item", "list", "--share-id", "S1", "--output", "json"],
            stdout: #"{"items":[{"id":"i1","type":"login","title":"GitHub","content":{"username":"octocat"}}]}"#
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

    // MARK: - Opening the rest of the app

    /// One gesture opens the app. Touch ID releases the Vaultwarden key, and the
    /// vaults that have no credential of their own to collect — here Proton,
    /// read through the CLI session the user already established — come up with
    /// it instead of waiting behind a second button press.
    @MainActor
    func testUnlockAlsoOpensTheVaultsThatNeedNoCredential() async throws {
        let store = FakeBiometricVaultKeyStore()
        try store.store(userKey: userKeyData, boundTo: wrappedUserKey, for: account)
        let executor = FakeCLIExecutor()
        await stubSignedInCLI(executor)
        let model = try makeModel(store: store, protonExecutor: executor)
        model.refreshAccountPresence()
        XCTAssertEqual(model.sessions.count, 2)

        model.unlockWithBiometrics()
        try await pollUntil {
            model.session(for: ProtonAccountService.accountID)?.isOpen == true
        }
        XCTAssertEqual(model.session(for: account)?.isOpen, true)
        XCTAssertTrue(
            model.allOpenItems.contains { $0.displayTitle == "GitHub" },
            "the Proton item is in All Vaults without a second press"
        )
        XCTAssertNil(model.unlockError)
    }

    /// A vault opened alongside the unlocked one keeps its failure to its own
    /// row: a signed-out Proton CLI says nothing about the master password, so
    /// its message must never reach the password prompt.
    @MainActor
    func testACredentialFreeVaultsFailureStaysOnItsOwnRow() async throws {
        let store = FakeBiometricVaultKeyStore()
        try store.store(userKey: userKeyData, boundTo: wrappedUserKey, for: account)
        let executor = FakeCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "pass-cli 2.2.4\n")
        await executor.stub(
            arguments: ["vault", "list", "--output", "json"], stdout: Data(), exitCode: 1
        )
        let model = try makeModel(store: store, protonExecutor: executor)
        model.refreshAccountPresence()

        model.unlockWithBiometrics()
        try await pollUntil {
            guard let state = model.session(for: ProtonAccountService.accountID)?.state,
                  case .failed = state else {
                return false
            }
            return true
        }
        XCTAssertEqual(model.session(for: account)?.isOpen, true, "the unlocked vault stays open")
        XCTAssertNil(model.unlockError, "and the password prompt is not handed Proton's message")
    }

    /// Locking everything and unlocking again brings the whole set back, so the
    /// convenience is not a one-shot at launch.
    @MainActor
    func testLockingEverythingAndUnlockingAgainReopensBoth() async throws {
        let store = FakeBiometricVaultKeyStore()
        try store.store(userKey: userKeyData, boundTo: wrappedUserKey, for: account)
        let executor = FakeCLIExecutor()
        await stubSignedInCLI(executor)
        let model = try makeModel(store: store, protonExecutor: executor)
        model.refreshAccountPresence()

        model.unlockWithBiometrics()
        try await pollUntil {
            model.session(for: ProtonAccountService.accountID)?.isOpen == true
        }

        model.lock()
        XCTAssertTrue(model.isLocked)
        XCTAssertEqual(model.session(for: ProtonAccountService.accountID)?.isOpen, false)

        model.unlockWithBiometrics()
        try await pollUntil {
            model.session(for: ProtonAccountService.accountID)?.isOpen == true
        }
        XCTAssertEqual(model.session(for: account)?.isOpen, true)
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
