import Foundation

/// The fixed Vaultwarden second-factor provider identifiers and this release's
/// support decision. Numbers are fixed by the server model; the client never
/// reassigns them.
enum VaultwardenTwoFactorProvider: Int, CaseIterable, Hashable, Sendable {
    case authenticator = 0
    case email = 1
    case duo = 2
    case yubiKeyOTP = 3
    case legacyU2F = 4
    case rememberToken = 5
    case organizationDuo = 6
    case webAuthn = 7
    case recoveryCode = 8

    /// Providers a user can complete interactively in this release: TOTP,
    /// email, and recovery code. WebAuthn, Duo, YubiKey, U2F, and org Duo are
    /// parsed and reported unsupported until their integrations are tested;
    /// the remember token is internal, not a user-completed challenge.
    var isUserCompletable: Bool {
        switch self {
        case .authenticator, .email, .recoveryCode:
            return true
        case .duo, .yubiKeyOTP, .legacyU2F, .rememberToken,
             .organizationDuo, .webAuthn:
            return false
        }
    }

    /// True for the email provider, which requires a separate send-challenge
    /// request before the code can be entered.
    var requiresChallengeDispatch: Bool {
        self == .email
    }
}

/// A parsed 2FA requirement: the offered providers split into the ones a user
/// can complete now and the ones this release only recognizes.
struct VaultwardenTwoFactorChallenge: Hashable, Sendable {
    let offered: [VaultwardenTwoFactorProvider]
    let unknownProviderIDs: [Int]

    init(offeredProviderIDs: [Int]) {
        var offered: [VaultwardenTwoFactorProvider] = []
        var unknown: [Int] = []
        for id in offeredProviderIDs {
            if let provider = VaultwardenTwoFactorProvider(rawValue: id) {
                offered.append(provider)
            } else {
                unknown.append(id)
            }
        }
        self.offered = offered
        self.unknownProviderIDs = unknown
    }

    /// The providers the user can complete. Order is ascending provider ID
    /// (the challenge maps are unordered on the wire, so a stable numeric order
    /// is imposed), not a server-declared preference; the caller chooses how to
    /// present them.
    var completableProviders: [VaultwardenTwoFactorProvider] {
        offered.filter(\.isUserCompletable)
    }

    /// True when the server requires a second factor but this release supports
    /// none of the offered providers.
    var hasNoCompletableProvider: Bool {
        completableProviders.isEmpty
    }
}

/// A user's proof for a specific provider, submitted on the token grant.
struct VaultwardenTwoFactorProof: Hashable, Sendable {
    let provider: VaultwardenTwoFactorProvider
    /// The one-time proof value (TOTP code, emailed code, or recovery code).
    /// Used for a single operation and never logged or persisted.
    let token: String
    /// Whether to request a remember-me token; sent as "1" only when true.
    let rememberDevice: Bool
}
