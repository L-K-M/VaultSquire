import Foundation

enum VaultwardenSyncError: Error, Equatable, Sendable {
    /// The refresh token is no longer valid; the account must reauthenticate.
    /// The caller keeps the last good snapshot — a sync failure never wipes it.
    case sessionExpired
    /// A network or rate-limit condition; retry later without ending the session.
    case transient
    /// The server's sync response could not be decoded.
    case malformedResponse
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
            return .failure(.transient)
        }

        let syncURL = transport.environment.apiURL.appendingPathComponent("sync")
        let response: VaultwardenHTTPResponse
        do {
            response = try await transport.send(.get, url: syncURL, bearer: accessToken)
        } catch {
            return .failure(.transient)
        }

        if response.status == 401 {
            return .failure(.sessionExpired)
        }
        guard (200..<300).contains(response.status) else {
            return .failure(.transient)
        }

        let decoded: VaultwardenSyncResponse
        do {
            decoded = try JSONDecoder().decode(VaultwardenSyncResponse.self, from: response.body)
        } catch {
            return .failure(.malformedResponse)
        }

        let updated = merge(current: current, sync: decoded, capturedAt: capturedAt)
        let newRefreshToken = await refresher.currentRefreshToken
        return .success(Success(snapshot: updated, refreshToken: newRefreshToken))
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
