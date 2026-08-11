import Foundation

/// The outcome of a token refresh. On success the caller atomically adopts the
/// new tokens; `sessionExpired` means the refresh token is no longer valid and
/// the account must reauthenticate (without deleting its last known-good
/// cache); `transientFailure` is a network or rate-limit condition the caller
/// retries later without ending the session.
enum VaultwardenRefreshOutcome: Sendable {
    case refreshed(accessToken: String, refreshToken: String, expiresIn: Int?)
    case sessionExpired
    case transientFailure
}

/// Coordinates token refresh for one account. It enforces the one-in-flight
/// rule: concurrent callers awaiting an expiring token share a single refresh
/// request rather than issuing several. The current refresh token is replaced
/// atomically on success.
actor VaultwardenTokenRefresher {
    private let transport: VaultwardenTransport
    private let clientID: String
    /// The identity base URL the login transaction approved. Defaults to the
    /// configured identity URL; a split-origin login passes its effective one
    /// so refresh targets the same server.
    private let identityBaseURL: URL
    private var refreshToken: String
    private var inFlight: Task<VaultwardenRefreshOutcome, Never>?
    /// Number of network refresh requests actually issued. Coalesced callers do
    /// not increment it, so it stays below the caller count when the
    /// one-in-flight rule holds.
    private(set) var refreshRequestCount = 0

    init(
        transport: VaultwardenTransport,
        refreshToken: String,
        identityBaseURL: URL? = nil,
        clientID: String = "desktop"
    ) {
        self.transport = transport
        self.refreshToken = refreshToken
        self.identityBaseURL = identityBaseURL ?? transport.environment.identityURL
        self.clientID = clientID
    }

    var currentRefreshToken: String {
        refreshToken
    }

    /// Refreshes the access token, coalescing concurrent callers onto one
    /// request. The shared task's result is returned to every waiter.
    func refresh() async -> VaultwardenRefreshOutcome {
        guard Self.isValidToken(refreshToken) else { return .sessionExpired }
        if let inFlight {
            return await withTaskCancellationHandler {
                await inFlight.value
            } onCancel: {
                inFlight.cancel()
            }
        }

        let token = refreshToken
        refreshRequestCount += 1
        let task = Task<VaultwardenRefreshOutcome, Never> { [transport, clientID, identityBaseURL] in
            await Self.performRefresh(
                transport: transport,
                refreshToken: token,
                clientID: clientID,
                identityBaseURL: identityBaseURL
            )
        }
        inFlight = task
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        inFlight = nil
        guard !Task.isCancelled else { return .transientFailure }

        // Replace the stored token only on success; a failed refresh leaves the
        // last valid refresh token in place for a later retry.
        if case .refreshed(_, let newRefreshToken, _) = outcome {
            refreshToken = newRefreshToken
        }
        return outcome
    }

    private static func performRefresh(
        transport: VaultwardenTransport,
        refreshToken: String,
        clientID: String,
        identityBaseURL: URL
    ) async -> VaultwardenRefreshOutcome {
        // The refresh grant carries exactly grant_type, refresh_token, and
        // client_id per the recorded protocol; device fields belong only on the
        // password grant.
        let fields = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        let tokenURL = identityBaseURL.appendingPathComponent("connect/token")

        var response: VaultwardenHTTPResponse
        do {
            response = try await transport.send(
                .post,
                url: tokenURL,
                body: .form(fields),
                responseLimit: 1 * 1024 * 1024
            )
        } catch {
            // A transport failure is transient; the caller retries later. It is
            // not a session-ending condition.
            return .transientFailure
        }
        defer { response.discardBody() }

        if (200..<300).contains(response.status) {
            if let token = try? JSONDecoder().decode(
                   VaultwardenTokenResponse.self, from: response.body
               ),
               let newRefreshToken = token.refreshToken,
               isValidToken(token.accessToken),
               isValidToken(newRefreshToken),
               token.tokenType.map({ $0.caseInsensitiveCompare("Bearer") == .orderedSame }) != false,
               token.expiresIn.map({ $0 > 0 && $0 <= 31_536_000 }) != false {
                return .refreshed(
                    accessToken: token.accessToken,
                    refreshToken: newRefreshToken,
                    expiresIn: token.expiresIn
                )
            }
            // A success without a usable refresh token is malformed, not a
            // revoked session; retry rather than force reauthentication.
            return .transientFailure
        }

        // A rejected refresh grant (400/401) is permanent: the token is no
        // longer usable, so end the session and reauthenticate rather than
        // retrying a request that can never succeed. A rate limit (429) or
        // server error (5xx) is transient.
        if response.status == 400 || response.status == 401 {
            return .sessionExpired
        }

        return .transientFailure
    }

    private static func isValidToken(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 16 * 1024
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }
}
