import Foundation

/// Names a provider implementation as an identity namespace. Provider item and
/// account identifiers are meaningful only inside their own provider, so every
/// compound identity starts here instead of assuming global uniqueness.
struct ProviderID: RawRepresentable, Hashable, Sendable, Codable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let vaultwarden = ProviderID(rawValue: "vaultwarden")
    static let protonCLI = ProviderID(rawValue: "proton-cli")
    static let onePasswordCLI = ProviderID(rawValue: "onepassword-cli")
}

/// A configured account inside one provider.
struct AccountID: Hashable, Sendable, Codable {
    let provider: ProviderID
    /// Opaque provider-issued account identifier. Never an email address.
    let rawValue: String

    init(provider: ProviderID, rawValue: String) {
        self.provider = provider
        self.rawValue = rawValue
    }
}

/// A user-visible space inside one account. A share is not a vault and not
/// every provider has spaces, so the personal scope is modeled explicitly
/// rather than reserving a magic provider identifier for it.
struct VaultSpaceID: Hashable, Sendable, Codable {
    enum Scope: Hashable, Sendable, Codable {
        case personal
        /// Provider-owned space or share identifier, such as an organization,
        /// collection, or share. Its meaning belongs to the provider.
        case providerSpace(String)
    }

    let account: AccountID
    let scope: Scope

    init(account: AccountID, scope: Scope) {
        self.account = account
        self.scope = scope
    }
}

/// The complete local item key: provider, account, space/share, and item.
/// A bare provider item identifier is never used as a local key because item
/// identifiers are not globally unique across providers, accounts, or shares.
struct VaultItemID: Hashable, Sendable, Codable {
    let space: VaultSpaceID
    let rawValue: String

    init(space: VaultSpaceID, rawValue: String) {
        self.space = space
        self.rawValue = rawValue
    }

    var account: AccountID {
        space.account
    }

    var provider: ProviderID {
        space.account.provider
    }
}
