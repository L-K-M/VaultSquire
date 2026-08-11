import Foundation

/// A vault the CLI reports the account can read. `vaultID` is the opaque
/// identifier used to scope item reads; `name` is a non-secret label.
struct OnePasswordVault: Equatable, Sendable, Codable {
    let vaultID: String
    let name: String
}

/// The canonical item categories VaultSquire recognizes from the CLI. Anything
/// else is preserved as `.unknown` and shown as unsupported rather than coerced
/// into a nearby category.
enum OnePasswordItemCategory: String, Sendable, Codable {
    case login
    case secureNote
    case creditCard
    case identity
    case password
    case apiCredential
    case database
    case server
    case sshKey
    case document
    case unknown

    /// Maps a raw CLI category token to a canonical kind. 1Password emits
    /// upper snake case (`SECURE_NOTE`); normalizing casing and separators
    /// keeps the mapping stable if a build spells one differently.
    static func from(raw: String) -> OnePasswordItemCategory {
        switch raw.lowercased().replacingOccurrences(of: "_", with: "") {
        case "login": return .login
        case "securenote": return .secureNote
        case "creditcard": return .creditCard
        case "identity": return .identity
        case "password": return .password
        case "apicredential": return .apiCredential
        case "database": return .database
        case "server": return .server
        case "sshkey": return .sshKey
        case "document": return .document
        default: return .unknown
        }
    }

    /// The shared category, mapped only where it is lossless. A 1Password
    /// Password, API Credential, Database, Server, SSH Key, or Document item
    /// has no faithful equivalent in the shared set, so it stays unsupported
    /// instead of being flattened into Login.
    var category: VaultItemCategory {
        switch self {
        case .login: return .login
        case .secureNote: return .secureNote
        case .creditCard: return .card
        case .identity: return .identity
        case .password, .apiCredential, .database, .server, .sshKey, .document, .unknown:
            return .unsupported
        }
    }
}

/// One item summary, as it rests in the sealed snapshot.
///
/// It deliberately carries no secret value. `op item list`'s payload is not
/// documented, so if a build were to include field values, the decoder drops
/// every concealed, one-time-password, and note value rather than letting it
/// reach disk. Secrets are fetched only when an item is opened, by
/// `OnePasswordItemContent`, and live in memory for that session alone.
struct OnePasswordItem: Equatable, Sendable, Codable {
    let itemID: String
    let vaultID: String
    let vaultName: String
    let category: OnePasswordItemCategory
    let title: String
    /// Non-secret. A Login's username field carries purpose `USERNAME` and
    /// type `STRING`; a concealed field is never accepted here.
    let username: String?
    /// The CLI's own non-secret display hint for a listed item, when it
    /// provides one. It is used as a subtitle fallback and is deliberately not
    /// treated as a username: `op item list`'s payload is undocumented, and
    /// what this field holds varies by category.
    let additionalInformation: String?
    /// Non-secret website labels.
    let urls: [String]
}

/// One field from an opened item, beyond the built-in ones the detail already
/// names. Custom sections and fields are where 1Password puts most of a credit
/// card, identity, or API credential, so they are surfaced rather than dropped.
struct OnePasswordContentField: Equatable, Sendable {
    let label: String
    let value: String
    let isConcealed: Bool
}

/// The transient decrypted content from one `op item get`, before it is merged
/// into a detail. Never persisted, and dropped when the vault locks.
struct OnePasswordItemContent: Equatable, Sendable {
    let username: String?
    let password: String?
    /// An `otpauth://` URI or bare Base32 seed; the UI derives the rotating
    /// code from it and never displays the seed itself.
    let totp: String?
    let note: String?
    let urls: [String]
    let additionalFields: [OnePasswordContentField]
}

enum OnePasswordReadModelError: Error, Equatable, Sendable {
    case malformedJSON
}

/// Maps the CLI's documented machine output into VaultSquire's small, canonical
/// read shapes. Decoding is deliberately tolerant: it accepts an array or a
/// wrapper object and tries several key spellings, so output that adds fields
/// never breaks a read and a missing field degrades to unsupported rather than
/// failing the snapshot. The key spellings follow 1Password's documented item
/// model (ONEPASSWORD_CLI_RESEARCH.md §5) and are the single point to reconcile
/// against a tested CLI build.
enum OnePasswordReadModel {
    /// Read-only capabilities for every 1Password item. All writes are
    /// disabled: `op item edit` places field values in argv and its template
    /// path requires rebuilding an item from lossy output, and no unarchive or
    /// restore command exists at all (ONEPASSWORD_CLI_RESEARCH.md §8).
    static let capabilities: Set<ProviderCapability> = [
        .viewItems, .searchItems, .revealSecret, .copySecret
    ]

    /// Field `purpose` values 1Password documents for built-in fields.
    private static let usernamePurpose = "USERNAME"
    private static let passwordPurpose = "PASSWORD"
    private static let notesPurpose = "NOTES"
    /// Field `type` values that carry a secret. A field of one of these types
    /// never enters a persisted summary.
    private static let concealedTypes: Set<String> = ["CONCEALED", "OTP", "SSHKEY"]

    // MARK: - Decoding

    static func decodeVaults(_ data: Data) throws -> [OnePasswordVault] {
        let objects = try objectArray(data, wrapperKeys: ["vaults", "data", "results"])
        return objects.compactMap { object in
            guard let vaultID = string(object, ["id", "vaultId", "vault_id", "uuid"]) else {
                return nil
            }
            let name = string(object, ["name", "title"]) ?? "Vault"
            return OnePasswordVault(vaultID: vaultID, name: name)
        }
    }

    /// Decodes item summaries for one vault. The vault identity comes from the
    /// caller — the vault the listing was scoped to — rather than from the
    /// payload, so an item can never be filed under a vault it was not read
    /// from.
    static func decodeItems(
        _ data: Data,
        vaultID: String,
        vaultName: String
    ) throws -> [OnePasswordItem] {
        let objects = try objectArray(data, wrapperKeys: ["items", "data", "results"])
        return objects.compactMap { object in
            guard let itemID = string(object, ["id", "itemId", "item_id", "uuid"]) else {
                return nil
            }
            let rawCategory = string(object, ["category", "type", "templateUuid"]) ?? "unknown"
            let fields = decodeFields(object)
            return OnePasswordItem(
                itemID: itemID,
                vaultID: vaultID,
                vaultName: vaultName,
                category: OnePasswordItemCategory.from(raw: rawCategory),
                title: string(object, ["title", "overview.title", "name"]) ?? "Untitled",
                username: nonSecretUsername(in: fields),
                additionalInformation: string(
                    object, ["additional_information", "additionalInformation", "ainfo"]
                ),
                urls: decodeURLs(object)
            )
        }
    }

    /// Decodes one opened item into transient content, including its secret
    /// fields.
    static func decodeItemContent(_ data: Data) throws -> OnePasswordItemContent {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw OnePasswordReadModelError.malformedJSON
        }
        let object: [String: Any]
        if let dictionary = root as? [String: Any] {
            object = dictionary
        } else if let array = root as? [[String: Any]], let first = array.first {
            object = first
        } else {
            throw OnePasswordReadModelError.malformedJSON
        }

        let fields = decodeFields(object)
        return OnePasswordItemContent(
            username: fields.first { $0.purpose == usernamePurpose }?.value,
            password: fields.first { $0.purpose == passwordPurpose }?.value,
            totp: fields.first { $0.type == "OTP" }?.value,
            note: fields.first { $0.purpose == notesPurpose }?.value,
            urls: decodeURLs(object),
            additionalFields: additionalFields(from: fields)
        )
    }

    // MARK: - Mapping

    static func projection(
        for item: OnePasswordItem,
        account: AccountID,
        captureGeneration: SnapshotGeneration
    ) -> VaultItemProjection {
        VaultItemProjection(
            id: itemID(for: item, account: account),
            displayTitle: item.title,
            displaySubtitle: item.username ?? item.additionalInformation ?? item.urls.first,
            category: item.category.category,
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

    /// Builds the detail for an item. Without fetched content it shows the
    /// non-secret summary fields only, which is what an offline read or a
    /// still-loading item honestly has.
    static func detail(
        for item: OnePasswordItem,
        account: AccountID,
        content: OnePasswordItemContent?
    ) -> VaultItemDetail {
        var fields: [VaultItemDetail.DetailField] = []

        func add(_ label: String, _ value: String?, _ kind: VaultItemDetail.DetailField.Kind) {
            guard let value, !value.isEmpty else { return }
            // Two custom fields can legitimately share a label, so the row id
            // is disambiguated by position rather than by label alone.
            let identifier = "\(item.itemID)-\(fields.count)-\(label)"
            fields.append(VaultItemDetail.DetailField(
                id: identifier, label: label, value: value, kind: kind
            ))
        }

        add("Vault", item.vaultName, .plain)
        add("Username", content?.username ?? item.username, .plain)
        add("Password", content?.password, .secret)
        add("One-time code", content?.totp, .totpSeed)

        let urls = content.map { $0.urls.isEmpty ? item.urls : $0.urls } ?? item.urls
        for (index, uri) in urls.enumerated() {
            add(urls.count == 1 ? "Website" : "Website \(index + 1)", uri, .uri)
        }

        for extra in content?.additionalFields ?? [] {
            add(extra.label, extra.value, extra.isConcealed ? .secret : .plain)
        }
        add("Note", content?.note, .plain)

        return VaultItemDetail(
            id: itemID(for: item, account: account),
            title: item.title,
            category: item.category.category,
            fields: fields
        )
    }

    static func itemID(for item: OnePasswordItem, account: AccountID) -> VaultItemID {
        VaultItemID(
            space: VaultSpaceID(account: account, scope: .providerSpace(item.vaultID)),
            rawValue: item.itemID
        )
    }

    /// Extracts an opaque account identifier from `op whoami` output, when one
    /// is present. Used to address every later command to a named account
    /// instead of relying on the CLI's default-account rule. A payload with no
    /// recognizable identifier yields nil and the commands stay unscoped.
    static func decodeAccountID(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return string(object, ["account_uuid", "accountUuid", "account_id", "accountId", "id"])
    }

    // MARK: - Field decoding

    /// One raw field, before it is classified as secret or displayable.
    private struct RawField {
        let label: String
        let value: String
        let type: String
        let purpose: String
        let sectionLabel: String?
    }

    private static func decodeFields(_ object: [String: Any]) -> [RawField] {
        guard let raw = object["fields"] as? [[String: Any]] else { return [] }
        return raw.compactMap { field in
            guard let value = firstString(field, ["value"]) else { return nil }
            let section = (field["section"] as? [String: Any])
                .flatMap { firstString($0, ["label", "name"]) }
            return RawField(
                label: firstString(field, ["label", "id", "t"]) ?? "Field",
                value: value,
                type: (firstString(field, ["type", "k"]) ?? "STRING").uppercased(),
                purpose: (firstString(field, ["purpose", "n"]) ?? "").uppercased(),
                sectionLabel: section
            )
        }
    }

    /// The username, only when it is genuinely non-secret. A build that marked
    /// the username field concealed would yield nil rather than seal a secret
    /// into the snapshot.
    private static func nonSecretUsername(in fields: [RawField]) -> String? {
        fields.first { $0.purpose == usernamePurpose && !concealedTypes.contains($0.type) }?.value
    }

    /// Every field that is not already surfaced as a built-in one, qualified by
    /// its section so two same-named fields in different sections stay
    /// distinguishable.
    private static func additionalFields(from fields: [RawField]) -> [OnePasswordContentField] {
        let builtInPurposes: Set<String> = [usernamePurpose, passwordPurpose, notesPurpose]
        var seenBuiltIn: Set<String> = []
        return fields.compactMap { field in
            // Built-in fields are rendered under their own fixed labels; skip
            // only the first of each so a duplicate purpose is still shown.
            if builtInPurposes.contains(field.purpose), seenBuiltIn.insert(field.purpose).inserted {
                return nil
            }
            if field.type == "OTP" { return nil }
            let label = field.sectionLabel.map { "\($0) · \(field.label)" } ?? field.label
            return OnePasswordContentField(
                label: label,
                value: field.value,
                isConcealed: concealedTypes.contains(field.type)
            )
        }
    }

    private static func decodeURLs(_ object: [String: Any]) -> [String] {
        guard let raw = object["urls"] else {
            return firstString(object, ["url", "href"]).map { [$0] } ?? []
        }
        if let array = raw as? [[String: Any]] {
            return array.compactMap { firstString($0, ["href", "url", "value"]) }
        }
        if let array = raw as? [String] {
            return array.filter { !$0.isEmpty }
        }
        if let single = raw as? String, !single.isEmpty {
            return [single]
        }
        return []
    }

    // MARK: - Tolerant extraction helpers

    private static func objectArray(_ data: Data, wrapperKeys: [String]) throws -> [[String: Any]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw OnePasswordReadModelError.malformedJSON
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
        throw OnePasswordReadModelError.malformedJSON
    }

    /// Reads the first present key, following one dotted path segment so a
    /// nested `overview.title` spelling resolves without a general search.
    private static func string(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let dot = key.firstIndex(of: ".") {
                let container = String(key[key.startIndex..<dot])
                let leaf = String(key[key.index(after: dot)...])
                if let nested = object[container] as? [String: Any],
                   let value = firstString(nested, [leaf]) {
                    return value
                }
                continue
            }
            if let value = firstString(object, [key]) {
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
}
