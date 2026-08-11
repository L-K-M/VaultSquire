import Foundation

/// A vault (share) the CLI reports the user can access. `shareID` is the opaque
/// access relationship used to scope item reads; `name` is a non-secret label.
struct ProtonVault: Equatable, Sendable, Codable {
    let shareID: String
    let vaultID: String?
    let name: String
}

/// The canonical item kinds VaultSquire recognizes from the CLI. Anything else
/// is preserved as `.unknown` and shown as unsupported rather than coerced.
enum ProtonItemType: String, Sendable, Codable {
    case login
    case note
    case alias
    case creditCard
    case identity
    case sshKey
    case wifi
    case custom
    case unknown

    /// Maps a raw CLI type token to a canonical kind. Tolerant of casing and of
    /// snake/camel spelling because the exact token varies by CLI build.
    static func from(raw: String) -> ProtonItemType {
        let normalized = raw.lowercased().replacingOccurrences(of: "_", with: "")
        switch normalized {
        case "login", "loginitem": return .login
        case "note", "securenote": return .note
        case "alias": return .alias
        case "creditcard", "card": return .creditCard
        case "identity": return .identity
        case "sshkey", "ssh": return .sshKey
        case "wifi", "wifinetwork": return .wifi
        case "custom", "customitem": return .custom
        default: return .unknown
        }
    }

    var category: VaultItemCategory {
        switch self {
        case .login: return .login
        case .note: return .secureNote
        case .creditCard: return .card
        case .identity: return .identity
        case .alias, .sshKey, .wifi, .custom, .unknown: return .unsupported
        }
    }
}

/// One decoded item. Non-secret display fields (title, username, urls) are
/// always eligible; secret fields (password, totp, note) are present only after
/// an explicit read and are the fields never written to argv. A whole item is a
/// lossy projection of the CLI's output, not provider-native ciphertext.
///
/// The summary decoded from `item list` carries no secret at all — the
/// documented list payload is summaries, but it is not guaranteed, so the
/// list decoder drops every password, one-time-password, and note value
/// rather than letting one reach the sealed snapshot (the same posture the
/// 1Password decoder takes). Secrets enter an item only by merging the
/// `ProtonItemContent` of an explicit `item view` read, and that content is
/// never sealed.
struct ProtonItem: Equatable, Sendable, Codable {
    let itemID: String
    let shareID: String
    let vaultName: String
    let type: ProtonItemType
    let title: String
    let username: String?
    let password: String?
    let totp: String?
    let urls: [String]
    let note: String?

    /// Overlays the secret fields fetched from an item read onto a summary,
    /// leaving identity and display fields intact.
    func merging(_ content: ProtonItemContent) -> ProtonItem {
        ProtonItem(
            itemID: itemID,
            shareID: shareID,
            vaultName: vaultName,
            type: type,
            title: title,
            username: content.username ?? username,
            password: content.password ?? password,
            totp: content.totp ?? totp,
            urls: content.urls.isEmpty ? urls : content.urls,
            note: content.note ?? note
        )
    }
}

/// The transient decrypted content from an item read, before it is merged into
/// an item. Never persisted on its own.
struct ProtonItemContent: Equatable, Sendable {
    let username: String?
    let password: String?
    let totp: String?
    let urls: [String]
    let note: String?
}

enum ProtonReadModelError: Error, Equatable, Sendable {
    case malformedJSON
}

/// Maps the CLI's documented machine output into VaultSquire's small, canonical
/// read shapes. Decoding is deliberately tolerant: it accepts an array or a
/// wrapper object, tries several key spellings, and looks one level into common
/// content containers, so an output that adds fields never breaks a read and a
/// missing field degrades to unsupported rather than failing the snapshot. The
/// key spellings follow Proton's documented item model
/// (PROTON_PASS_RESEARCH.md §5) and are the single point to reconcile against a
/// tested CLI build.
enum ProtonReadModel {
    /// Read-only capabilities for every Proton item. All writes are disabled:
    /// no create, update, archive, trash, or delete surface exists for Proton
    /// accounts (PROTON_PASS_RESEARCH.md §8).
    static let capabilities: Set<ProviderCapability> = [
        .viewItems, .searchItems, .revealSecret, .copySecret
    ]

    // MARK: - Decoding

    static func decodeVaults(_ data: Data) throws -> [ProtonVault] {
        let objects = try objectArray(data, wrapperKeys: ["vaults", "shares", "data", "items"])
        return objects.compactMap { object in
            guard let shareID = string(object, ["shareId", "share_id", "shareID", "ShareID", "id"]) else {
                return nil
            }
            let name = string(object, ["name", "vaultName", "vault_name", "title"]) ?? "Vault"
            let vaultID = string(object, ["vaultId", "vault_id", "vaultID", "VaultID"])
            return ProtonVault(shareID: shareID, vaultID: vaultID, name: name)
        }
    }

    static func decodeItems(_ data: Data, shareID: String, vaultName: String) throws -> [ProtonItem] {
        let objects = try objectArray(data, wrapperKeys: ["items", "data", "results"])
        return objects.compactMap { object in
            guard let itemID = string(object, ["itemId", "item_id", "itemID", "ItemID", "id"]) else {
                return nil
            }
            let rawType = string(object, ["type", "itemType", "item_type", "kind"]) ?? "unknown"
            let type = ProtonItemType.from(raw: rawType)
            let title = string(object, ["title", "name"], searchNested: true) ?? "Untitled"
            let content = decodeContent(object)
            return ProtonItem(
                itemID: itemID,
                shareID: shareID,
                vaultName: vaultName,
                type: type,
                title: title,
                username: content.username,
                // No secret from a list payload is ever retained: passwords,
                // one-time-password seeds, and notes are nil here by policy,
                // whatever the build's `item list` happens to print.
                password: nil,
                totp: nil,
                urls: content.urls,
                note: nil
            )
        }
    }

    /// Decodes the content of a single item read into transient secret fields.
    static func decodeItemContent(_ data: Data) throws -> ProtonItemContent {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw ProtonReadModelError.malformedJSON
        }
        let object: [String: Any]
        if let dictionary = root as? [String: Any] {
            object = dictionary
        } else if let array = root as? [[String: Any]], let first = array.first {
            object = first
        } else {
            throw ProtonReadModelError.malformedJSON
        }
        return decodeContent(object)
    }

    // MARK: - Mapping

    static func projection(
        for item: ProtonItem,
        account: AccountID,
        captureGeneration: SnapshotGeneration
    ) -> VaultItemProjection {
        VaultItemProjection(
            id: itemID(for: item, account: account),
            displayTitle: item.title,
            displaySubtitle: item.username ?? item.urls.first,
            category: item.type.category,
            username: item.username,
            websites: item.urls,
            groupingLabels: item.vaultName.isEmpty ? [] : [item.vaultName],
            capabilities: capabilities,
            cacheReference: ProviderCacheReference(
                scope: .wholeAccount(account),
                captureGeneration: captureGeneration
            )
        )
    }

    static func detail(for item: ProtonItem, account: AccountID) -> VaultItemDetail {
        var fields: [VaultItemDetail.DetailField] = []
        func add(_ label: String, _ value: String?, _ kind: VaultItemDetail.DetailField.Kind) {
            guard let value, !value.isEmpty else { return }
            fields.append(VaultItemDetail.DetailField(
                id: "\(item.itemID)-\(label)", label: label, value: value, kind: kind
            ))
        }
        add("Vault", item.vaultName, .plain)
        add("Username", item.username, .plain)
        add("Password", item.password, .secret)
        add("One-time code", item.totp, .totpSeed)
        for (index, uri) in item.urls.enumerated() {
            add(item.urls.count == 1 ? "Website" : "Website \(index + 1)", uri, .uri)
        }
        add("Note", item.note, .plain)
        return VaultItemDetail(
            id: itemID(for: item, account: account),
            title: item.title,
            category: item.type.category,
            fields: fields
        )
    }

    static func itemID(for item: ProtonItem, account: AccountID) -> VaultItemID {
        VaultItemID(
            space: VaultSpaceID(account: account, scope: .providerSpace(item.shareID)),
            rawValue: item.itemID
        )
    }

    // MARK: - Tolerant extraction helpers

    /// The common containers an item's fields may nest under, searched in order
    /// after the top level.
    private static let contentContainers = ["content", "data", "login", "item", "metadata", "fields"]

    private static func decodeContent(_ object: [String: Any]) -> ProtonItemContent {
        ProtonItemContent(
            username: string(object, ["username", "user", "email"], searchNested: true),
            password: string(object, ["password", "pass"], searchNested: true),
            totp: string(object, ["totp", "totpUri", "totp_uri", "otp"], searchNested: true),
            urls: stringArray(object, ["urls", "uris", "websites", "url"], searchNested: true),
            note: string(object, ["note", "notes"], searchNested: true)
        )
    }

    private static func objectArray(_ data: Data, wrapperKeys: [String]) throws -> [[String: Any]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw ProtonReadModelError.malformedJSON
        }
        if let array = root as? [[String: Any]] {
            return array
        }
        if let object = root as? [String: Any] {
            for key in wrapperKeys {
                if let array = object[key] as? [[String: Any]] {
                    return array
                }
            }
            // A single object standing in for a one-element array.
            return [object]
        }
        throw ProtonReadModelError.malformedJSON
    }

    private static func string(
        _ object: [String: Any],
        _ keys: [String],
        searchNested: Bool = false
    ) -> String? {
        if let value = firstString(object, keys) {
            return value
        }
        guard searchNested else { return nil }
        for container in contentContainers {
            if let nested = object[container] as? [String: Any],
               let value = firstString(nested, keys) {
                return value
            }
        }
        return nil
    }

    private static func firstString(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func stringArray(
        _ object: [String: Any],
        _ keys: [String],
        searchNested: Bool = false
    ) -> [String] {
        if let values = firstStringArray(object, keys) {
            return values
        }
        guard searchNested else { return [] }
        for container in contentContainers {
            if let nested = object[container] as? [String: Any],
               let values = firstStringArray(nested, keys) {
                return values
            }
        }
        return []
    }

    private static func firstStringArray(_ object: [String: Any], _ keys: [String]) -> [String]? {
        for key in keys {
            if let array = object[key] as? [String] {
                return array.filter { !$0.isEmpty }
            }
            // A URL list of objects like [{"url": "..."}].
            if let array = object[key] as? [[String: Any]] {
                let extracted = array.compactMap { firstString($0, ["url", "uri", "value"]) }
                if !extracted.isEmpty { return extracted }
            }
            // A single string standing in for a one-element list.
            if let single = object[key] as? String, !single.isEmpty {
                return [single]
            }
        }
        return nil
    }
}
