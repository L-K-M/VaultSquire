import Foundation

enum VaultwardenSyncError: Error, Equatable, Sendable {
    /// The refresh token is no longer valid; the account must reauthenticate.
    /// The caller keeps the last good snapshot — a sync failure never wipes it.
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
    /// The vault fetch returned an HTTP status that is neither success nor a
    /// session rejection. The status is carried for display; it is not secret.
    case unexpectedStatus(Int)
    /// The sync response exceeded the transport's response-size bound.
    case responseTooLarge
    /// The server's sync response could not be decoded.
    case malformedResponse
    /// The sync response carried different bootstrap key material (a rotated
    /// wrapped user key or private key) than the snapshot holds. The candidate
    /// is NOT promoted: the prior snapshot and bootstrap data are retained,
    /// because retained ciphertext must never be decrypted under a rotated
    /// user key, and the old key must not be used to write new ciphertext.
    /// The account must re-authenticate.
    case bootstrapChanged
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
        capturedAt: Date
    ) async -> Result<Success, VaultwardenSyncError> {
        let accessToken: String
        switch await refresher.refresh() {
        case .refreshed(let token, _, _):
            accessToken = token
        case .sessionExpired:
            return .failure(.sessionExpired)
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

        // A changed wrapped user key or private key means the account's key
        // hierarchy rotated since this snapshot was captured. The candidate is
        // not promoted: the old keyring must never decrypt new ciphertext, and
        // the old key must never encrypt new writes. The empty-key case is
        // exempt — it is the first-unlock fill, where the snapshot has no key
        // yet and the sync is what supplies it.
        if bootstrapChanged(current: current, sync: decoded) {
            return .failure(.bootstrapChanged)
        }

        let updated = merge(current: current, sync: decoded, capturedAt: capturedAt)
        let newRefreshToken = await refresher.currentRefreshToken
        return .success(Success(snapshot: updated, refreshToken: newRefreshToken))
    }

    /// True when the sync response's wrapped key material differs from the
    /// snapshot's. A nil or empty server value is not a change (the merge
    /// keeps the prior value then); an empty stored value means the snapshot
    /// is still waiting for its first key and the sync is allowed to fill it.
    private func bootstrapChanged(
        current: VaultwardenVaultSnapshot,
        sync: VaultwardenSyncResponse
    ) -> Bool {
        if let newKey = sync.profile.key, !newKey.isEmpty,
           !current.wrappedUserKey.isEmpty,
           newKey != current.wrappedUserKey {
            return true
        }
        if let newPrivateKey = sync.profile.privateKey, !newPrivateKey.isEmpty,
           let currentPrivateKey = current.wrappedPrivateKey, !currentPrivateKey.isEmpty,
           newPrivateKey != currentPrivateKey {
            return true
        }
        return false
    }

    private func merge(
        current: VaultwardenVaultSnapshot,
        sync: VaultwardenSyncResponse,
        capturedAt: Date
    ) -> VaultwardenVaultSnapshot {
        var updated = current
        // The sync profile reissues the wrapped key material; keep the prior
        // values when the server omits them so unlock never loses its key.
        updated.wrappedUserKey = sync.profile.key ?? current.wrappedUserKey
        updated.wrappedPrivateKey = sync.profile.privateKey ?? current.wrappedPrivateKey
        updated.organizations = sync.profile.organizations.map {
            .init(id: $0.id, name: $0.name, wrappedKey: $0.key)
        }
        updated.folders = sync.folders.map { .init(id: $0.id, name: $0.name) }
        updated.ciphers = sync.ciphers
        updated.syncedAt = capturedAt
        updated.generation = current.generation + 1
        return updated
    }
}
