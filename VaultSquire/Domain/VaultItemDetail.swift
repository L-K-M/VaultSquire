import Foundation

/// A decrypted item, held only in memory while the vault is unlocked and never
/// persisted. It is provider-agnostic: a provider's decryptor flattens its item
/// into ordered fields the detail view renders uniformly. Secret fields are
/// marked so the UI keeps them concealed until revealed and never logs them.
struct VaultItemDetail: Sendable, Hashable, Identifiable {
    let id: VaultItemID
    let title: String
    let category: VaultItemCategory
    let fields: [DetailField]
    /// Whether the owning account may reveal or copy secret fields at all.
    /// False under a provider hide-passwords policy, where secrets are never
    /// offered even though the ciphertext decrypts locally.
    var canRevealSecrets: Bool = true

    /// A single labelled field of a decrypted item.
    struct DetailField: Sendable, Hashable, Identifiable {
        enum Kind: Sendable, Hashable {
            case plain
            case secret
            /// A TOTP seed (an `otpauth://` URI or a bare Base32 secret); the UI
            /// derives and displays the rotating code, never the seed.
            case totpSeed
            case uri
        }

        /// Stable within one item, so SwiftUI can identify rows without an index.
        let id: String
        let label: String
        let value: String
        let kind: Kind

        var isConcealable: Bool {
            kind == .secret || kind == .totpSeed
        }
    }
}
