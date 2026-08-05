import Foundation

/// The eight authentication error categories the client must distinguish
/// without exposing server internals or secrets. The category drives retry
/// and UI decisions; the human-facing message is derived separately and
/// carries no secret material.
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
/// field intended for humans and is scrubbed of secrets by construction (it is
/// only ever a server-provided description or a fixed string, never a token,
/// URL, or credential).
struct VaultwardenAPIError: Error, Hashable, Sendable {
    let category: VaultwardenErrorCategory
    let httpStatus: Int?
    /// Stable machine code such as an identity `error` value (e.g.
    /// "invalid_grant"); never interpolated into logs with user data.
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

/// Vaultwarden duplicates a request's error message into several compatibility
/// shapes. This resolves a single safe display message in the fixed decode
/// precedence: identity `error_description`, then `message`, then
/// `errorModel.message`, then flattened `validationErrors`, then a generic
/// status message.
enum VaultwardenErrorDecoder {
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
        if let error = body?.error, !error.isEmpty,
           let description = body?.errorDescription, !description.isEmpty {
            return description
        }
        if let message = body?.message, !message.isEmpty {
            return message
        }
        if let modelMessage = body?.errorModel?.message, !modelMessage.isEmpty {
            return modelMessage
        }
        if let flattened = body?.flattenedValidationErrors, !flattened.isEmpty {
            return flattened
        }

        return "The server returned an error (status \(httpStatus))."
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
        switch httpStatus {
        case 429:
            return VaultwardenAPIError(
                category: .rateLimit,
                httpStatus: httpStatus,
                machineCode: body?.error,
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
                machineCode: body?.error,
                retry: .noRetry,
                safeDisplayMessage: message
            )
        case 423:
            return VaultwardenAPIError(
                category: .accountLocked,
                httpStatus: httpStatus,
                machineCode: body?.error,
                retry: .noRetry,
                safeDisplayMessage: message
            )
        case 500, 502, 503, 504:
            return VaultwardenAPIError(
                category: .network,
                httpStatus: httpStatus,
                machineCode: body?.error,
                retry: .backoffThenRetry(retryAfter: retryAfter),
                safeDisplayMessage: message
            )
        default:
            return VaultwardenAPIError(
                category: .unexpected,
                httpStatus: httpStatus,
                machineCode: body?.error,
                retry: .noRetry,
                safeDisplayMessage: message
            )
        }
    }
}
