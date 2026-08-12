import Foundation

/// Canonical item category used only where a lossless mapping from the
/// provider's own kind exists. Anything else stays visible as unsupported
/// instead of being coerced into a nearby category.
enum VaultItemCategory: Hashable, Sendable {
    case login
    case secureNote
    case card
    case identity
    case unsupported
}

/// Stable reference from a projection row back to the provider cache envelope
/// it was built from.
struct ProviderCacheReference: Hashable, Sendable {
    let scope: ProviderCacheScope
    let captureGeneration: SnapshotGeneration
}

/// The narrow immutable projection shared UI and search may consume. It
/// carries display fields, non-secret labels, and exact action capabilities —
/// nothing more. Secrets, provider wire shapes, and unknown fields remain
/// inside the provider cache envelope the reference points back to.
struct VaultItemProjection: Hashable, Sendable, Identifiable {
    let id: VaultItemID
    let displayTitle: String
    let displaySubtitle: String?
    let category: VaultItemCategory
    let username: String?
    let websites: [String]
    /// Non-secret folder or collection labels; empty when a provider has no
    /// such grouping.
    let groupingLabels: [String]
    let capabilities: Set<ProviderCapability>
    let cacheReference: ProviderCacheReference
    /// Whether the item is marked as a favorite. Defaults to false so Proton
    /// and 1Password — whose CLIs expose no such concept — need no change at
    /// their construction sites; only Vaultwarden, which already decodes and
    /// round-trips `favorite` on write, passes a real value.
    ///
    /// A `var` rather than a `let`: a `let` with a default value is excluded
    /// from the memberwise initializer entirely, so the decryptor could not
    /// pass the cipher's real value. A `var` with a default appears as a
    /// defaulted parameter, which is what the rest of this comment describes.
    var favorite: Bool = false
    /// Whether the item carries a one-time-code seed, decided once when the
    /// item is projected. The row's context menu needs this to know whether to
    /// offer the action, and it is read for every visible row — asking the
    /// decrypted detail there would decrypt the whole vault on every redraw.
    ///
    /// False for both CLI providers, whose listings deliberately carry no
    /// secrets, so their rows do not offer a code the listing cannot produce.
    var hasOneTimeCode: Bool = false
}
