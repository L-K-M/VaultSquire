import Foundation

enum VaultSessionError: Error, Equatable, Sendable {
    case invalidTransition
}

/// Owns the mutable session state, the session generation, and the decrypted
/// projections. Transitions are serialized by actor isolation. Every
/// asynchronous result must present the generation it was started under, and
/// anything stale is discarded, so a lock during any asynchronous state leaves
/// the app locked with no late state publication.
actor VaultSession {
    private(set) var state = VaultSessionState.initial
    /// Decrypted display projections. Memory only; cleared on every lock.
    private(set) var projectedItems: [VaultItemProjection] = []

    private var generationCounter: UInt64 = 0
    private var activeGeneration: SessionGeneration?
    private var authenticationOrigin: AccountState?
    private var registeredWork: [UUID: Task<Void, Never>] = [:]

    // MARK: Account dimension

    func beginAuthentication() throws {
        switch state.account {
        case .noAccount, .reauthenticationRequired, .challenged:
            authenticationOrigin = state.account
            state.account = .authenticating
        case .authenticating, .authenticated, .loggingOut:
            throw VaultSessionError.invalidTransition
        }
    }

    func presentChallenge() throws {
        guard state.account == .authenticating else {
            throw VaultSessionError.invalidTransition
        }

        state.account = .challenged
    }

    func completeAuthentication() throws {
        switch state.account {
        case .authenticating, .challenged:
            authenticationOrigin = nil
            state.account = .authenticated
        case .noAccount, .authenticated, .reauthenticationRequired, .loggingOut:
            throw VaultSessionError.invalidTransition
        }
    }

    /// Returns to where authentication started. A cancelled reauthentication
    /// leaves the account in `reauthenticationRequired` with its cached state
    /// intact; only an explicit logout or documented revocation deletes cache.
    func cancelAuthentication() throws {
        switch state.account {
        case .authenticating, .challenged:
            state.account = authenticationOrigin == .reauthenticationRequired
                ? .reauthenticationRequired
                : .noAccount
            authenticationOrigin = nil
        case .noAccount, .authenticated, .reauthenticationRequired, .loggingOut:
            throw VaultSessionError.invalidTransition
        }
    }

    func requireReauthentication() throws {
        guard state.account == .authenticated else {
            throw VaultSessionError.invalidTransition
        }

        state.account = .reauthenticationRequired
    }

    func beginLogout() throws {
        switch state.account {
        case .authenticated, .reauthenticationRequired:
            state.account = .loggingOut
            lock()
        case .noAccount, .authenticating, .challenged, .loggingOut:
            throw VaultSessionError.invalidTransition
        }
    }

    func completeLogout() throws {
        guard state.account == .loggingOut else {
            throw VaultSessionError.invalidTransition
        }

        state.account = .noAccount
    }

    // MARK: Vault-access dimension

    /// Issues the new session generation an unlock attempt must carry.
    /// Reauthentication gates remote access, not the local cache, so an
    /// account in `reauthenticationRequired` may still unlock cached data.
    func beginUnlock() throws -> SessionGeneration {
        switch state.account {
        case .authenticated, .reauthenticationRequired:
            break
        case .noAccount, .authenticating, .challenged, .loggingOut:
            throw VaultSessionError.invalidTransition
        }
        guard state.vaultAccess == .locked else {
            throw VaultSessionError.invalidTransition
        }

        generationCounter += 1
        let generation = SessionGeneration(rawValue: generationCounter)
        activeGeneration = generation
        state.vaultAccess = .unlocking(generation)
        return generation
    }

    /// Publishes a finished unlock. A stale generation — most importantly one
    /// invalidated by a lock while the unlock was in flight — is discarded and
    /// the vault stays locked.
    @discardableResult
    func completeUnlock(_ generation: SessionGeneration) -> Bool {
        guard activeGeneration == generation,
              state.vaultAccess == .unlocking(generation) else {
            return false
        }

        state.vaultAccess = .unlocked(generation)
        return true
    }

    /// Publishes decrypted projections produced under `generation`. Late
    /// results carrying a stale generation are discarded without touching
    /// published state.
    @discardableResult
    func publish(
        _ projections: [VaultItemProjection],
        generation: SessionGeneration
    ) -> Bool {
        guard activeGeneration == generation,
              state.vaultAccess == .unlocked(generation) else {
            return false
        }

        projectedItems = projections
        return true
    }

    /// Locks unconditionally and idempotently; locking must never fail. The
    /// generation is invalidated before registered work is cancelled so a
    /// cancellation handler that races ahead can never publish plaintext.
    func lock() {
        state.vaultAccess = .locking
        generationCounter += 1
        activeGeneration = nil

        let work = registeredWork.values
        registeredWork.removeAll()
        for task in work {
            task.cancel()
        }

        projectedItems = []
        state.vaultAccess = .locked
    }

    // MARK: Cancellation registry

    /// Registers plaintext-producing work to be cancelled by the next lock.
    func register(_ task: Task<Void, Never>) -> UUID {
        let token = UUID()
        registeredWork[token] = task
        return token
    }

    func unregister(_ token: UUID) {
        registeredWork[token] = nil
    }

    // MARK: Connectivity dimension

    func setConnectivity(_ connectivity: ConnectivityState) {
        state.connectivity = connectivity
    }

    // MARK: Sync dimension

    /// Sync transitions carry snapshot generations and are valid while the
    /// vault is locked: ciphertext-only sync does not require a session
    /// generation to exist.
    func beginSyncCheck() throws {
        switch state.syncOperation {
        case .idle, .failed:
            state.syncOperation = .checking
        case .checking, .syncing:
            throw VaultSessionError.invalidTransition
        }
    }

    func beginSyncApply(candidate: SnapshotGeneration) throws {
        guard state.syncOperation == .checking else {
            throw VaultSessionError.invalidTransition
        }

        state.syncOperation = .syncing(candidate)
    }

    func completeSync() throws {
        guard case .syncing = state.syncOperation else {
            throw VaultSessionError.invalidTransition
        }

        state.syncOperation = .idle
    }

    func failSync() throws {
        switch state.syncOperation {
        case .checking, .syncing:
            state.syncOperation = .failed
        case .idle, .failed:
            throw VaultSessionError.invalidTransition
        }
    }

    func clearSyncFailure() throws {
        guard state.syncOperation == .failed else {
            throw VaultSessionError.invalidTransition
        }

        state.syncOperation = .idle
    }
}
