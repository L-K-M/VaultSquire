import Foundation

/// Exact per-action capabilities a provider account or item supports. UI
/// actions are enabled from these values only; capability absence is a
/// provider fact, never a mapping of one provider's semantics onto another's.
enum ProviderCapability: String, CaseIterable, Hashable, Sendable, Codable {
    case viewItems = "view-items"
    case searchItems = "search-items"
    case revealSecret = "reveal-secret"
    case copySecret = "copy-secret"
    case createItem = "create-item"
    case updateItem = "update-item"
    case archiveItem = "archive-item"
    case trashItem = "trash-item"
    case restoreItem = "restore-item"
    case deleteItemPermanently = "delete-item-permanently"
    case favoriteItem = "favorite-item"
    case organizeFolders = "organize-folders"
    case shareItems = "share-items"
    case manageAliases = "manage-aliases"
    case usePasskeys = "use-passkeys"
    case transferAttachments = "transfer-attachments"
    case incrementalSync = "incremental-sync"
}

/// Where an action attempt originated. Every entry point routes through the
/// same gate so none of them can bypass a capability check.
enum ActionEntryPoint: CaseIterable, Hashable, Sendable {
    case menu
    case keyboardShortcut
    case contextMenu
    case deepLink
    case accessibilityAction
}

/// A provider mutation shape. Field payloads arrive with the provider
/// workstreams; the shape exists now so capability gating is exact per action.
enum VaultItemMutation: Hashable, Sendable {
    case createItem(VaultSpaceID)
    case updateItem(VaultItemID)
    case archiveItem(VaultItemID)
    case trashItem(VaultItemID)
    case restoreItem(VaultItemID)
    case deleteItemPermanently(VaultItemID)
    case favoriteItem(VaultItemID)

    var requiredCapability: ProviderCapability {
        switch self {
        case .createItem:
            return .createItem
        case .updateItem:
            return .updateItem
        case .archiveItem:
            return .archiveItem
        case .trashItem:
            return .trashItem
        case .restoreItem:
            return .restoreItem
        case .deleteItemPermanently:
            return .deleteItemPermanently
        case .favoriteItem:
            return .favoriteItem
        }
    }
}

enum CapabilityGateError: Error, Equatable, Sendable {
    case unsupportedCapability(ProviderCapability)
}

/// Proof that a specific mutation passed the capability gate. Only the gate
/// can create one, so a provider mutation cannot be invoked — from menus,
/// keyboard shortcuts, context menus, deep links, or accessibility actions —
/// without its capability check.
struct CapabilityAuthorization: Hashable, Sendable {
    let mutation: VaultItemMutation
    let entryPoint: ActionEntryPoint

    fileprivate init(mutation: VaultItemMutation, entryPoint: ActionEntryPoint) {
        self.mutation = mutation
        self.entryPoint = entryPoint
    }
}

/// The single use-case boundary between action entry points and provider
/// mutations. Disabled controls are presentation only; this check is the rule.
struct CapabilityGate: Sendable {
    let capabilities: Set<ProviderCapability>

    init(capabilities: Set<ProviderCapability>) {
        self.capabilities = capabilities
    }

    func supports(_ capability: ProviderCapability) -> Bool {
        capabilities.contains(capability)
    }

    /// Authorizes a mutation, or throws.
    ///
    /// The throw is the refusal and never anything else — there is one throw
    /// site and it fires only when the provider lacks the capability. That is
    /// what makes `try?` at the call sites correct rather than lossy: there is
    /// no internal error being swallowed alongside the verdict. Anything added
    /// here that can fail for another reason has to be reported separately,
    /// because callers map a throw straight onto "not permitted".
    func authorize(
        _ mutation: VaultItemMutation,
        from entryPoint: ActionEntryPoint
    ) throws -> CapabilityAuthorization {
        let required = mutation.requiredCapability
        guard capabilities.contains(required) else {
            throw CapabilityGateError.unsupportedCapability(required)
        }

        return CapabilityAuthorization(mutation: mutation, entryPoint: entryPoint)
    }
}
