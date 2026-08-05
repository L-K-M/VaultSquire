import Foundation

/// Per-installation device identity sent on token grants. The identifier is a
/// persistent random UUID; persistence is a later workstream, so the caller
/// supplies it here and holds it in memory.
struct VaultwardenDeviceIdentity: Hashable, Sendable {
    let identifier: String
    let name: String
}

/// The in-memory result of a completed login. Tokens and key material stay in
/// memory; nothing is persisted in this slice.
struct VaultwardenAuthSession: Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    /// 32-byte master key and 64-byte stretched key for later unlock, held by
    /// the caller's session owner.
    let masterKey: Data
    let stretchedMasterKey: Data
    let wrappedUserKey: String?
    let wrappedPrivateKey: String?
    let rememberTwoFactorToken: String?
    let kdfConfiguration: VaultwardenKDFConfiguration
}

/// Carries the derived proof and key material across a 2FA prompt so the grant
/// can be resubmitted without re-deriving from the master password. Its
/// members are non-public: only the authenticator constructs and consumes it.
struct VaultwardenPendingTwoFactor: Sendable {
    fileprivate let authHash: String
    fileprivate let masterKey: Data
    fileprivate let stretchedMasterKey: Data
    fileprivate let kdfConfiguration: VaultwardenKDFConfiguration
    fileprivate let normalizedEmail: String
    fileprivate let device: VaultwardenDeviceIdentity
    /// The approved identity and API base URLs the continuation must reuse, so
    /// the grant and email challenge target the same endpoints the login
    /// transaction already approved.
    fileprivate let identityBaseURL: URL
    fileprivate let apiBaseURL: URL
}

enum VaultwardenLoginOutcome: Sendable {
    case authenticated(VaultwardenAuthSession)
    case twoFactorRequired(VaultwardenTwoFactorChallenge, pending: VaultwardenPendingTwoFactor)
}

enum VaultwardenKDFChangeDecision: Sendable {
    case approve
    case reject
}

/// Confirms a KDF algorithm/parameter change before derivation. First login
/// passes `last == nil`; unchanged settings are not routed here.
protocol VaultwardenKDFChangePolicy: Sendable {
    func confirmChange(
        from last: VaultwardenKDFConfiguration?,
        to next: VaultwardenKDFConfiguration
    ) async -> VaultwardenKDFChangeDecision
}

/// Approves effective API/identity origins that differ from the entered one
/// before the email is sent. Denial aborts before any credential-derived data
/// leaves the device.
protocol VaultwardenOriginApprovalPolicy: Sendable {
    func approve(
        entered: VaultwardenOrigin,
        effectiveIdentity: VaultwardenOrigin,
        effectiveAPI: VaultwardenOrigin
    ) async -> Bool
}

/// Drives the headless Vaultwarden login transaction: config discovery,
/// effective-origin approval, prelogin, KDF validation and change
/// confirmation, local derivation, the token grant, and 2FA continuation.
/// It performs no persistence and owns no UI.
struct VaultwardenAuthenticator: Sendable {
    let transport: VaultwardenTransport
    let kdfChangePolicy: VaultwardenKDFChangePolicy
    let originApprovalPolicy: VaultwardenOriginApprovalPolicy

    private var environment: VaultwardenEnvironment { transport.environment }

    /// Runs config discovery through the token grant. Returns
    /// `.twoFactorRequired` when the server signals a second factor; the caller
    /// completes it with `completeTwoFactor`.
    func login(
        email: String,
        masterPasswordBytes: Data,
        device: VaultwardenDeviceIdentity,
        lastAcceptedKDF: VaultwardenKDFConfiguration?
    ) async throws -> VaultwardenLoginOutcome {
        let endpoints = try await resolveEffectiveEndpoints()

        let normalizedEmail = VaultwardenKeyDerivation.normalizedEmail(email)
        let prelogin = try await fetchPrelogin(
            email: normalizedEmail,
            identityBase: endpoints.identityBase
        )
        let kdfConfiguration = try mapKDF(prelogin)

        if !kdfMatches(kdfConfiguration, lastAcceptedKDF) {
            let decision = await kdfChangePolicy.confirmChange(
                from: lastAcceptedKDF,
                to: kdfConfiguration
            )
            guard decision == .approve else {
                throw VaultwardenAPIError(
                    category: .incompatibleCrypto,
                    safeDisplayMessage: "The server's key-derivation settings changed and were not approved."
                )
            }
        }

        let masterKey: Data
        let stretchedMasterKey: Data
        let authHash: String
        do {
            masterKey = try await VaultwardenKeyDerivation.deriveMasterKey(
                passwordBytes: masterPasswordBytes,
                email: normalizedEmail,
                configuration: kdfConfiguration
            )
            stretchedMasterKey = try VaultwardenKeyDerivation.stretchMasterKey(masterKey)
            authHash = try VaultwardenKeyDerivation.authenticationHash(
                masterKey: masterKey,
                passwordBytes: masterPasswordBytes
            )
        } catch let error as VaultwardenCryptoError {
            throw Self.mapCryptoError(error)
        }

        let pending = VaultwardenPendingTwoFactor(
            authHash: authHash,
            masterKey: masterKey,
            stretchedMasterKey: stretchedMasterKey,
            kdfConfiguration: kdfConfiguration,
            normalizedEmail: normalizedEmail,
            device: device,
            identityBaseURL: endpoints.identityBase,
            apiBaseURL: endpoints.apiBase
        )

        return try await submitGrant(pending: pending, proof: nil)
    }

    /// Resubmits the token grant with a second-factor proof.
    func completeTwoFactor(
        _ pending: VaultwardenPendingTwoFactor,
        proof: VaultwardenTwoFactorProof
    ) async throws -> VaultwardenAuthSession {
        guard proof.provider.isUserCompletable else {
            throw VaultwardenAPIError(
                category: .unsupportedTwoFactorProvider,
                safeDisplayMessage: "This two-factor method is not supported yet."
            )
        }

        let outcome = try await submitGrant(pending: pending, proof: proof)
        switch outcome {
        case .authenticated(let session):
            return session
        case .twoFactorRequired:
            // A resubmitted proof that still returns a challenge is a failed
            // proof, reported as bad credentials for the factor.
            throw VaultwardenAPIError(
                category: .badCredentials,
                safeDisplayMessage: "The two-factor code was not accepted."
            )
        }
    }

    /// Sends the email-provider challenge so the user can receive a code.
    func sendEmailChallenge(pending: VaultwardenPendingTwoFactor) async throws {
        let url = pending.apiBaseURL.appendingPathComponent("two-factor/send-email-login")
        let response = try await transport.send(
            .post,
            url: url,
            body: .json(Data("{\"email\":\"\(pending.normalizedEmail)\"}".utf8))
        )
        guard (200..<300).contains(response.status) else {
            throw Self.error(from: response)
        }
    }

    // MARK: - Steps

    /// Fetches `/api/config` (before any email is sent), resolves the effective
    /// identity and API base URLs, and, when either differs from the entered
    /// origin, requires explicit approval. The approved base URLs are returned
    /// so prelogin, the token grant, and the email challenge all target them.
    private func resolveEffectiveEndpoints() async throws -> (identityBase: URL, apiBase: URL) {
        let configURL = environment.apiURL.appendingPathComponent("config")
        let response: VaultwardenHTTPResponse
        do {
            response = try await transport.send(.get, url: configURL)
        } catch {
            throw Self.mapTransportError(error)
        }
        guard (200..<300).contains(response.status) else {
            throw Self.error(from: response)
        }

        let entered = environment.origin
        let config = try? JSONDecoder().decode(
            VaultwardenConfig.self, from: response.body
        )
        let identityBase = baseURL(
            from: config?.environment?.identity, fallback: environment.identityURL
        )
        let apiBase = baseURL(
            from: config?.environment?.api, fallback: environment.apiURL
        )
        let effectiveIdentity = originOf(identityBase, fallback: entered)
        let effectiveAPI = originOf(apiBase, fallback: entered)

        if effectiveIdentity != entered || effectiveAPI != entered {
            let approved = await originApprovalPolicy.approve(
                entered: entered,
                effectiveIdentity: effectiveIdentity,
                effectiveAPI: effectiveAPI
            )
            guard approved else {
                throw VaultwardenAPIError(
                    category: .badCredentials,
                    safeDisplayMessage: "The server's effective origin was not approved."
                )
            }
        }

        return (identityBase, apiBase)
    }

    private func fetchPrelogin(
        email: String,
        identityBase: URL
    ) async throws -> VaultwardenPrelogin {
        let body = Data("{\"email\":\"\(email)\"}".utf8)
        let currentURL = identityBase.appendingPathComponent("accounts/prelogin/password")
        var response = try await transport.send(.post, url: currentURL, body: .json(body))

        // Legacy servers expose only the un-suffixed alias.
        if response.status == 404 {
            let legacyURL = identityBase.appendingPathComponent("accounts/prelogin")
            response = try await transport.send(.post, url: legacyURL, body: .json(body))
        }
        guard (200..<300).contains(response.status) else {
            throw Self.error(from: response)
        }

        do {
            return try JSONDecoder().decode(VaultwardenPrelogin.self, from: response.body)
        } catch {
            throw VaultwardenAPIError(
                category: .incompatibleCrypto,
                httpStatus: response.status,
                safeDisplayMessage: "The server returned unreadable key-derivation settings."
            )
        }
    }

    private func submitGrant(
        pending: VaultwardenPendingTwoFactor,
        proof: VaultwardenTwoFactorProof?
    ) async throws -> VaultwardenLoginOutcome {
        var fields: [String: String] = [
            "grant_type": "password",
            "username": pending.normalizedEmail,
            "password": pending.authHash,
            "scope": "api offline_access",
            "client_id": "desktop",
            "device_type": "7",
            "device_identifier": pending.device.identifier,
            "device_name": pending.device.name,
        ]
        if let proof {
            fields["two_factor_provider"] = String(proof.provider.rawValue)
            fields["two_factor_token"] = proof.token
            if proof.rememberDevice {
                fields["two_factor_remember"] = "1"
            }
        }

        let tokenURL = pending.identityBaseURL.appendingPathComponent("connect/token")
        let response = try await transport.send(.post, url: tokenURL, body: .form(fields))

        if (200..<300).contains(response.status) {
            let token = try decodeToken(response)
            let session = VaultwardenAuthSession(
                accessToken: token.accessToken,
                refreshToken: token.refreshToken,
                expiresIn: token.expiresIn,
                masterKey: pending.masterKey,
                stretchedMasterKey: pending.stretchedMasterKey,
                wrappedUserKey: token.key,
                wrappedPrivateKey: token.privateKey,
                rememberTwoFactorToken: token.twoFactorToken,
                kdfConfiguration: pending.kdfConfiguration
            )
            return .authenticated(session)
        }

        // A 400 carrying challenge maps is a 2FA requirement, not a failure,
        // but only on the first grant. A resubmitted proof that comes back with
        // maps is handled by completeTwoFactor as a failed proof.
        let body = try? JSONDecoder().decode(VaultwardenErrorBody.self, from: response.body)
        if response.status == 400, proof == nil, let body, body.signalsTwoFactorChallenge {
            let challenge = VaultwardenTwoFactorChallenge(
                offeredProviderIDs: body.offeredProviderIDs
            )
            return .twoFactorRequired(challenge, pending: pending)
        }

        throw VaultwardenErrorDecoder.classify(
            httpStatus: response.status,
            body: body,
            retryAfter: response.retryAfter
        )
    }

    // MARK: - Helpers

    private func decodeToken(_ response: VaultwardenHTTPResponse) throws -> VaultwardenTokenResponse {
        do {
            return try JSONDecoder().decode(
                VaultwardenTokenResponse.self, from: response.body
            )
        } catch {
            throw VaultwardenAPIError(
                category: .unexpected,
                httpStatus: response.status,
                safeDisplayMessage: "The server returned an unreadable token response."
            )
        }
    }

    private func mapKDF(_ prelogin: VaultwardenPrelogin) throws -> VaultwardenKDFConfiguration {
        do {
            let configuration = try prelogin.configuration()
            try configuration.validate()
            return configuration
        } catch let error as VaultwardenCryptoError {
            throw Self.mapCryptoError(error)
        }
    }

    private func kdfMatches(
        _ lhs: VaultwardenKDFConfiguration,
        _ rhs: VaultwardenKDFConfiguration?
    ) -> Bool {
        guard let rhs else {
            return false
        }

        return lhs == rhs
    }

    /// Resolves a config-advertised service URL to a usable base URL. A value
    /// that is not a valid absolute URL with a host falls back to the entered
    /// service URL, so a malformed or relative advertisement never redirects
    /// credentials somewhere unexpected.
    private func baseURL(from urlString: String?, fallback: URL) -> URL {
        guard let urlString, !urlString.isEmpty,
              let url = URL(string: urlString),
              url.scheme != nil, url.host != nil else {
            return fallback
        }

        return url
    }

    private func originOf(_ url: URL, fallback: VaultwardenOrigin) -> VaultwardenOrigin {
        guard let scheme = url.scheme?.lowercased(), let host = url.host else {
            return fallback
        }

        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return VaultwardenOrigin(scheme: scheme, host: host.lowercased(), port: port)
    }

    private static func error(from response: VaultwardenHTTPResponse) -> VaultwardenAPIError {
        let body = try? JSONDecoder().decode(VaultwardenErrorBody.self, from: response.body)
        return VaultwardenErrorDecoder.classify(
            httpStatus: response.status,
            body: body,
            retryAfter: response.retryAfter
        )
    }

    private static func mapTransportError(_ error: Error) -> VaultwardenAPIError {
        if let apiError = error as? VaultwardenAPIError {
            return apiError
        }

        return VaultwardenAPIError(
            category: .network,
            retry: .backoffThenRetry(retryAfter: nil),
            safeDisplayMessage: "The server could not be reached."
        )
    }

    private static func mapCryptoError(_ error: VaultwardenCryptoError) -> VaultwardenAPIError {
        VaultwardenAPIError(
            category: .incompatibleCrypto,
            safeDisplayMessage: "The account's key-derivation settings are not supported."
        )
    }
}
