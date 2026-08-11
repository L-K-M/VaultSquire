import Foundation

/// Per-installation device identity sent on token grants. The identifier is a
/// persistent random UUID; persistence is a later workstream, so the caller
/// supplies it here and holds it in memory.
struct VaultwardenDeviceIdentity: Hashable, Sendable {
    let identifier: String
    let name: String
}

/// The in-memory result of a completed login. Credential tokens are handed to
/// the Keychain transaction; credential-derived keys are deliberately absent.
struct VaultwardenAuthSession: Sendable {
    let refreshToken: String?
    let wrappedUserKey: String?
    let wrappedPrivateKey: String?
    let rememberTwoFactorToken: String?
    let kdfConfiguration: VaultwardenKDFConfiguration
    /// The approved identity base URL this session authenticated against, so a
    /// token refresher targets the same origin the login transaction approved.
    let identityBaseURL: URL
    /// The approved API base URL (".../api"), so sync and writes target the
    /// same service origin the login transaction approved. On a split-origin
    /// server this differs from the configured base; deriving the API URL from
    /// the configured base would miss the server's advertised API service.
    let apiBaseURL: URL
}

/// Carries only the derived authentication proof across a 2FA prompt so the
/// grant can be resubmitted without retaining the master or stretched key. Its
/// members are non-public: only the authenticator constructs and consumes it.
struct VaultwardenPendingTwoFactor: Sendable {
    fileprivate var authHash: String
    fileprivate let kdfConfiguration: VaultwardenKDFConfiguration
    fileprivate let normalizedEmail: String
    fileprivate let device: VaultwardenDeviceIdentity
    /// The approved identity and API base URLs the continuation must reuse, so
    /// the grant and email challenge target the same endpoints the login
    /// transaction already approved.
    fileprivate let identityBaseURL: URL
    fileprivate let apiBaseURL: URL

    mutating func discardSensitiveMaterial() {
        authHash.removeAll(keepingCapacity: false)
    }
}

enum VaultwardenLoginOutcome: Sendable {
    case authenticated(VaultwardenAuthSession)
    case twoFactorRequired(VaultwardenTwoFactorChallenge, pending: VaultwardenPendingTwoFactor)
}

enum VaultwardenKDFChangeDecision: Sendable {
    case approve
    case reject
}

/// Confirms a KDF algorithm/parameter change before derivation. It is
/// consulted only when a prior accepted configuration exists and differs from
/// the server's; first login (no baseline) and an unchanged configuration are
/// not routed here.
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
    private static let maximumEmailBytes = 320
    private static let maximumPasswordBytes = 16 * 1024
    private static let maximumTwoFactorBytes = 512
    private static let maximumURLBytes = 2_048
    private static let maximumAuthResponseBytes = 1 * 1024 * 1024

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
        let normalizedEmail = VaultwardenKeyDerivation.normalizedEmail(email)
        guard !normalizedEmail.isEmpty,
              normalizedEmail.utf8.count <= Self.maximumEmailBytes,
              normalizedEmail.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              !masterPasswordBytes.isEmpty,
              masterPasswordBytes.count <= Self.maximumPasswordBytes,
              !device.identifier.isEmpty,
              device.identifier.utf8.count <= 256,
              device.identifier.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              !device.name.isEmpty,
              device.name.utf8.count <= 512,
              device.name.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw VaultwardenAPIError(
                category: .unexpected,
                safeDisplayMessage: "The sign-in input is invalid or too large."
            )
        }
        let endpoints = try await resolveEffectiveEndpoints()

        let prelogin = try await fetchPrelogin(
            email: normalizedEmail,
            identityBase: endpoints.identityBase
        )
        let kdfConfiguration = try mapKDF(prelogin)

        // Confirmation is required only when a prior configuration exists and
        // differs. First login has no baseline, so it is not routed through the
        // change policy; a below-floor configuration is still refused by
        // validation regardless.
        if let lastAcceptedKDF, lastAcceptedKDF != kdfConfiguration {
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

        var masterKey = Data()
        let authHash: String
        do {
            masterKey = try await VaultwardenKeyDerivation.deriveMasterKey(
                passwordBytes: masterPasswordBytes,
                email: normalizedEmail,
                configuration: kdfConfiguration
            )
            defer { VaultwardenCryptoZeroize.zero(&masterKey) }
            authHash = try VaultwardenKeyDerivation.authenticationHash(
                masterKey: masterKey,
                passwordBytes: masterPasswordBytes
            )
        } catch let error as VaultwardenCryptoError {
            throw Self.mapCryptoError(error)
        }

        let pending = VaultwardenPendingTwoFactor(
            authHash: authHash,
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
        guard proof.provider.isUserCompletable,
              !proof.token.isEmpty,
              proof.token.utf8.count <= Self.maximumTwoFactorBytes,
              proof.token.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw VaultwardenAPIError(
                category: .unsupportedTwoFactorProvider,
                safeDisplayMessage: "This two-factor method is not supported yet."
            )
        }

        let outcome = try await submitGrant(pending: pending, proof: proof)
        guard case .authenticated(let session) = outcome else {
            // submitGrant only returns .twoFactorRequired for the initial grant
            // (proof == nil); a still-challenged resubmission is already
            // classified as bad credentials by submitGrant, so this is a
            // defensive fallback.
            throw VaultwardenAPIError(
                category: .badCredentials,
                safeDisplayMessage: "The two-factor code was not accepted."
            )
        }

        return session
    }

    /// Sends the email-provider challenge so the user can receive a code. The
    /// request authenticates with the same server-auth hash and device
    /// identifier the token grant uses; the exact field set is verified on the
    /// pinned-container contract lane.
    func sendEmailChallenge(pending: VaultwardenPendingTwoFactor) async throws {
        let url = pending.apiBaseURL.appendingPathComponent("two-factor/send-email-login")
        var body = try JSONEncoder().encode([
            "email": pending.normalizedEmail,
            "masterPasswordHash": pending.authHash,
            "deviceIdentifier": pending.device.identifier,
        ])
        defer { body.resetBytes(in: body.startIndex..<body.endIndex) }
        var response = try await transport.send(
            .post,
            url: url,
            body: .json(body),
            responseLimit: Self.maximumAuthResponseBytes
        )
        defer { response.discardBody() }
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
        var response: VaultwardenHTTPResponse
        do {
            response = try await transport.send(
                .get,
                url: configURL,
                responseLimit: Self.maximumAuthResponseBytes
            )
        } catch {
            throw Self.mapTransportError(error)
        }
        defer { response.discardBody() }
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
                // A declined approval is a user choice, not rejected
                // credentials; classify it as unexpected so credential-retry
                // UI is not offered.
                throw VaultwardenAPIError(
                    category: .unexpected,
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
        var body = try Self.emailBody(email)
        defer { body.resetBytes(in: body.startIndex..<body.endIndex) }
        let currentURL = identityBase.appendingPathComponent("accounts/prelogin/password")
        var response = try await transport.send(
            .post,
            url: currentURL,
            body: .json(body),
            responseLimit: Self.maximumAuthResponseBytes
        )

        // Legacy servers expose only the un-suffixed alias.
        if response.status == 404 {
            response.discardBody()
            let legacyURL = identityBase.appendingPathComponent("accounts/prelogin")
            response = try await transport.send(
                .post,
                url: legacyURL,
                body: .json(body),
                responseLimit: Self.maximumAuthResponseBytes
            )
        }
        defer { response.discardBody() }
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
        var response = try await transport.send(
            .post,
            url: tokenURL,
            body: .form(fields),
            responseLimit: Self.maximumAuthResponseBytes
        )
        defer { response.discardBody() }

        if (200..<300).contains(response.status) {
            let token = try decodeToken(response)
            let session = VaultwardenAuthSession(
                refreshToken: token.refreshToken,
                wrappedUserKey: token.key,
                wrappedPrivateKey: token.privateKey,
                rememberTwoFactorToken: token.twoFactorToken,
                kdfConfiguration: pending.kdfConfiguration,
                identityBaseURL: pending.identityBaseURL,
                apiBaseURL: pending.apiBaseURL
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
            let token = try JSONDecoder().decode(
                VaultwardenTokenResponse.self, from: response.body
            )
            guard Self.isValidToken(token.accessToken),
                  token.refreshToken.map(Self.isValidToken) != false,
                  token.twoFactorToken.map(Self.isValidToken) != false,
                  token.key.map(Self.isValidWrappedKey) != false,
                  token.privateKey.map(Self.isValidWrappedKey) != false,
                  token.tokenType.map({ $0.caseInsensitiveCompare("Bearer") == .orderedSame }) != false,
                  token.expiresIn.map({ $0 > 0 && $0 <= 31_536_000 }) != false else {
                throw VaultwardenAPIError(
                    category: .unexpected,
                    httpStatus: response.status,
                    safeDisplayMessage: "The server returned invalid token fields."
                )
            }
            return token
        } catch let error as VaultwardenAPIError {
            throw error
        } catch {
            throw VaultwardenAPIError(
                category: .unexpected,
                httpStatus: response.status,
                safeDisplayMessage: "The server returned an unreadable token response."
            )
        }
    }

    private static func isValidToken(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 16 * 1024
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func isValidWrappedKey(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= VaultwardenEncString.maximumSerializedBytes
    }

    /// Builds a JSON body for a single email field with proper escaping, so an
    /// address containing a quote or backslash cannot break the request shape.
    private static func emailBody(_ email: String) throws -> Data {
        try JSONEncoder().encode(["email": email])
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

    /// Resolves a config-advertised service URL to a usable base URL. A value
    /// that is not a valid absolute HTTPS URL with a host falls back to the
    /// entered service URL, so a malformed, relative, or plaintext-http
    /// advertisement never redirects credentials somewhere unexpected. The
    /// http case matters in practice: a server whose DOMAIN setting is unset
    /// advertises `http://localhost` service URLs, and treating those as
    /// unusable keeps login on the entered origin instead of failing it.
    private func baseURL(from urlString: String?, fallback: URL) -> URL {
        guard let urlString else { return fallback }
        let lowered = urlString.lowercased()
        guard !urlString.isEmpty,
              urlString.utf8.count <= Self.maximumURLBytes,
              urlString.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              !lowered.contains("%25"),
              !lowered.contains("%2e"),
              !lowered.contains("%2f"),
              !lowered.contains("%5c"),
              !urlString.contains("\\"),
              let components = URLComponents(string: urlString),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              Self.hasCanonicalPath(components),
              let url = components.url else {
            return fallback
        }

        return url
    }

    private static func hasCanonicalPath(_ components: URLComponents) -> Bool {
        let encoded = components.percentEncodedPath.lowercased()
        guard !encoded.contains("%25"),
              !encoded.contains("%2e"),
              !encoded.contains("%2f"),
              !encoded.contains("%5c"),
              !encoded.contains("\\") else {
            return false
        }
        return !components.path
            .split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0 == "." || $0 == ".." })
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
