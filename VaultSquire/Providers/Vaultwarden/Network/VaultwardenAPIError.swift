import Foundation

/// The eight authentication error categories the client must distinguish
/// without exposing server internals or secrets. The category drives retry
/// and UI decisions; the human-facing message is fixed local wording and
/// carries no provider-controlled prose or secret material.
enum VaultwardenErrorCategory: String, Hashable, Sendable {
    case badCredentials
    case twoFactorChallenge
    case unsupportedTwoFactorProvider
    case rateLimit
    case tls
    case network
    case accountLocked
    case incompatibleCrypto
    /// A session-ending refresh/authorization failure (`invalid_grant`).
    case sessionExpired
    /// Anything not otherwise classified; carries only a stable code.
    case unexpected
}

/// Whether an operation may be retried, and how. Kept separate from the
/// display message so retry logic never depends on human-facing text.
enum VaultwardenRetryDisposition: Hashable, Sendable {
    case noRetry
    case retryAfterRefreshOnce
    case backoffThenRetry(retryAfter: TimeInterval?)
    case reconcileBeforeRetry
}

/// A typed transport/auth error. `category`, `httpStatus`, `machineCode`, and
/// `retry` are the machine-readable facts; `safeDisplayMessage` is the only
/// field intended for humans. It is always fixed local wording; server
/// descriptions and validation text never cross into it because they may echo
/// submitted values or contain deceptive controls.
struct VaultwardenAPIError: Error, Hashable, Sendable {
    let category: VaultwardenErrorCategory
    let httpStatus: Int?
    /// Stable, bounded machine code such as `invalid_grant`; arbitrary server
    /// text is never retained here or interpolated into UI/logs.
    let machineCode: String?
    let retry: VaultwardenRetryDisposition
    let safeDisplayMessage: String

    init(
        category: VaultwardenErrorCategory,
        httpStatus: Int? = nil,
        machineCode: String? = nil,
        retry: VaultwardenRetryDisposition = .noRetry,
        safeDisplayMessage: String
    ) {
        self.category = category
        self.httpStatus = httpStatus
        self.machineCode = machineCode
        self.retry = retry
        self.safeDisplayMessage = safeDisplayMessage
    }
}

/// Classifies Vaultwarden failures while keeping arbitrary provider prose on
/// the untrusted side of the boundary. Only a bounded machine code and fixed
/// local display wording survive.
enum VaultwardenErrorDecoder {
    private static func machineCode(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.utf8.count <= 128 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._-")
        )
        return raw.unicodeScalars.allSatisfy { allowed.contains($0) } ? raw : nil
    }

    /// Which grant produced a response, so `invalid_grant` classifies
    /// correctly: rejected login credentials versus an expired session.
    enum Context: Sendable {
        case login
        case refresh
    }

    static func safeMessage(
        from body: VaultwardenErrorBody?,
        httpStatus: Int
    ) -> String {
        // Provider text is untrusted and may echo submitted values, contain
        // control characters, or be arbitrarily large. UI receives fixed local
        // wording only; `body` remains a classification input, never prose.
        _ = body
        switch httpStatus {
        case 400, 401:
            return "The server rejected the sign-in request."
        case 423:
            return "The account is locked."
        case 429:
            return "Too many attempts were made. Try again later."
        case 500, 502, 503, 504:
            return "The server is temporarily unavailable."
        default:
            return "The server returned an error (status \(httpStatus))."
        }
    }

    /// Classifies a completed HTTP response into a typed error. 2FA challenge
    /// detection is decided by the caller from local login state and the
    /// presence of challenge maps, so this handles the non-challenge paths.
    ///
    /// `context` distinguishes a token refresh from an interactive login: an
    /// `invalid_grant` on refresh ends the session (reauthentication needed),
    /// while the same code on a login grant means the submitted credentials
    /// were rejected. This classifier serves the authenticator; the refresher
    /// reports session expiry through its own outcome type.
    static func classify(
        httpStatus: Int,
        body: VaultwardenErrorBody?,
        retryAfter: TimeInterval?,
        context: Context = .login
    ) -> VaultwardenAPIError {
        let message = safeMessage(from: body, httpStatus: httpStatus)
        let code = machineCode(body?.error)
        switch httpStatus {
        case 429:
            return VaultwardenAPIError(
                category: .rateLimit,
                httpStatus: httpStatus,
                machineCode: code,
                retry: .backoffThenRetry(retryAfter: retryAfter),
                safeDisplayMessage: message
            )
        case 400 where body?.error == "invalid_grant":
            return VaultwardenAPIError(
                category: context == .refresh ? .sessionExpired : .badCredentials,
                httpStatus: httpStatus,
                machineCode: "invalid_grant",
                retry: .noRetry,
                safeDisplayMessage: message
            )
        case 400, 401:
            return VaultwardenAPIError(
                category: .badCredentials,
                httpStatus: httpStatus,
                machineCode: code,
                retry: .noRetry,
                safeDisplayMessage: message
            )
        case 423:
            return VaultwardenAPIError(
                category: .accountLocked,
                httpStatus: httpStatus,
                machineCode: code,
                retry: .noRetry,
                safeDisplayMessage: message
            )
        case 500, 502, 503, 504:
            return VaultwardenAPIError(
                category: .network,
                httpStatus: httpStatus,
                machineCode: code,
                retry: .backoffThenRetry(retryAfter: retryAfter),
                safeDisplayMessage: message
            )
        default:
            return VaultwardenAPIError(
                category: .unexpected,
                httpStatus: httpStatus,
                machineCode: code,
                retry: .noRetry,
                safeDisplayMessage: message
            )
        }
    }
}
