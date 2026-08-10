import Foundation

extension AccountID {
    /// The single configured Vaultwarden account this release supports. The
    /// multi-account workstream replaces this fixed identity with per-account
    /// keys; until then one opaque id pairs with `VaultwardenAccountKey.primary`.
    static let vaultwardenPrimary = AccountID(provider: .vaultwarden, rawValue: "primary")
}

enum VaultwardenAccountError: Error, Equatable, Sendable {
    /// No stored vault exists for the account (never signed in, or the cache is
    /// unavailable on this host).
    case noVault
    /// The server did not return the wrapped user key at login, so nothing can
    /// be unlocked.
    case missingKeyMaterial
}

/// The unlocked material and derived items for one account, held only while the
/// vault is unlocked.
struct VaultwardenUnlockedVault: Sendable {
    let keyring: VaultwardenKeyring
    var snapshot: VaultwardenVaultSnapshot
    var items: [VaultItemProjection]
}

/// Orchestrates one Vaultwarden account across the credential store, the sealed
/// vault cache, the sync service, and the unlock crypto. It owns no state — the
/// caller (AppModel) holds the unlocked vault — so it stays a value type the UI
/// layer can construct with test doubles.
struct VaultwardenAccountService: Sendable {
    let account: AccountID
    let credentialStore: any VaultwardenCredentialStore
    let vaultCache: VaultwardenVaultCache
    let descriptorStore: AccountDescriptorStore
    let makeTransport: @Sendable (VaultwardenEnvironment) -> VaultwardenTransport
    let now: @Sendable () -> Date

    init(
        account: AccountID = .vaultwardenPrimary,
        credentialStore: any VaultwardenCredentialStore = KeychainCredentialStore(),
        vaultCache: VaultwardenVaultCache = VaultwardenVaultCache(),
        descriptorStore: AccountDescriptorStore = AccountDescriptorStore(),
        makeTransport: @escaping @Sendable (VaultwardenEnvironment) -> VaultwardenTransport = {
            VaultwardenTransport(environment: $0)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.account = account
        self.credentialStore = credentialStore
        self.vaultCache = vaultCache
        self.descriptorStore = descriptorStore
        self.makeTransport = makeTransport
        self.now = now
    }

    // MARK: - Configuration

    /// Persists the just-authenticated account: an initial empty-vault snapshot
    /// sealed to the cache and a non-secret descriptor. The refresh token is
    /// stored separately by the add-account flow. Throws `missingKeyMaterial`
    /// when the login returned no wrapped user key.
    func persistAfterLogin(
        session: VaultwardenAuthSession,
        serverBaseURL: URL,
        email: String
    ) throws {
        guard let wrappedUserKey = session.wrappedUserKey else {
            throw VaultwardenAccountError.missingKeyMaterial
        }
        let snapshot = VaultwardenVaultSnapshot(
            version: VaultwardenVaultSnapshot.currentVersion,
            serverBaseURL: serverBaseURL.absoluteString,
            identityBaseURL: session.identityBaseURL.absoluteString,
            email: VaultwardenKeyDerivation.normalizedEmail(email),
            kdf: .init(configuration: session.kdfConfiguration),
            wrappedUserKey: wrappedUserKey,
            wrappedPrivateKey: session.wrappedPrivateKey,
            organizations: [],
            folders: [],
            ciphers: [],
            syncedAt: now(),
            generation: 1
        )
        try vaultCache.save(snapshot, for: account)
        descriptorStore.upsert(AccountDescriptor(
            account: account,
            serverDisplay: serverBaseURL.host ?? serverBaseURL.absoluteString,
            email: VaultwardenKeyDerivation.normalizedEmail(email)
        ))
    }

    func loadSnapshot() throws -> VaultwardenVaultSnapshot? {
        try vaultCache.load(for: account)
    }

    // MARK: - Unlock

    func unlock(masterPasswordBytes: Data) async throws -> VaultwardenUnlockedVault {
        guard let snapshot = try vaultCache.load(for: account) else {
            throw VaultwardenAccountError.noVault
        }
        let keyring = try await VaultwardenVaultUnlock.unlock(
            snapshot: snapshot, masterPasswordBytes: masterPasswordBytes
        )
        return VaultwardenUnlockedVault(
            keyring: keyring,
            snapshot: snapshot,
            items: projections(keyring: keyring, snapshot: snapshot)
        )
    }

    func projections(
        keyring: VaultwardenKeyring,
        snapshot: VaultwardenVaultSnapshot
    ) -> [VaultItemProjection] {
        let folderNames = decryptFolderNames(keyring: keyring, snapshot: snapshot)
        return snapshot.ciphers
            .map {
                VaultwardenItemDecryptor.projection(
                    for: $0,
                    keyring: keyring,
                    account: account,
                    folderNames: folderNames,
                    generation: snapshot.generation
                )
            }
            .sorted { lhs, rhs in
                lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            }
    }

    func detail(
        for itemID: VaultItemID,
        keyring: VaultwardenKeyring,
        snapshot: VaultwardenVaultSnapshot
    ) -> VaultItemDetail? {
        guard let cipher = snapshot.ciphers.first(where: { $0.id == itemID.rawValue }) else {
            return nil
        }
        return VaultwardenItemDecryptor.detail(
            for: cipher, keyring: keyring, account: account, generation: snapshot.generation
        )
    }

    private func decryptFolderNames(
        keyring: VaultwardenKeyring,
        snapshot: VaultwardenVaultSnapshot
    ) -> [String: String] {
        var names: [String: String] = [:]
        for folder in snapshot.folders {
            if let name = keyring.decrypt(folder.name, organizationID: nil) {
                names[folder.id] = name
            }
        }
        return names
    }

    // MARK: - Sync

    /// Refreshes and fetches the vault, persisting the updated snapshot and the
    /// rotated refresh token on success. Returns the new snapshot, or a sync
    /// error that never disturbs the last good cache.
    func sync() async -> Result<VaultwardenVaultSnapshot, VaultwardenSyncError> {
        let snapshot: VaultwardenVaultSnapshot
        do {
            guard let loaded = try vaultCache.load(for: account) else {
                return .failure(.sessionExpired)
            }
            snapshot = loaded
        } catch {
            return .failure(.transient)
        }

        let refreshToken: String
        do {
            guard let stored = try credentialStore.load(for: .primary) else {
                return .failure(.sessionExpired)
            }
            refreshToken = stored.refreshToken
        } catch {
            return .failure(.transient)
        }

        let environment: VaultwardenEnvironment
        do {
            environment = try VaultwardenEnvironment(configuredURL: snapshot.serverBaseURL)
        } catch {
            return .failure(.transient)
        }
        let transport = makeTransport(environment)
        let refresher = VaultwardenTokenRefresher(
            transport: transport,
            refreshToken: refreshToken,
            identityBaseURL: URL(string: snapshot.identityBaseURL)
        )
        let service = VaultwardenSyncService(transport: transport)

        let result = await service.sync(current: snapshot, refresher: refresher, capturedAt: now())
        switch result {
        case .success(let success):
            do {
                try vaultCache.save(success.snapshot, for: account)
                try? credentialStore.replaceRefreshToken(success.refreshToken, for: .primary)
            } catch {
                return .failure(.transient)
            }
            return .success(success.snapshot)
        case .failure(let error):
            return .failure(error)
        }
    }
}
