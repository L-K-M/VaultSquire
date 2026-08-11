import Foundation

enum VaultwardenSyncError: Error, Equatable, Sendable {
    /// The refresh token is no longer valid; the account must reauthenticate.
    /// The account layer preserves its ciphertext behind a durable lockout
    /// marker, or destroys the offline-open path if that marker cannot commit.
    case sessionExpired
    /// The network transport failed while fetching the vault. This is the only
    /// case that genuinely means "couldn't reach the server"; every other
    /// failure keeps its own case so the message never blames the network for
    /// a different problem.
    case transient
    /// The token refresh failed for a non-terminal reason: network trouble, a
    /// rate limit, or a server error. Distinct from `transient` because the
    /// vault fetch never ran.
    case refreshFailed
    /// TLS trust failed on refresh or sync. Distinct wording prevents a
    /// certificate failure from being presented as ordinary reachability.
    case tlsFailure
    /// The vault fetch returned an HTTP status that is neither success nor a
    /// session rejection. The status is carried for display; it is not secret.
    case unexpectedStatus(Int)
    /// The sync response exceeded the transport's response-size bound.
    case responseTooLarge
    /// The server's sync response could not be decoded.
    case malformedResponse
    /// The provider's wrapped hierarchy or security stamp changed. The new
    /// candidate is not promoted; the account must complete a new login.
    case reauthenticationRequired
    /// The locally stored account context (sealed snapshot, credentials, or
    /// server URL) could not be read on this device; the network was never
    /// consulted.
    case localStorageFailed
}

/// Fetches `GET /api/sync` and folds it into the account's vault snapshot.
///
/// It refreshes the access token first (the access token is never persisted;
/// only the rotating refresh token is), fetches the vault, and produces an
/// updated snapshot that preserves the account context the sync response does
/// not carry — email, KDF, and the approved base URLs come from the prior
/// snapshot, while ciphers, folders, organization keys, and the wrapped key
/// material come from the server. The rotated refresh token is returned for the
/// caller to persist.
struct VaultwardenSyncService: Sendable {
    let transport: VaultwardenTransport
    /// The API base approved at login (".../api"). When absent the API URL is
    /// derived from the configured base, which is only correct for same-origin
    /// servers; a split-origin server's sync must target its advertised API.
    var apiBaseURL: URL? = nil

    struct Success: Sendable {
        let snapshot: VaultwardenVaultSnapshot
        let refreshToken: String
    }

    func sync(
        current: VaultwardenVaultSnapshot,
        refresher: VaultwardenTokenRefresher,
        capturedAt: Date,
        persistRefreshToken: @Sendable (String) throws -> Void = { _ in }
    ) async -> Result<Success, VaultwardenSyncError> {
        let accessToken: String
        switch await refresher.refresh() {
        case .refreshed(let token, let rotatedRefreshToken, _):
            guard !Task.isCancelled else { return .failure(.transient) }
            // Rotation may invalidate the old token before the subsequent vault
            // read finishes. Persist it immediately; tying replacement to a
            // successful sync strands the account whenever that read fails or
            // is cancelled after refresh.
            do {
                try persistRefreshToken(rotatedRefreshToken)
            } catch {
                return .failure(.localStorageFailed)
            }
            accessToken = token
        case .sessionExpired:
            return .failure(.sessionExpired)
        case .tlsFailure:
            return .failure(.tlsFailure)
        case .transientFailure:
            return .failure(.refreshFailed)
        }

        let syncURL = (apiBaseURL ?? transport.environment.apiURL)
            .appendingPathComponent("sync")
        let response: VaultwardenHTTPResponse
        do {
            response = try await transport.send(.get, url: syncURL, bearer: accessToken)
        } catch VaultwardenTransportError.responseTooLarge {
            return .failure(.responseTooLarge)
        } catch VaultwardenTransportError.tlsFailure {
            return .failure(.tlsFailure)
        } catch {
            return .failure(.transient)
        }

        if response.status == 401 {
            return .failure(.sessionExpired)
        }
        guard (200..<300).contains(response.status) else {
            // A blocked redirect surfaces here as its 3xx status.
            return .failure(.unexpectedStatus(response.status))
        }

        let decoded: VaultwardenSyncResponse
        do {
            decoded = try JSONDecoder().decode(VaultwardenSyncResponse.self, from: response.body)
        } catch {
            return .failure(.malformedResponse)
        }

        guard !Task.isCancelled else { return .failure(.transient) }
        guard !Self.bootstrapChanged(current: current, sync: decoded) else {
            return .failure(.reauthenticationRequired)
        }
        guard let updated = merge(
            current: current,
            sync: decoded,
            rawResponse: response.body,
            capturedAt: capturedAt
        ) else {
            return .failure(.malformedResponse)
        }
        guard !Task.isCancelled else { return .failure(.transient) }
        let newRefreshToken = await refresher.currentRefreshToken
        return .success(Success(snapshot: updated, refreshToken: newRefreshToken))
    }

    private static func bootstrapChanged(
        current: VaultwardenVaultSnapshot,
        sync: VaultwardenSyncResponse
    ) -> Bool {
        if !current.wrappedUserKey.isEmpty {
            guard let next = sync.profile.key,
                  next == current.wrappedUserKey else {
                return true
            }
        }
        if let previous = current.wrappedPrivateKey {
            guard let next = sync.profile.privateKey,
                  next == previous else {
                return true
            }
        }
        if let previous = current.securityStamp {
            guard let next = sync.profile.securityStamp,
                  next == previous else {
                return true
            }
        }
        return false
    }

    private func merge(
        current: VaultwardenVaultSnapshot,
        sync: VaultwardenSyncResponse,
        rawResponse: Data,
        capturedAt: Date
    ) -> VaultwardenVaultSnapshot? {
        guard current.generation < UInt64.max else { return nil }
        var updated = current
        // The sync profile reissues the wrapped key material; keep the prior
        // values when the server omits them so unlock never loses its key.
        updated.wrappedUserKey = sync.profile.key ?? current.wrappedUserKey
        updated.wrappedPrivateKey = sync.profile.privateKey ?? current.wrappedPrivateKey
        updated.securityStamp = sync.profile.securityStamp ?? current.securityStamp
        updated.organizations = sync.profile.organizations.map {
            .init(id: $0.id, name: $0.name, wrappedKey: $0.key)
        }
        updated.folders = sync.folders.map { .init(id: $0.id, name: $0.name) }
        updated.ciphers = sync.ciphers
        updated.rawSyncResponse = rawResponse
        updated.reauthenticationRequired = false
        updated.syncedAt = capturedAt
        updated.generation = current.generation + 1
        return updated.isStructurallyValid ? updated : nil
    }
}
