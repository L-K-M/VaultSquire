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
    /// This single-account build already holds a different server/account.
    case existingAccountMismatch
    /// Only part of the local account transaction exists; overwriting it would
    /// hide credentials or ciphertext rather than repairing it atomically.
    case inconsistentLocalState
    /// The provider hierarchy changed or its refresh session ended; a complete
    /// login is required before cached content can be opened again.
    case reauthenticationRequired
    /// Reauthentication succeeded, but its mandatory replacement full sync did
    /// not complete, so the prior marked snapshot remains authoritative.
    case replacementSyncFailed
}

/// The unlocked material and derived items for one account, held only while the
/// vault is unlocked.
struct VaultwardenUnlockedVault: Sendable {
    let keyring: VaultwardenKeyring
    var snapshot: VaultwardenVaultSnapshot
    var items: [VaultItemProjection]
    /// Folder id to decrypted folder name. Held so the sidebar can list every
    /// folder the account has, including one holding no items, which a list
    /// derived only from the items themselves would never show.
    var folderNames: [String: String] = [:]
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

    /// Returns the persisted KDF baseline for a login to the same configured
    /// account. A different server/email or a partial prior transaction fails
    /// before any credential-derived proof is sent; this single-account build
    /// never silently overwrites one account with another.
    func loginBaseline(
        serverBaseURL: URL,
        email: String
    ) throws -> VaultwardenKDFConfiguration? {
        let snapshot = try vaultCache.load(for: account)
        let descriptor = descriptorStore.descriptor(for: account)
        // This is a security transaction, not a shell presence probe: load and
        // validate the complete record so malformed/weak Keychain state blocks
        // before any credential-derived proof leaves.
        let credentialsExist = try credentialStore.load(for: .primary) != nil

        guard snapshot != nil || descriptor != nil || credentialsExist else {
            return nil
        }
        // Every durable part must agree before credential-derived proof leaves.
        // A token alone cannot identify its server/account, and a descriptor or
        // cache alone is likewise an interrupted transaction; none is silently
        // adopted or overwritten as a fresh account.
        guard let snapshot, descriptor != nil, credentialsExist else {
            throw VaultwardenAccountError.inconsistentLocalState
        }
        let storedEnvironment = try VaultwardenEnvironment(configuredURL: snapshot.serverBaseURL)
        let normalizedEmail = VaultwardenKeyDerivation.normalizedEmail(email)
        guard storedEnvironment.base == serverBaseURL,
              snapshot.email == normalizedEmail else {
            throw VaultwardenAccountError.existingAccountMismatch
        }
        return try snapshot.kdf.configuration()
    }

    /// Commits a just-authenticated account. A first login may persist an empty
    /// seed because it has no prior ciphertext to revive. Reauthentication is
    /// stricter: its replacement hierarchy must complete a full sync while the
    /// prior cache remains marked/authoritative, and only that complete
    /// candidate may replace it.
    func persistAfterLogin(
        session: VaultwardenAuthSession,
        serverBaseURL: URL,
        email: String
    ) async throws {
        let descriptor = AccountDescriptor(
            account: account,
            serverDisplay: serverBaseURL.host ?? serverBaseURL.absoluteString,
            email: VaultwardenKeyDerivation.normalizedEmail(email)
        )
        let previousSnapshot = try vaultCache.load(for: account)
        guard previousSnapshot?.generation != UInt64.max else {
            throw VaultwardenAccountError.inconsistentLocalState
        }
        var snapshot = VaultwardenVaultSnapshot(
            version: VaultwardenVaultSnapshot.currentVersion,
            serverBaseURL: serverBaseURL.absoluteString,
            identityBaseURL: session.identityBaseURL.absoluteString,
            apiBaseURL: session.apiBaseURL.absoluteString,
            email: VaultwardenKeyDerivation.normalizedEmail(email),
            kdf: .init(configuration: session.kdfConfiguration),
            wrappedUserKey: session.wrappedUserKey ?? "",
            wrappedPrivateKey: session.wrappedPrivateKey,
            organizations: [],
            folders: [],
            ciphers: [],
            syncedAt: now(),
            generation: previousSnapshot?.generation ?? 1
        )

        if previousSnapshot != nil {
            guard let stored = try credentialStore.load(for: .primary) else {
                throw VaultwardenAccountError.replacementSyncFailed
            }
            let environment = try VaultwardenEnvironment(
                configuredURL: serverBaseURL.absoluteString
            )
            let transport = makeTransport(environment)
            let refresher = VaultwardenTokenRefresher(
                transport: transport,
                refreshToken: stored.refreshToken,
                identityBaseURL: session.identityBaseURL
            )
            let syncService = VaultwardenSyncService(
                transport: transport,
                apiBaseURL: session.apiBaseURL
            )
            let result = await syncService.sync(
                current: snapshot,
                refresher: refresher,
                capturedAt: now(),
                persistRefreshToken: { token in
                    try credentialStore.replaceRefreshToken(token, for: .primary)
                }
            )
            guard !Task.isCancelled,
                  case .success(let success) = result else {
                throw VaultwardenAccountError.replacementSyncFailed
            }
            snapshot = success.snapshot
        }

        // The cache is the only durable copy of the approved origins, KDF, and
        // wrapped hierarchy. Commit it before the non-secret descriptor, and
        // restore the prior cache if descriptor verification fails.
        try vaultCache.save(snapshot, for: account)
        guard descriptorStore.upsert(descriptor) else {
            if let previousSnapshot {
                try? vaultCache.save(previousSnapshot, for: account)
            } else {
                try? vaultCache.wipe(for: account)
            }
            throw VaultwardenAccountError.inconsistentLocalState
        }
    }

    func loadSnapshot() throws -> VaultwardenVaultSnapshot? {
        try vaultCache.load(for: account)
    }

    // MARK: - Unlock

    func unlock(masterPasswordBytes: Data) async throws -> VaultwardenUnlockedVault {
        guard var snapshot = try vaultCache.load(for: account) else {
            throw VaultwardenAccountError.noVault
        }
        guard snapshot.reauthenticationRequired != true else {
            throw VaultwardenAccountError.reauthenticationRequired
        }
        // Some servers return the wrapped user key only from the sync profile,
        // so a freshly added account can hold a seed with no key yet. Fetch the
        // authoritative vault before deriving any keyring; a successful sync
        // fills the wrapped key material.
        if snapshot.wrappedUserKey.isEmpty {
            _ = await sync()
            guard let refreshed = try vaultCache.load(for: account) else {
                throw VaultwardenAccountError.noVault
            }
            snapshot = refreshed
            guard snapshot.reauthenticationRequired != true else {
                throw VaultwardenAccountError.reauthenticationRequired
            }
        }
        guard !snapshot.wrappedUserKey.isEmpty else {
            throw VaultwardenAccountError.missingKeyMaterial
        }
        let keyring = try await VaultwardenVaultUnlock.unlock(
            snapshot: snapshot, masterPasswordBytes: masterPasswordBytes
        )
        let folderNames = decryptFolderNames(keyring: keyring, snapshot: snapshot)
        return VaultwardenUnlockedVault(
            keyring: keyring,
            snapshot: snapshot,
            items: projections(
                keyring: keyring, snapshot: snapshot, folderNames: folderNames
            ),
            folderNames: folderNames
        )
    }

    /// Opens the stored vault with an already-unwrapped user key, for a Touch ID
    /// unlock. The key came from the biometry-protected Keychain entry, which is
    /// bound to the snapshot's current wrapped user key, so a rotated key cannot
    /// silently open a vault it no longer matches.
    func unlock(userKeyData: Data) async throws -> VaultwardenUnlockedVault {
        guard let snapshot = try vaultCache.load(for: account) else {
            throw VaultwardenAccountError.noVault
        }
        guard snapshot.reauthenticationRequired != true else {
            throw VaultwardenAccountError.reauthenticationRequired
        }
        guard let userKey = try? VaultwardenSymmetricKey(keyData: userKeyData) else {
            throw VaultwardenAccountError.missingKeyMaterial
        }
        let keyring = VaultwardenVaultUnlock.keyring(snapshot: snapshot, userKey: userKey)
        let folderNames = decryptFolderNames(keyring: keyring, snapshot: snapshot)
        return VaultwardenUnlockedVault(
            keyring: keyring,
            snapshot: snapshot,
            items: projections(
                keyring: keyring, snapshot: snapshot, folderNames: folderNames
            ),
            folderNames: folderNames
        )
    }

    /// The wrapped user key a biometric entry is bound to, so enrollment and
    /// unlock can agree on which key material the stored key belongs to.
    func reauthenticationIsRequired() throws -> Bool {
        try vaultCache.load(for: account)?.reauthenticationRequired == true
    }

    func currentWrappedUserKey() async -> String? {
        guard let snapshot = try? vaultCache.load(for: account),
              snapshot.reauthenticationRequired != true else {
            return nil
        }
        return snapshot.wrappedUserKey
    }

    func projections(
        keyring: VaultwardenKeyring,
        snapshot: VaultwardenVaultSnapshot
    ) -> [VaultItemProjection] {
        return projections(
            keyring: keyring,
            snapshot: snapshot,
            folderNames: decryptFolderNames(keyring: keyring, snapshot: snapshot)
        )
    }

    private func projections(
        keyring: VaultwardenKeyring,
        snapshot: VaultwardenVaultSnapshot,
        folderNames: [String: String]
    ) -> [VaultItemProjection] {
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
        guard itemID.account == account,
              let cipher = snapshot.ciphers.first(where: {
                  VaultwardenItemDecryptor.itemID(for: $0, account: account) == itemID
              }) else {
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
        guard itemID.account == account,
              let cipher = snapshot.ciphers.first(where: {
                  VaultwardenItemDecryptor.itemID(for: $0, account: account) == itemID
              }),
              cipher.type == .login else {
            return nil
        }
        let contentKey = keyring.key(for: cipher)
        func decrypt(_ value: String?) -> String { keyring.decrypt(value, key: contentKey) ?? "" }
        return VaultItemDraft(
            itemID: itemID,
            title: decrypt(cipher.name),
            username: decrypt(cipher.login?.username),
            password: decrypt(cipher.login?.password),
            totp: decrypt(cipher.login?.totp),
            websites: (cipher.login?.uris ?? []).compactMap {
                keyring.decrypt($0.uri, key: contentKey)
            },
            notes: decrypt(cipher.notes),
            favorite: cipher.favorite
        )
    }

    func decryptFolderNames(
        keyring: VaultwardenKeyring,
        snapshot: VaultwardenVaultSnapshot
    ) -> [String: String] {
        var names: [String: String] = [:]
        var remainingBytes = 4 * 1024 * 1024
        for folder in snapshot.folders {
            let maximum = min(4_096, remainingBytes)
            let decrypted = maximum > 0 ? keyring.decrypt(
                folder.name,
                organizationID: nil,
                maximumUTF8Bytes: maximum
            ) : nil
            let safeName = (decrypted?.isEmpty == false) ? decrypted! : "Folder"
            names[folder.id] = safeName
            remainingBytes = max(0, remainingBytes - safeName.utf8.count)
        }
        return names
    }

    // MARK: - Capabilities and writes

    /// The actions this build is authorized to expose. Mutations stay absent:
    /// the required official-client interoperability, revision/conflict,
    /// ambiguity, cancellation, permission-change, and unsupported-field
    /// survival gates have not passed. Keeping the dormant implementation
    /// behind this use-case gate makes an accidental UI action fail closed too.
    static let capabilities: Set<ProviderCapability> = [
        .viewItems, .searchItems, .revealSecret, .copySecret,
    ]

    var capabilityGate: CapabilityGate { CapabilityGate(capabilities: Self.capabilities) }

    /// Production mutation entry points are hard-disabled in addition to the
    /// empty capability set. The implementation harness lives behind DEBUG for
    /// protocol tests, but no release call path can obtain network credentials
    /// or construct a mutation request.
    func create(
        draft: VaultItemDraft,
        keyring: VaultwardenKeyring
    ) async -> Result<Void, VaultwardenWriteError> {
        .failure(.rejected)
    }

    func update(
        draft: VaultItemDraft,
        keyring: VaultwardenKeyring
    ) async -> Result<Void, VaultwardenWriteError> {
        .failure(.rejected)
    }

    func archive(itemID: VaultItemID) async -> Result<Void, VaultwardenWriteError> {
        .failure(.rejected)
    }

    /// The API base approved at login, parsed from the snapshot. Nil for
    /// snapshots sealed before the field existed; callers then fall back to
    /// deriving the API URL from the configured base.
    private static func approvedAPIBase(of snapshot: VaultwardenVaultSnapshot) -> URL? {
        snapshot.apiBaseURL.flatMap(URL.init(string:))
    }

    // MARK: - Sync

    /// Refreshes and fetches the vault, persisting the updated snapshot and the
    /// rotated refresh token on success. Ordinary failures preserve the last
    /// good cache; observed bootstrap drift replaces it with a durable lockout
    /// marker (or destroys its sealing path) before requiring login.
    func sync() async -> Result<VaultwardenVaultSnapshot, VaultwardenSyncError> {
        let snapshot: VaultwardenVaultSnapshot
        do {
            guard let loaded = try vaultCache.load(for: account) else {
                return .failure(.localStorageFailed)
            }
            snapshot = loaded
        } catch {
            return .failure(.localStorageFailed)
        }
        guard snapshot.reauthenticationRequired != true else {
            return .failure(.reauthenticationRequired)
        }

        let refreshToken: String
        do {
            guard let stored = try credentialStore.load(for: .primary) else {
                return .failure(.localStorageFailed)
            }
            refreshToken = stored.refreshToken
        } catch {
            return .failure(.localStorageFailed)
        }

        let environment: VaultwardenEnvironment
        do {
            environment = try VaultwardenEnvironment(configuredURL: snapshot.serverBaseURL)
        } catch {
            return .failure(.localStorageFailed)
        }
        let transport = makeTransport(environment)
        let refresher = VaultwardenTokenRefresher(
            transport: transport,
            refreshToken: refreshToken,
            identityBaseURL: URL(string: snapshot.identityBaseURL)
        )
        let service = VaultwardenSyncService(
            transport: transport,
            apiBaseURL: Self.approvedAPIBase(of: snapshot)
        )

        let result = await service.sync(
            current: snapshot,
            refresher: refresher,
            capturedAt: now(),
            persistRefreshToken: { token in
                try credentialStore.replaceRefreshToken(token, for: .primary)
            }
        )
        switch result {
        case .success(let success):
            guard !Task.isCancelled else { return .failure(.transient) }
            // Publication requires a complete durable cache commit. The rotated
            // token was already replaced immediately after refresh, so a cache
            // failure leaves the prior snapshot intact without stranding the
            // network session.
            do {
                try vaultCache.save(success.snapshot, for: account)
            } catch {
                return .failure(.localStorageFailed)
            }
            return .success(success.snapshot)
        case .failure(.reauthenticationRequired):
            persistReauthenticationMarker(over: snapshot)
            return .failure(.reauthenticationRequired)
        case .failure(.sessionExpired):
            // Refresh invalid_grant is an account-state transition, not an
            // ordinary sync error. Keep ciphertext but prevent another offline
            // or biometric unlock until a complete login replaces the marker.
            persistReauthenticationMarker(over: snapshot)
            return .failure(.sessionExpired)
        case .failure(let error):
            return .failure(error)
        }
    }

    private func persistReauthenticationMarker(
        over snapshot: VaultwardenVaultSnapshot
    ) {
        var blocked = snapshot
        blocked.reauthenticationRequired = true
        do {
            try vaultCache.save(blocked, for: account)
        } catch {
            // If the durable marker cannot be committed, destroy the old
            // offline-open path. If even the file cannot be removed,
            // invalidate its device-only sealing key as the final durable
            // fail-closed boundary.
            do {
                try vaultCache.wipe(for: account)
            } catch {
                try? vaultCache.invalidateSealingKey()
            }
        }
    }
}
