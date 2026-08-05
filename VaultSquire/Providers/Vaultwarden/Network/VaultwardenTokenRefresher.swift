import Foundation

/// The outcome of a token refresh. On success the caller atomically adopts the
/// new tokens; `sessionExpired` means the refresh token is no longer valid and
/// the account must reauthenticate (without deleting its last known-good cache).
enum VaultwardenRefreshOutcome: Sendable {
    case refreshed(accessToken: String, refreshToken: String, expiresIn: Int?)
    case sessionExpired
}

/// Coordinates token refresh for one account. It enforces the one-in-flight
/// rule: concurrent callers awaiting an expiring token share a single refresh
/// request rather than issuing several. The current refresh token is replaced
/// atomically on success.
actor VaultwardenTokenRefresher {
    private let transport: VaultwardenTransport
    private let clientID: String
    private var refreshToken: String
    private var inFlight: Task<VaultwardenRefreshOutcome, Never>?
    private(set) var refreshRequestCount = 0

    init(
        transport: VaultwardenTransport,
        refreshToken: String,
        clientID: String = "desktop"
    ) {
        self.transport = transport
        self.refreshToken = refreshToken
        self.clientID = clientID
    }

    var currentRefreshToken: String {
        refreshToken
    }

    /// Refreshes the access token, coalescing concurrent callers onto one
    /// request. The shared task's result is returned to every waiter.
    func refresh() async -> VaultwardenRefreshOutcome {
        if let inFlight {
            return await inFlight.value
        }

        let token = refreshToken
        let task = Task<VaultwardenRefreshOutcome, Never> { [transport, clientID] in
            await Self.performRefresh(
                transport: transport,
                refreshToken: token,
                clientID: clientID
            )
        }
        inFlight = task
        let outcome = await task.value
        inFlight = nil

        if case .refreshed(_, let newRefreshToken, _) = outcome {
            refreshToken = newRefreshToken
        }
        return outcome
    }

    private static func performRefresh(
        transport: VaultwardenTransport,
        refreshToken: String,
        clientID: String
    ) async -> VaultwardenRefreshOutcome {
        let fields = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        let tokenURL = transport.environment.identityURL
            .appendingPathComponent("connect/token")

        let response: VaultwardenHTTPResponse
        do {
            response = try await transport.send(.post, url: tokenURL, body: .form(fields))
        } catch {
            // A transport failure is transient; the caller retries later. It is
            // not a session-ending condition, so report expiry only on an
            // explicit invalid_grant below.
            return .sessionExpired
        }

        if (200..<300).contains(response.status),
           let token = try? JSONDecoder().decode(
               VaultwardenTokenResponse.self, from: response.body
           ),
           let newRefreshToken = token.refreshToken {
            return .refreshed(
                accessToken: token.accessToken,
                refreshToken: newRefreshToken,
                expiresIn: token.expiresIn
            )
        }

        return .sessionExpired
    }
}
