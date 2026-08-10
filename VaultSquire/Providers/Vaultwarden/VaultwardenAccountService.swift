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

    /// Reconstructs an editable plaintext draft from a stored login cipher.
    /// Returns nil for a missing item or a non-login type (only logins are
    /// editable in this slice).
    func draft(
        for itemID: VaultItemID,
        keyring: VaultwardenKeyring,
        snapshot: VaultwardenVaultSnapshot
    ) -> VaultItemDraft? {
        guard let cipher = snapshot.ciphers.first(where: { $0.id == itemID.rawValue }),
              cipher.type == .login else {
            return nil
        }
        let org = cipher.organizationID
        func decrypt(_ value: String?) -> String { keyring.decrypt(value, organizationID: org) ?? "" }
        return VaultItemDraft(
            itemID: itemID,
            title: decrypt(cipher.name),
            username: decrypt(cipher.login?.username),
            password: decrypt(cipher.login?.password),
            totp: decrypt(cipher.login?.totp),
            websites: (cipher.login?.uris ?? []).compactMap { keyring.decrypt($0.uri, organizationID: org) },
            notes: decrypt(cipher.notes),
            favorite: cipher.favorite
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

    // MARK: - Capabilities and writes

    /// The actions a Vaultwarden personal vault supports. Reads plus the writes
    /// this release implements; archive is included because Vaultwarden exposes
    /// per-user archiving. Every mutation is checked against this set through
    /// `CapabilityGate`, so a disabled control is never the only guard.
    static let capabilities: Set<ProviderCapability> = [
        .viewItems, .searchItems, .revealSecret, .copySecret,
        .createItem, .updateItem, .archiveItem,
    ]

    var capabilityGate: CapabilityGate { CapabilityGate(capabilities: Self.capabilities) }

    /// Creates a login item from an unlocked draft, then the caller re-syncs.
    func create(
        draft: VaultItemDraft,
        keyring: VaultwardenKeyring
    ) async -> Result<Void, VaultwardenWriteError> {
        let space = VaultSpaceID(account: account, scope: .personal)
        guard (try? capabilityGate.authorize(.createItem(space), from: .menu)) != nil else {
            return .failure(.rejected)
        }
        return await performWrite { token, transport in
            await VaultwardenWriteService(transport: transport)
                .createLogin(draft: draft, userKey: keyring.userKey, accessToken: token)
        }
    }

    /// Updates an existing login item.
    func update(
        draft: VaultItemDraft,
        keyring: VaultwardenKeyring
    ) async -> Result<Void, VaultwardenWriteError> {
        guard let itemID = draft.itemID else { return .failure(.rejected) }
        guard (try? capabilityGate.authorize(.updateItem(itemID), from: .menu)) != nil else {
            return .failure(.rejected)
        }
        return await performWrite { token, transport in
            await VaultwardenWriteService(transport: transport)
                .updateLogin(cipherID: itemID.rawValue, draft: draft, userKey: keyring.userKey, accessToken: token)
        }
    }

    /// Archives an item where the server supports it.
    func archive(itemID: VaultItemID) async -> Result<Void, VaultwardenWriteError> {
        guard (try? capabilityGate.authorize(.archiveItem(itemID), from: .menu)) != nil else {
            return .failure(.rejected)
        }
        return await performWrite { token, transport in
            await VaultwardenWriteService(transport: transport)
                .archive(cipherID: itemID.rawValue, accessToken: token)
        }
    }

    /// Loads the account context, refreshes to an access token, runs a write,
    /// and persists the rotated refresh token. A failed refresh reports
    /// session-expired; the write itself never touches the sealed cache — the
    /// caller re-syncs on success to pull the authoritative new state.
    private func performWrite(
        _ body: @Sendable (String, VaultwardenTransport) async -> Result<Void, VaultwardenWriteError>
    ) async -> Result<Void, VaultwardenWriteError> {
        let snapshot: VaultwardenVaultSnapshot
        let refreshToken: String
        do {
            guard let loaded = try vaultCache.load(for: account),
                  let stored = try credentialStore.load(for: .primary) else {
                return .failure(.sessionExpired)
            }
            snapshot = loaded
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
        let token: String
        switch await refresher.refresh() {
        case .refreshed(let accessToken, _, _):
            token = accessToken
        case .sessionExpired:
            return .failure(.sessionExpired)
        case .transientFailure:
            return .failure(.transient)
        }
        let rotatedRefreshToken = await refresher.currentRefreshToken
        try? credentialStore.replaceRefreshToken(rotatedRefreshToken, for: .primary)

        return await body(token, transport)
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
